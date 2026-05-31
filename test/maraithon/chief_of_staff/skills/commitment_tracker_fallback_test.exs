defmodule Maraithon.ChiefOfStaff.Skills.CommitmentTrackerFallbackTest do
  use Maraithon.DataCase, async: false

  alias Maraithon.Accounts
  alias Maraithon.Agents
  alias Maraithon.Briefs
  alias Maraithon.ChiefOfStaff.Skills.CommitmentTracker
  alias Maraithon.ChiefOfStaff.SourceBundle
  alias Maraithon.Todos

  setup do
    old_todos_config = Application.get_env(:maraithon, :todos, [])

    Application.put_env(
      :maraithon,
      :todos,
      Keyword.put(old_todos_config, :llm_complete, fn _prompt ->
        {:error, :todo_intelligence_unavailable}
      end)
    )

    on_exit(fn ->
      Application.put_env(:maraithon, :todos, old_todos_config)
    end)

    user_id = "commitment-tracker-fallback-#{System.unique_integer([:positive])}@example.com"
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

    {:ok, agent} =
      Agents.create_agent(%{
        user_id: user_id,
        behavior: "ai_chief_of_staff",
        config: %{}
      })

    %{user_id: user_id, agent: agent}
  end

  test "saves checked commitments directly when todo intelligence is unavailable", %{
    user_id: user_id,
    agent: agent
  } do
    now = ~U[2026-05-09 15:00:00Z]

    source_bundle =
      %{trigger: %{type: :wakeup}, timestamp: now}
      |> SourceBundle.empty(%{})
      |> SourceBundle.put_gmail(%{
        "inbox_messages" => [],
        "sent_messages" => [
          %{
            "message_id" => "msg-sent-investor-pack",
            "thread_id" => "thread-investor-pack",
            "labels" => ["SENT"],
            "from" => "Kent <kent@runner.now>",
            "to" => "Priya <priya@example.com>",
            "subject" => "Investor pack",
            "text_body" => "I'll send the revised investor pack by Monday morning.",
            "internal_date" => now,
            "account" => "kent@runner.now"
          }
        ],
        "status" => "ready",
        "fetched_at" => now
      })
      |> SourceBundle.put_calendar(%{"events" => [], "status" => "ready", "fetched_at" => now})

    state =
      CommitmentTracker.init(%{
        "user_id" => user_id,
        "timezone" => "America/Toronto",
        "timezone_offset_hours" => -4,
        "commitment_review_hour_local" => 7
      })

    context = %{
      agent_id: agent.id,
      user_id: user_id,
      timestamp: now,
      trigger: %{type: :wakeup},
      source_bundle: source_bundle,
      assistant_cycle_id: "cycle-commitment-fallback"
    }

    {:effect, {:llm_call, _params}, state} = CommitmentTracker.handle_wakeup(state, context)

    response = %{
      content:
        Jason.encode!(%{
          "title" => "Commitment tracker - 2026-05-09",
          "summary" => "One checked follow-up should be saved.",
          "body" =>
            "Open work review - 2026-05-09\n\nNew commitments:\n- Send Priya the revised investor pack by Monday morning.",
          "todos" => [
            %{
              "source" => "gmail",
              "title" => "Send Priya the revised investor pack",
              "summary" => "You owe Priya the revised investor pack by Monday morning.",
              "next_action" =>
                "Open the investor pack, confirm the revision, and send it to Priya.",
              "due_at" => "2026-05-11T13:00:00Z",
              "dedupe_key" => "commitment:gmail:thread-investor-pack",
              "source_account_label" => "kent@runner.now",
              "source_item_id" => "thread-investor-pack",
              "source_occurred_at" => "2026-05-09T15:00:00Z",
              "metadata" => %{
                "commitment_direction" => "i_owe",
                "source_ref" => "gmail thread-investor-pack",
                "quote" => "I'll send the revised investor pack by Monday morning."
              }
            }
          ]
        })
    }

    {:emit, {:briefs_recorded, payload}, _state} =
      CommitmentTracker.handle_effect_result({:llm_call, response}, state, context)

    assert payload.todo_count == 1
    assert payload.todo_skipped_count == 0

    [todo] = Todos.list_for_user(user_id, limit: 5)
    assert todo.title == "Send Priya the revised investor pack"

    assert todo.next_action ==
             "Open the investor pack, confirm the revision, and send it to Priya."

    assert todo.metadata["origin_skill_id"] == "commitment_tracker"

    [brief] = Briefs.list_recent_for_user(user_id, limit: 1)
    assert brief.body =~ "Added to open work:"
    assert brief.body =~ "- Send Priya the revised investor pack"
    refute brief.body =~ "found possible commitments"
    refute brief.body =~ "could not save them as open work"
    assert get_in(brief.metadata, ["todo_write", "todo_count"]) == 1
    assert payload.linked_todo_ids == [todo.id]
    assert brief.metadata["linked_todo_ids"] == [todo.id]
    assert brief.metadata["todo_digest"] == true
    assert brief.metadata["todo_digest_count"] == 1
  end
end
