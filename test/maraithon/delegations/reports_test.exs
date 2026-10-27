defmodule Maraithon.Delegations.ReportsTest do
  use Maraithon.DataCase, async: true
  alias Maraithon.{Accounts, Repo}
  alias Maraithon.Delegations.{Delegation, Reports, Turn}
  alias Maraithon.ChiefOfStaff.Skills.MorningBriefing

  setup do
    user_id = "delegation-report-#{Ecto.UUID.generate()}@example.invalid"
    {:ok, _} = Accounts.get_or_create_user_by_email(user_id)

    account =
      Repo.insert!(%Maraithon.Accounts.ConnectedAccount{
        user_id: user_id,
        provider: "google:report",
        status: "connected"
      })

    %{user_id: user_id, account: account, now: DateTime.utc_now()}
  end

  test "quiet users have no invented progress or spend", c do
    report = report(c)
    assert report["items"] == []
    assert report["cost"]["recorded_30d_micro_usd"] == 0
    assert report["cost"]["unresolved_micro_usd"] == 0
    assert Reports.section(report) == nil
  end

  test "old decisions surface before recent activity; quiet waiting and archived work stay quiet",
       c do
    old = DateTime.add(c.now, -90, :day)
    waiting = conversation(c, "waiting_reply", old)
    archived = conversation(c, "completed", old)
    decision = conversation(c, "needs_user", old)
    recent = conversation(c, "completed", c.now)
    report = report(c)

    assert Enum.map(report["items"], & &1["todo_id"]) == [decision.todo_id, recent.todo_id]
    refute Enum.any?(report["items"], &(&1["todo_id"] in [waiting.todo_id, archived.todo_id]))
    section = Reports.section(report)
    assert section =~ "Owner: Charlie"
    assert section =~ "Which date should Charlie use?"
    assert section =~ "Completed"
  end

  test "cost window includes its boundary, retains older unknown charges and isolates users", c do
    d = conversation(c, "completed", c.now)
    boundary = DateTime.add(c.now, -30, :day)
    turn(d, 1, boundary, 2_000, 0)
    turn(d, 2, DateTime.add(boundary, -1), 8_000, 10_000)
    turn(d, 3, c.now, 4_000, 0)

    {:ok, other} =
      Accounts.get_or_create_user_by_email("other-#{Ecto.UUID.generate()}@example.invalid")

    account =
      Repo.insert!(%Maraithon.Accounts.ConnectedAccount{
        user_id: other.email,
        provider: "google:other-report",
        status: "connected"
      })

    other_context = %{c | user_id: other.email, account: account}
    foreign = conversation(other_context, "needs_user", c.now)
    turn(foreign, 1, c.now, 900_000, 500_000)
    report = report(c)
    [item] = report["items"]

    assert report["cost"] == %{
             "recorded_30d_micro_usd" => 6_000,
             "unresolved_micro_usd" => 10_000
           }

    assert item["cost"]["lifetime_micro_usd"] == 14_000
    assert item["cost"]["turns"] == 3
    assert item["cost"]["model_calls"] == 6
    assert item["cost"]["average_per_turn_micro_usd"] == 4_666
    assert Reports.section(report) =~ "US$0.01 reserved; final provider cost is pending"
    assert Reports.section(report) =~ "last 30 days: US$0.006"
  end

  test "bounded rows do not truncate the user's cost total", c do
    for _ <- 1..10 do
      d = conversation(c, "completed", c.now)
      turn(d, 1, c.now, 1_000, 0)
    end

    report = report(c)
    assert length(report["items"]) == 8
    assert report["more"]
    assert report["cost"]["recorded_30d_micro_usd"] == 10_000
    assert Reports.section(report) =~ "More conversations are available in Tasks."
  end

  test "brief verification replaces model claims, preserves ownership and is idempotent", c do
    d = conversation(c, "needs_user", c.now)
    turn(d, 1, c.now, 4_483, 0)
    input = %{"date" => "2026-09-15", "delegations" => report(c)}

    brief = %{
      "body" =>
        "Review the open decision.\n\n## Delegated conversations\nEverything sent. Cost US$99.\n\n## Today's Move\nPick the date.",
      "todos" => []
    }

    {verified, _} = MorningBriefing.verify_quality(brief, input, "source_fallback")
    refute verified["body"] =~ "Everything sent"
    refute verified["body"] =~ "US$99"
    assert verified["body"] =~ "Owner: Charlie"
    assert verified["body"] =~ "US$0.004483"
    {again, _} = MorningBriefing.verify_quality(verified, input, "source_fallback")
    assert length(Regex.scan(~r/## Delegated conversations/, again["body"])) == 1
    assert again["body"] =~ "Which date should Charlie use?"
    assert again["todos"] == []
  end

  test "source labels cannot insert a markdown section or executable link", c do
    d = conversation(c, "needs_user", c.now)
    todo = Repo.get!(Maraithon.Todos.Todo, d.todo_id)

    todo
    |> Ecto.Changeset.change(title: "A\n## Done\n[click](javascript:alert(1)) <script>x</script>")
    |> Repo.update!()

    section = Reports.section(report(c))
    refute section =~ "\n## Done"
    refute section =~ "[click](javascript"
    refute section =~ "<script>"
  end

  test "the brief leaves delegated actions with the agent and returns paused work to the user",
       c do
    waiting = conversation(c, "waiting_reply", DateTime.add(c.now, -90, :day))
    paused = conversation(c, "paused", c.now)
    needs_user = conversation(c, "needs_user", c.now)
    options = [exclude_delegated: true, now: c.now]

    tasks = Maraithon.Todos.list_open_for_user(c.user_id, options)
    assert Enum.map(tasks, & &1.id) == [paused.todo_id]
    assert length(Maraithon.Todos.list_open_for_user(c.user_id)) == 3
    bucket = Maraithon.Todos.bucket_for_brief(c.user_id, options)
    assert bucket["active_count"] == 1
    refute inspect(bucket) =~ waiting.todo_id
    refute inspect(bucket) =~ needs_user.todo_id
    assert Reports.section(report(c)) =~ "Needs your decision"
  end

  defp report(c), do: Reports.brief(c.user_id, c.now, DateTime.add(c.now, -1, :day))

  defp conversation(c, state, at) do
    todo =
      Repo.insert!(%Maraithon.Todos.Todo{
        user_id: c.user_id,
        owner_user_id: c.user_id,
        title: "Get Charlie's dates",
        summary: "Charlie is coordinating the meeting",
        source: "manual",
        next_action: "Wait for Charlie",
        dedupe_key: Ecto.UUID.generate()
      })

    d =
      %Delegation{user_id: c.user_id}
      |> Delegation.changeset(%{
        todo_id: todo.id,
        connected_account_id: c.account.id,
        provider: "gmail",
        state: state,
        data: %{
          "task_owner" => %{"kind" => "person", "label" => "Charlie"},
          "question" => "Which date should Charlie use?"
        }
      })
      |> Repo.insert!()

    from(row in Delegation, where: row.id == ^d.id) |> Repo.update_all(set: [updated_at: at])
    d
  end

  defp turn(d, seq, at, cost, reserved) do
    turn =
      %Turn{user_id: d.user_id}
      |> Turn.changeset(%{
        delegation_id: d.id,
        seq: seq,
        grant_version: 1,
        source_revision: seq,
        status: "settled",
        cost_micro_usd: cost,
        reserved_micro_usd: reserved,
        model_calls: 2,
        data: %{}
      })
      |> Repo.insert!()

    from(row in Turn, where: row.id == ^turn.id) |> Repo.update_all(set: [updated_at: at])
  end
end
