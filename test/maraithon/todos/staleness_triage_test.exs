defmodule Maraithon.Todos.StalenessTriageTest do
  use Maraithon.DataCase, async: true

  alias Maraithon.Accounts
  alias Maraithon.ConnectedAccounts
  alias Maraithon.Repo
  alias Maraithon.Todos
  alias Maraithon.Todos.{StalenessBatch, StalenessTriage}

  defp unique_user! do
    user_id = "staleness-triage-#{Ecto.UUID.generate()}@example.com"
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)
    user_id
  end

  defp connect_telegram!(user_id, chat_id) do
    {:ok, _telegram} =
      ConnectedAccounts.upsert_manual(user_id, "telegram", %{
        external_account_id: chat_id,
        metadata: %{"username" => "staleness-triage"}
      })

    chat_id
  end

  defp stale_todo_attrs(title, days_ago, overrides \\ %{}) do
    occurred_at =
      DateTime.utc_now()
      |> DateTime.add(-days_ago * 24 * 60 * 60, :second)
      |> DateTime.truncate(:second)

    %{
      "source" => "gmail",
      "title" => title,
      "summary" => "This item has been quiet since it was captured.",
      "next_action" => "Confirm whether this thread still needs handling.",
      "source_occurred_at" => occurred_at,
      "dedupe_key" => "staleness-triage:#{Ecto.UUID.generate()}"
    }
    |> Map.merge(overrides)
  end

  defp create_todos!(user_id, attrs_list) do
    {:ok, todos} = Todos.upsert_many(user_id, attrs_list)
    todos
  end

  defp accepting_deliver(test_pid, message_id) do
    fn candidate ->
      send(test_pid, {:push, candidate})
      {:ok, %{decision: "sent_now", message_id: message_id}}
    end
  end

  defp empty_array_llm(test_pid) do
    fn prompt ->
      send(test_pid, {:triage_prompt, prompt})
      {:ok, %{content: "[]"}}
    end
  end

  test "builds a card capped at 6 oldest candidates and honors the reused exclusions" do
    user_id = unique_user!()
    chat_id = connect_telegram!(user_id, "778899")
    test_pid = self()

    qualifying =
      Enum.map(0..7, fn offset ->
        stale_todo_attrs("Quiet open loop number #{offset + 1}", 30 - offset)
      end)

    excluded = [
      stale_todo_attrs("Book the dentist for our daughter", 25),
      stale_todo_attrs("Waiting on a reply about the project proposal", 25, %{
        "metadata" => %{"relationship_strength" => 80}
      }),
      stale_todo_attrs("Escalate the certificate expiry issue", 25, %{"priority" => 90})
    ]

    [nudged_attrs, proposed_attrs] = [
      stale_todo_attrs("Recheck the mirror sync report", 25),
      stale_todo_attrs("Confirm the offsite room block", 25, %{
        "metadata" => %{
          "staleness_triage" => %{
            "last_proposed_at" =>
              DateTime.utc_now() |> DateTime.add(-1 * 24 * 3600, :second) |> DateTime.to_iso8601()
          }
        }
      })
    ]

    # Titles asserted below come from the persisted structs, since
    # UserFacingCopy may polish raw title wording on ingest.
    qualifying_todos = create_todos!(user_id, qualifying)
    excluded_todos = create_todos!(user_id, excluded)
    [nudged_todo] = create_todos!(user_id, [nudged_attrs])
    [proposed_todo] = create_todos!(user_id, [proposed_attrs])

    # Recently nudged (within 7 days) means "actively being chased".
    {:ok, _todo} =
      Todos.get_for_user(user_id, nudged_todo.id)
      |> Ecto.Changeset.change(
        last_nudged_at:
          DateTime.utc_now() |> DateTime.add(-2 * 24 * 3600, :second) |> DateTime.truncate(:second)
      )
      |> Repo.update()

    assert {:ok, %{sent: true, decision: "sent_now", todo_count: 6}} =
             StalenessTriage.run_for_user(user_id,
               llm_complete: empty_array_llm(test_pid),
               push_deliver: accepting_deliver(test_pid, "9001")
             )

    assert_receive {:triage_prompt, prompt}
    assert prompt =~ "CURRENT_LOCAL_TIME"

    assert_receive {:push, candidate}
    assert candidate.user_id == user_id
    assert candidate.chat_id == chat_id
    assert candidate.origin_type == "staleness_triage"
    assert candidate.urgency == 0.2
    assert candidate.interrupt_now == false
    assert candidate.digest == true

    assert candidate.dedupe_key ==
             "staleness_triage:#{user_id}:#{Date.to_iso8601(Date.utc_today())}"

    assert candidate.body =~ "These 6 look stale — still relevant?"
    assert candidate.body =~ "days ago."

    # Oldest six qualifying items are on the card; the two youngest
    # qualifying items wait for a later batch.
    for todo <- Enum.take(qualifying_todos, 6) do
      assert candidate.body =~ todo.title
    end

    for todo <- Enum.drop(qualifying_todos, 6) do
      refute candidate.body =~ todo.title
    end

    # Reused AttentionRanker carve-outs plus this pass's own guards.
    for todo <- excluded_todos ++ [nudged_todo, proposed_todo] do
      refute candidate.body =~ todo.title
    end

    rows = candidate.telegram_opts[:reply_markup]["inline_keyboard"]
    assert length(rows) == 6

    oldest = List.first(qualifying_todos)

    assert Enum.at(rows, 0) == [
             %{"text" => "Keep active", "callback_data" => "tgtodo:#{oldest.id}:important"},
             %{"text" => "Done", "callback_data" => "tgtodo:#{oldest.id}:done"},
             %{"text" => "Dismiss", "callback_data" => "tgtodo:#{oldest.id}:dismiss"}
           ]

    # Batch state persisted with the resolved chat_id and returned message_id.
    batch = StalenessBatch.get_by_message(chat_id, "9001")
    assert batch.user_id == user_id
    assert length(batch.todo_ids) == 6
    assert oldest.id in batch.todo_ids

    # Only carded todos get the proposal stamp.
    stamped = Todos.get_for_user(user_id, oldest.id)
    assert is_binary(get_in(stamped.metadata, ["staleness_triage", "last_proposed_at"]))

    capped_out = List.last(qualifying_todos)
    uncarded = Todos.get_for_user(user_id, capped_out.id)
    assert get_in(uncarded.metadata, ["staleness_triage", "last_proposed_at"]) == nil

    # A recent batch means the next daily tick is a no-op for this user.
    assert {:skip, :recent_batch} =
             StalenessTriage.run_for_user(user_id,
               llm_complete: empty_array_llm(test_pid),
               push_deliver: accepting_deliver(test_pid, "9002")
             )
  end

  test "held or suppressed deliveries create no batch row and stamp nothing" do
    user_id = unique_user!()
    _chat_id = connect_telegram!(user_id, "778900")
    test_pid = self()

    [todo] = create_todos!(user_id, [stale_todo_attrs("Quiet held-delivery loop", 20)])

    held_deliver = fn candidate ->
      send(test_pid, {:push, candidate})
      {:ok, %{decision: "held_rate_limit", reason: "quiet_hours"}}
    end

    assert {:ok, %{sent: false, decision: "held_rate_limit"}} =
             StalenessTriage.run_for_user(user_id,
               llm_complete: empty_array_llm(test_pid),
               push_deliver: held_deliver
             )

    assert_receive {:push, _candidate}
    assert Repo.all(from(batch in StalenessBatch, where: batch.user_id == ^user_id)) == []

    unstamped = Todos.get_for_user(user_id, todo.id)
    assert get_in(unstamped.metadata, ["staleness_triage", "last_proposed_at"]) == nil

    # Nothing was stamped, so the very next tick retries naturally.
    suppressed_deliver = fn candidate ->
      send(test_pid, {:push, candidate})
      {:ok, %{decision: "suppressed", reason: "duplicate"}}
    end

    assert {:ok, %{sent: false, decision: "suppressed"}} =
             StalenessTriage.run_for_user(user_id,
               llm_complete: empty_array_llm(test_pid),
               push_deliver: suppressed_deliver
             )

    assert Repo.all(from(batch in StalenessBatch, where: batch.user_id == ^user_id)) == []
  end

  test "skips the whole cycle when no Telegram destination resolves" do
    user_id = unique_user!()
    test_pid = self()

    _todos = create_todos!(user_id, [stale_todo_attrs("Quiet loop with no telegram", 20)])

    deliver = fn candidate ->
      send(test_pid, {:push, candidate})
      {:ok, %{decision: "sent_now", message_id: "1"}}
    end

    assert {:skip, :no_telegram_destination} =
             StalenessTriage.run_for_user(user_id,
               llm_complete: empty_array_llm(test_pid),
               push_deliver: deliver
             )

    refute_receive {:push, _candidate}
  end

  test "does nothing for a user with zero stale candidates" do
    user_id = unique_user!()
    connect_telegram!(user_id, "778901")
    test_pid = self()

    # Fresh todo: not stale, so no card and no model/push calls.
    _todos = create_todos!(user_id, [stale_todo_attrs("Fresh item from yesterday", 1)])

    assert {:skip, :no_candidates} =
             StalenessTriage.run_for_user(user_id,
               llm_complete: empty_array_llm(test_pid),
               push_deliver: accepting_deliver(test_pid, "1")
             )

    refute_receive {:triage_prompt, _prompt}
    refute_receive {:push, _candidate}
  end

  test "StalenessTriageSweep.run_once proposes for due users and skips quiet ones" do
    user_id = unique_user!()
    connect_telegram!(user_id, "778902")
    quiet_user_id = unique_user!()
    connect_telegram!(quiet_user_id, "778903")
    test_pid = self()

    _todos = create_todos!(user_id, [stale_todo_attrs("Quiet sweep target item", 20)])
    _fresh = create_todos!(quiet_user_id, [stale_todo_attrs("Fresh sweep item", 1)])

    summary =
      Maraithon.Runtime.StalenessTriageSweep.run_once(
        user_ids: [user_id, quiet_user_id],
        llm_complete: empty_array_llm(test_pid),
        push_deliver: accepting_deliver(test_pid, "42")
      )

    assert summary == %{users: 2, proposed: 1, skipped: 1, errors: 0}
    assert_receive {:push, %{user_id: ^user_id}}
    refute_receive {:push, _other}
  end

  test "record_resolution is idempotent and get_by_message round-trips id shapes" do
    user_id = unique_user!()
    todo_id = Ecto.UUID.generate()
    other_id = Ecto.UUID.generate()

    {:ok, batch} =
      StalenessBatch.create(%{
        user_id: user_id,
        chat_id: 12_345,
        message_id: 777,
        todo_ids: [todo_id, other_id],
        rationales: %{todo_id => "Quiet for weeks."}
      })

    # Integer ids were normalized to the same string form the callback
    # handler reads, so both shapes find the batch.
    assert %StalenessBatch{id: batch_id} = StalenessBatch.get_by_message("12345", "777")
    assert %StalenessBatch{id: ^batch_id} = StalenessBatch.get_by_message(12_345, 777)
    assert batch.id == batch_id

    {:ok, once} = StalenessBatch.record_resolution(batch, todo_id, "done")
    {:ok, twice} = StalenessBatch.record_resolution(once, todo_id, "done")

    assert once.resolved == twice.resolved
    assert twice.resolved[todo_id]["action"] == "done"

    refute StalenessBatch.all_resolved?(twice)

    {:ok, finished} = StalenessBatch.record_resolution(twice, other_id, "important")
    assert StalenessBatch.all_resolved?(finished)
  end
end
