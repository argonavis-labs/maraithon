defmodule Maraithon.GoalsTest do
  use Maraithon.DataCase, async: true

  alias Maraithon.Accounts
  alias Maraithon.Goals
  alias Maraithon.Todos

  setup do
    email = "goals-#{System.unique_integer([:positive])}@example.com"
    {:ok, user} = Accounts.get_or_create_user_by_email(email)
    %{user: user}
  end

  test "creates goals with category defaults and exposes bounded context", %{user: user} do
    now = ~U[2026-06-13 12:00:00Z]

    assert {:ok, work_goal} =
             Goals.create_goal(
               user.id,
               %{
                 "category" => "work",
                 "title" => "Ship Goals tab",
                 "desired_outcome" => "Maraithon has a durable goals surface."
               },
               now: now
             )

    assert work_goal.status == "active"
    assert work_goal.sensitivity == "standard"
    assert work_goal.proactive_visibility == "summary"
    assert DateTime.compare(work_goal.next_review_at, DateTime.add(now, 7, :day)) == :eq

    assert {:ok, private_goal} =
             Goals.create_goal(
               user.id,
               %{
                 "category" => "life",
                 "title" => "Keep a private life goal",
                 "desired_outcome" => "This should not appear in broad context.",
                 "sensitivity" => "private"
               },
               now: now
             )

    snapshot = Goals.context_snapshot(user.id, now: now)

    assert get_in(snapshot, ["counts", "active"]) == 2
    assert Enum.any?(snapshot["active_goals"], &(&1["id"] == work_goal.id))
    refute Enum.any?(snapshot["active_goals"], &(&1["id"] == private_goal.id))
  end

  test "records progress, links open work, and includes it in open-loop goals", %{user: user} do
    assert {:ok, goal} =
             Goals.create_goal(user.id, %{
               "category" => "work",
               "title" => "Improve launch follow-through",
               "desired_outcome" => "Every launch thread has a clear next move."
             })

    assert {:ok, progress} =
             Goals.record_progress(user.id, goal.id, %{
               "summary" => "Launch follow-up is blocked on a reply.",
               "progress_state" => "blocked"
             })

    assert progress.progress_state == "blocked"

    assert {:ok, [todo]} =
             Todos.upsert_many(user.id, [
               %{
                 "source" => "goals",
                 "title" => "Reply on launch follow-through",
                 "summary" => "A goal-linked next move should stay visible.",
                 "next_action" => "Send the launch follow-up reply.",
                 "status" => "open"
               }
             ])

    assert {:ok, link} =
             Goals.link_resource(user.id, goal.id, %{
               "resource_type" => "todo",
               "resource_id" => todo.id,
               "relationship" => "next_move"
             })

    assert link.resource_id == todo.id

    open_loop_goals = Goals.open_loop_snapshot(user.id)

    assert Enum.any?(open_loop_goals.at_risk_goals, &(&1["id"] == goal.id))
    assert [%{goal: %{id: goal_id}, todo: %{id: todo_id}}] = open_loop_goals.linked_open_work
    assert goal_id == goal.id
    assert todo_id == todo.id
  end

  test "public goal writes cannot spoof internal review state", %{user: user} do
    now = ~U[2026-06-13 12:00:00Z]
    spoof_reviewed_at = ~U[2001-02-03 04:05:06Z]
    spoof_next_review_at = ~U[2099-01-01 00:00:00Z]

    assert {:ok, goal} =
             Goals.create_goal(
               user.id,
               %{
                 "category" => "work",
                 "title" => "Keep review state owned by Maraithon",
                 "desired_outcome" => "Public writes cannot forge review metadata.",
                 "last_reviewed_at" => spoof_reviewed_at,
                 "next_review_at" => spoof_next_review_at,
                 "metadata" => %{"unsafe" => true}
               },
               now: now
             )

    assert goal.last_reviewed_at == nil
    assert DateTime.compare(goal.next_review_at, DateTime.add(now, 7, :day)) == :eq
    assert goal.metadata == %{}

    assert {:ok, public_update} =
             Goals.update_goal(user.id, goal.id, %{
               "last_reviewed_at" => spoof_reviewed_at,
               "next_review_at" => spoof_next_review_at,
               "metadata" => %{"unsafe" => true}
             })

    assert public_update.last_reviewed_at == nil
    assert DateTime.compare(public_update.next_review_at, goal.next_review_at) == :eq
    assert public_update.metadata == %{}

    assert {:ok, internal_update} =
             Goals.update_goal(
               user.id,
               goal.id,
               %{
                 "last_reviewed_at" => spoof_reviewed_at,
                 "next_review_at" => spoof_next_review_at,
                 "metadata" => %{"review_source" => "goal_alignment"}
               },
               allow_internal_fields: true
             )

    assert DateTime.compare(internal_update.last_reviewed_at, spoof_reviewed_at) == :eq
    assert DateTime.compare(internal_update.next_review_at, spoof_next_review_at) == :eq
    assert internal_update.metadata == %{"review_source" => "goal_alignment"}
  end

  test "review output skips invalid candidates while preserving valid output", %{user: user} do
    now = ~U[2026-06-13 12:00:00Z]

    assert {:ok, goal} =
             Goals.create_goal(
               user.id,
               %{
                 "category" => "work",
                 "title" => "Ship source-backed goal reviews",
                 "desired_outcome" => "Connected data becomes useful goal advice."
               },
               now: now
             )

    assert {:ok, run} =
             Goals.record_review_run(
               user.id,
               %{
                 "goal_id" => goal.id,
                 "trigger" => "scheduled",
                 "status" => "running",
                 "source_summary" => %{"sources" => ["goals", "notes"]},
                 "metadata" => %{"mode" => "test"}
               },
               now: now
             )

    output = %{
      "progress_updates" => [
        %{
          "goal_id" => goal.id,
          "summary" => "The launch thread is blocked on a pricing artifact.",
          "progress_state" => "blocked",
          "confidence" => 0.86,
          "evidence" => %{"source_refs" => ["notes:n1"]}
        }
      ],
      "resource_links" => [
        %{
          "goal_id" => goal.id,
          "resource_type" => "todo",
          "resource_id" => Ecto.UUID.generate(),
          "relationship" => "next_move"
        },
        %{
          "goal_id" => goal.id,
          "resource_type" => "source_observation",
          "resource_id" => "notes:n1",
          "relationship" => "evidence"
        }
      ],
      "todo_candidates" => [
        %{
          "goal_id" => goal.id,
          "title" => "Finish the pricing artifact",
          "summary" => "The pricing conversation needs a concrete artifact to unblock launch.",
          "next_action" => "Draft and send the pricing artifact to the launch thread.",
          "priority" => 88,
          "confidence" => 0.91,
          "evidence" => %{
            "redacted_summary" => "A connected note says pricing is blocking launch.",
            "source_refs" => ["notes:n1"]
          }
        },
        %{
          "goal_id" => goal.id,
          "title" => "Too vague",
          "summary" => "Missing evidence should not stop useful candidates.",
          "next_action" => "Review this malformed candidate."
        },
        %{
          "goal_id" => goal.id,
          "title" => "Do not leave orphaned goal work",
          "summary" => "This candidate has evidence but an invalid link confidence.",
          "next_action" => "Confirm invalid linked goal work is not persisted.",
          "priority" => 70,
          "confidence" => 1.7,
          "evidence" => %{
            "redacted_summary" => "A connected note says this candidate should fail linking.",
            "source_refs" => ["notes:n2"]
          }
        }
      ],
      "advice" => [
        %{
          "goal_id" => goal.id,
          "headline" => "Unblock pricing",
          "summary" => "Send the pricing artifact so launch can move.",
          "source_refs" => ["notes:n1"],
          "confidence" => 0.91,
          "urgency" => "now"
        },
        %{
          "goal_id" => goal.id,
          "headline" => "Generic motivation",
          "summary" => "Try harder on the goal this week.",
          "confidence" => 0.91,
          "urgency" => "soon"
        },
        %{
          "goal_id" => goal.id,
          "headline" => "Malformed summary",
          "summary" => %{"nested" => "not text"},
          "source_refs" => ["notes:n1"],
          "confidence" => 0.88,
          "urgency" => "soon"
        }
      ],
      "findings" => [
        %{
          "goal_id" => goal.id,
          "kind" => "blocks",
          "summary" => "The pricing artifact is the current source-backed blocker.",
          "source_refs" => ["notes:n1"],
          "confidence" => 0.9
        },
        %{
          "goal_id" => goal.id,
          "kind" => "opportunity",
          "summary" => "This ungrounded finding should not be saved.",
          "confidence" => 0.88
        }
      ],
      "reviewed_goal_ids" => [goal.id]
    }

    assert {:ok, applied} = Goals.apply_review_output(user.id, run.id, output, now: now)

    assert applied.review_run.status == "partial"
    assert applied.summary["progress_updates_count"] == 1
    assert applied.summary["links_count"] == 2
    assert applied.summary["todos_count"] == 1
    assert applied.summary["skipped_outputs_count"] == 6

    assert [
             "advice",
             "advice",
             "finding",
             "resource_link",
             "todo_candidate",
             "todo_candidate"
           ] =
             applied.summary["skipped_outputs"]
             |> Enum.map(& &1["kind"])
             |> Enum.sort()

    assert Enum.any?(
             applied.summary["skipped_outputs"],
             &(&1["kind"] == "todo_candidate" and
                 &1["reason"] == "invalid_goal_todo_candidate_confidence")
           )

    assert Enum.any?(
             applied.summary["skipped_outputs"],
             &(&1["kind"] == "advice" and &1["reason"] == "review_advice_missing_source_refs")
           )

    assert Enum.any?(
             applied.summary["skipped_outputs"],
             &(&1["kind"] == "advice" and &1["reason"] == "invalid_review_advice")
           )

    assert Enum.any?(
             applied.summary["skipped_outputs"],
             &(&1["kind"] == "finding" and
                 &1["reason"] == "review_finding_missing_source_refs")
           )

    assert [todo] = Todos.list_for_user(user.id, source: "goals", limit: 5)
    assert todo.title == "Finish the pricing artifact"
    assert todo.next_action == "Draft and send the pricing artifact to the launch thread."
    assert get_in(todo.metadata, ["surface_quality", "surfaceable"]) == true
    assert get_in(todo.metadata, ["surface_quality", "source_backed"]) == true

    detail = Goals.get_goal(user.id, goal.id)
    assert Enum.any?(detail.progress_updates, &(&1.progress_state == "blocked"))
    assert Enum.any?(detail.links, &(&1.resource_type == "source_observation"))
    assert Enum.any?(detail.links, &(&1.resource_type == "todo" and &1.resource_id == todo.id))

    review_run = Enum.find(detail.review_runs, &(&1.id == run.id))
    assert review_run.status == "partial"
    assert review_run.result["skipped_outputs_count"] == 6
    assert [%{"headline" => "Unblock pricing"}] = review_run.result["advice"]

    assert [
             %{
               "kind" => "blocks",
               "summary" => "The pricing artifact is the current source-backed blocker."
             }
           ] =
             review_run.result["findings"]
  end

  test "reviewing a missing selected goal fails closed", %{user: user} do
    assert {:error, :not_found} =
             Goals.review_goal_alignment(user.id,
               goal_id: Ecto.UUID.generate(),
               trigger: "manual"
             )
  end
end
