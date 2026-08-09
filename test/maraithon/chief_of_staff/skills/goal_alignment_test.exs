defmodule Maraithon.ChiefOfStaff.Skills.GoalAlignmentTest do
  use Maraithon.DataCase, async: true

  alias Maraithon.Accounts
  alias Maraithon.ChiefOfStaff.SourceBundle
  alias Maraithon.ChiefOfStaff.Skills
  alias Maraithon.ChiefOfStaff.Skills.GoalAlignment
  alias Maraithon.Goals
  alias Maraithon.Todos

  setup do
    email = "goal-alignment-#{System.unique_integer([:positive])}@example.com"
    {:ok, user} = Accounts.get_or_create_user_by_email(email)
    %{user: user}
  end

  test "is registered and enabled by default" do
    assert Skills.get("goal_alignment") == GoalAlignment
    assert "goal_alignment" in Skills.default_enabled_ids()
  end

  test "scheduled wakeup reviews due goals against connected context and saves high-quality output",
       %{user: user} do
    now = ~U[2026-06-13 12:00:00Z]

    {:ok, goal} =
      Goals.create_goal(
        user.id,
        %{
          "category" => "work",
          "title" => "Review goal alignment",
          "desired_outcome" => "Due goals are checked routinely.",
          "review_cadence" => "daily"
        },
        now: DateTime.add(now, -2, :day)
      )

    state = GoalAlignment.init(%{"user_id" => user.id, "review_interval_hours" => 1})

    source_bundle =
      %{trigger: %{type: :wakeup}, timestamp: now}
      |> SourceBundle.empty(%{})
      |> SourceBundle.put_notes(%{
        "notes" => [
          %{
            "note_id" => "n1",
            "title" => "Launch follow-up",
            "summary" => "Pricing thread is blocked until the Goals review artifact ships."
          }
        ],
        "status" => "ready",
        "fetched_at" => now
      })

    assert {:effect, {:llm_call, params}, pending_state} =
             GoalAlignment.handle_wakeup(state, %{
               user_id: user.id,
               timestamp: now,
               trigger: %{type: :wakeup},
               source_bundle: source_bundle
             })

    assert pending_state.last_reviewed_at == now
    assert pending_state.pending_goal_ids == [goal.id]
    prompt = params["messages"] |> hd() |> Map.fetch!("content")
    assert prompt =~ "all connected context"
    assert prompt =~ "Launch follow-up"

    model_output =
      Jason.encode!(%{
        "findings" => [
          %{
            "goal_id" => goal.id,
            "kind" => "blocks",
            "summary" =>
              "The launch pricing thread is blocked by the missing Goals review artifact.",
            "source_refs" => ["notes:n1"],
            "confidence" => 0.92
          }
        ],
        "advice" => [
          %{
            "goal_id" => goal.id,
            "headline" => "Unblock the pricing thread",
            "summary" =>
              "Ship the review artifact first; it is the current blocker for launch follow-through.",
            "urgency" => "now",
            "source_refs" => ["notes:n1"],
            "confidence" => 0.91
          }
        ],
        "progress_updates" => [
          %{
            "goal_id" => goal.id,
            "summary" => "Launch follow-through is blocked on the Goals review artifact.",
            "progress_state" => "blocked",
            "confidence" => 0.91,
            "evidence" => %{
              "redacted_summary" =>
                "A local note says the pricing thread is blocked until the Goals review artifact ships.",
              "source_refs" => ["notes:n1"]
            }
          }
        ],
        "resource_links" => [
          %{
            "goal_id" => goal.id,
            "resource_type" => "source_observation",
            "resource_id" => "notes:n1",
            "relationship" => "blocks",
            "confidence" => 0.91,
            "metadata" => %{"reason" => "The note identifies the blocker."}
          }
        ],
        "todo_candidates" => [
          %{
            "goal_id" => goal.id,
            "title" => "Finish the Goals review artifact",
            "summary" =>
              "The launch pricing thread is blocked until the Goals review artifact ships.",
            "next_action" => "Finish and share the Goals review artifact so pricing can move.",
            "priority" => 86,
            "attention_mode" => "act_now",
            "confidence" => 0.91,
            "evidence" => %{
              "redacted_summary" =>
                "A local note says pricing is blocked until the Goals review artifact ships.",
              "source_refs" => ["notes:n1"]
            }
          }
        ]
      })

    assert {:emit,
            {:goal_alignment_reviewed,
             %{
               count: 1,
               review_run_ids: [review_run_id],
               progress_updates_count: 1,
               todos_count: 1,
               advice_count: 1
             }},
            next_state} =
             GoalAlignment.handle_effect_result(
               {:llm_call, %{content: model_output}},
               pending_state,
               %{}
             )

    assert next_state.pending_review_run_id == nil

    reviewed_goal = Goals.get_goal(user.id, goal.id, preload: false)
    assert DateTime.compare(reviewed_goal.last_reviewed_at, now) == :eq

    [todo] = Todos.list_for_user(user.id, source: "goals", limit: 5)
    assert todo.title == "Finish the Goals review artifact"
    assert todo.next_action == "Finish and share the Goals review artifact so pricing can move."

    detail = Goals.get_goal(user.id, goal.id)
    assert Enum.any?(detail.review_runs, &(&1.id == review_run_id and &1.status == "completed"))
    assert Enum.any?(detail.progress_updates, &(&1.progress_state == "blocked"))
    assert Enum.any?(detail.links, &(&1.resource_type == "todo" and &1.resource_id == todo.id))

    review_run = Enum.find(detail.review_runs, &(&1.id == review_run_id))
    assert [%{"headline" => "Unblock the pricing thread"}] = review_run.result["advice"]
  end
end
