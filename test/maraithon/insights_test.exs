defmodule Maraithon.InsightsTest do
  use Maraithon.DataCase, async: true

  alias Maraithon.Accounts
  alias Maraithon.Agents
  alias Maraithon.InsightNotifications.Delivery
  alias Maraithon.Insights
  alias Maraithon.Todos

  setup do
    user_id = "insights-user-#{System.unique_integer([:positive])}@example.com"
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

    {:ok, agent} =
      Agents.create_agent(%{
        user_id: user_id,
        behavior: "prompt_agent",
        config: %{}
      })

    %{user_id: user_id, agent: agent}
  end

  describe "record_many/3" do
    test "inserts and upserts by dedupe key", %{user_id: user_id, agent: agent} do
      {:ok, [first]} =
        Insights.record_many(user_id, agent.id, [
          %{
            "source" => "gmail",
            "category" => "reply_urgent",
            "title" => "Reply to contract email",
            "summary" => "The sender asks for a same-day reply.",
            "recommended_action" => "Reply before end of day.",
            "priority" => 72,
            "confidence" => 0.81,
            "dedupe_key" => "email:abc:reply_urgent"
          }
        ])

      assert first.status == "new"
      assert first.priority == 72

      {:ok, _} = Insights.acknowledge(user_id, first.id)

      {:ok, [updated]} =
        Insights.record_many(user_id, agent.id, [
          %{
            "source" => "gmail",
            "category" => "reply_urgent",
            "title" => "Reply to contract email now",
            "summary" => "Escalation risk if ignored.",
            "recommended_action" => "Send acknowledgment and timeline.",
            "priority" => 92,
            "confidence" => 0.93,
            "dedupe_key" => "email:abc:reply_urgent"
          }
        ])

      assert updated.id == first.id
      assert updated.status == "new"
      assert updated.priority == 92
      assert updated.title == "Reply to contract email now"
    end

    test "dismisses prior open revisions that share a tracking key", %{
      user_id: user_id,
      agent: agent
    } do
      {:ok, [first]} =
        Insights.record_many(user_id, agent.id, [
          %{
            "source" => "gmail",
            "category" => "reply_urgent",
            "title" => "Monitoring investor thread",
            "summary" => "Keep watching the investor thread for movement.",
            "recommended_action" => "Watch for a blocker or a direct ask back to you.",
            "priority" => 75,
            "confidence" => 0.82,
            "attention_mode" => "monitor",
            "dedupe_key" => "thread-1:rev-1",
            "tracking_key" => "thread-1"
          }
        ])

      {:ok, [second]} =
        Insights.record_many(user_id, agent.id, [
          %{
            "source" => "gmail",
            "category" => "reply_urgent",
            "title" => "Monitoring investor thread again",
            "summary" => "The thread changed and still needs monitoring.",
            "recommended_action" => "Keep watching for a blocker or a handoff.",
            "priority" => 81,
            "confidence" => 0.87,
            "attention_mode" => "monitor",
            "dedupe_key" => "thread-1:rev-2",
            "tracking_key" => "thread-1"
          }
        ])

      first = Repo.get!(Maraithon.Insights.Insight, first.id)
      second = Repo.get!(Maraithon.Insights.Insight, second.id)

      assert first.status == "dismissed"
      assert second.status == "new"
      assert second.attention_mode == "monitor"
      assert second.tracking_key == "thread-1"
      assert Enum.map(Insights.list_open_monitor_for_user(user_id), & &1.id) == [second.id]

      [todo] = Todos.list_open_for_user(user_id)
      assert todo.title == "Monitoring investor thread again"
      assert todo.dedupe_key == "insight:thread-1"
      assert get_in(todo.metadata, ["source_insight_id"]) == second.id
      assert Enum.count(Todos.list_recent_for_user(user_id)) == 1
    end

    test "recorded insights are mirrored into todos and todo resolution closes the insight", %{
      user_id: user_id,
      agent: agent
    } do
      due_at = DateTime.add(DateTime.utc_now(), 2, :hour)

      {:ok, [insight]} =
        Insights.record_many(user_id, agent.id, [
          %{
            "source" => "gmail",
            "category" => "reply_urgent",
            "title" => "Reply to the billing thread",
            "summary" => "Billing needs a same-day response with the account owner and ETA.",
            "recommended_action" => "Reply in-thread now with the payment status.",
            "priority" => 88,
            "confidence" => 0.91,
            "due_at" => due_at,
            "dedupe_key" => "billing-thread:rev-1",
            "tracking_key" => "billing-thread",
            "source_id" => "thread-billing",
            "metadata" => %{
              "thread_id" => "thread-billing",
              "subject" => "Billing account past due",
              "draft_plan" => "Reply in your voice with payment status, owner, and ETA.",
              "google_account_email" => "ops@example.com"
            }
          }
        ])

      [todo] = Todos.list_open_for_user(user_id, kind: "gmail_triage")
      assert todo.title == "Reply to the billing thread"
      assert todo.dedupe_key == "insight:billing-thread"
      assert DateTime.compare(todo.due_at, due_at) == :eq

      assert todo.action_plan ==
               "Draft in your voice: reply to the recipient about Billing account past due with the actual promise, current status, and timing you can safely stand behind."

      assert todo.source_account_label == "ops@example.com"
      assert get_in(todo.metadata, ["source_insight_id"]) == insight.id

      assert {:ok, _done_todo} =
               Todos.mark_done(user_id, todo.id, note: "Handled with the finance team.")

      updated_insight = Repo.get!(Maraithon.Insights.Insight, insight.id)

      assert updated_insight.status == "acknowledged"
      assert get_in(updated_insight.metadata, ["todo_resolution", "status"]) == "done"

      assert get_in(updated_insight.metadata, ["todo_resolution", "note"]) ==
               "Handled with the finance team."
    end

    test "polishes user-facing insight copy before storing it", %{
      user_id: user_id,
      agent: agent
    } do
      {:ok, [insight]} =
        Insights.record_many(user_id, agent.id, [
          %{
            "source" => "gmail",
            "category" => "reply_urgent",
            "title" => "Reply to legal",
            "summary" => "No later reply was found.",
            "recommended_action" => "Reply now with owner and ETA.",
            "metadata" => %{
              "why_now" => "Michael is waiting and no later reply was found.",
              "decision_prompt" => "Decide whether to send the campaign owner and ETA."
            },
            "dedupe_key" => "copy:polished"
          }
        ])

      assert insight.summary == "No later reply is recorded."
      assert insight.recommended_action == "Reply with a clear owner and timing."

      assert insight.metadata["why_now"] ==
               "Michael is waiting; no later reply is recorded."

      assert insight.metadata["decision_prompt"] ==
               "Send the campaign update with a clear owner and timing."
    end

    test "default Slack draft plan avoids internal loop language", %{
      user_id: user_id,
      agent: agent
    } do
      {:ok, [insight]} =
        Insights.record_many(user_id, agent.id, [
          %{
            "source" => "slack",
            "category" => "commitment_unresolved",
            "title" => "Send the launch timing to Priya",
            "summary" => "Priya is waiting on launch timing.",
            "recommended_action" => "Reply in the Slack thread with timing.",
            "metadata" => %{
              "record" => %{
                "person" => "Priya",
                "source" => "slack",
                "status" => "unresolved"
              }
            },
            "dedupe_key" => "copy:slack-draft-plan"
          }
        ])

      assert insight.metadata["draft_plan"] =~ "send the Slack follow-through to Priya"
      refute insight.metadata["draft_plan"] =~ "Slack loop"
      refute insight.metadata["draft_plan"] =~ "close the loop"
    end

    test "insight snooze and dismiss propagate to the mirrored todo", %{
      user_id: user_id,
      agent: agent
    } do
      {:ok, [insight]} =
        Insights.record_many(user_id, agent.id, [
          %{
            "source" => "calendar",
            "category" => "event_prep_needed",
            "title" => "Prep for board meeting",
            "summary" => "Board meeting prep still needs to happen.",
            "recommended_action" => "Draft the board talk track before tomorrow morning.",
            "priority" => 73,
            "confidence" => 0.8,
            "dedupe_key" => "calendar:board-prep"
          }
        ])

      [todo] = Todos.list_open_for_user(user_id, kind: "general")
      snooze_until = DateTime.add(DateTime.utc_now(), 4, :hour)

      assert {:ok, _insight} = Insights.snooze(user_id, insight.id, snooze_until)

      todo = Repo.get!(Maraithon.Todos.Todo, todo.id)
      assert todo.status == "snoozed"
      assert DateTime.compare(todo.snoozed_until, snooze_until) == :eq

      assert {:ok, _insight} = Insights.dismiss(user_id, insight.id)

      todo = Repo.get!(Maraithon.Todos.Todo, todo.id)
      assert todo.status == "dismissed"
    end
  end

  describe "list_open_for_user/2" do
    test "hides future-snoozed insights and shows active ones", %{user_id: user_id, agent: agent} do
      {:ok, [snoozed]} =
        Insights.record_many(user_id, agent.id, [
          %{
            "source" => "calendar",
            "category" => "event_prep_needed",
            "title" => "Prep for board meeting",
            "summary" => "Board meeting prep needed.",
            "recommended_action" => "Draft key talking points.",
            "dedupe_key" => "calendar:1:event_prep_needed"
          }
        ])

      {:ok, [_active]} =
        Insights.record_many(user_id, agent.id, [
          %{
            "source" => "gmail",
            "category" => "reply_urgent",
            "title" => "Reply to legal",
            "summary" => "Legal requested immediate response.",
            "recommended_action" => "Reply and confirm receipt.",
            "dedupe_key" => "email:2:reply_urgent"
          }
        ])

      {:ok, _} = Insights.snooze(user_id, snoozed.id, DateTime.add(DateTime.utc_now(), 4, :hour))

      open = Insights.list_open_for_user(user_id)
      open_ids = Enum.map(open, & &1.id)

      refute snoozed.id in open_ids
      assert length(open_ids) == 1
    end

    test "filters act-now and monitor insights separately", %{user_id: user_id, agent: agent} do
      {:ok, [act_now]} =
        Insights.record_many(user_id, agent.id, [
          %{
            "source" => "gmail",
            "category" => "reply_urgent",
            "title" => "Reply to legal",
            "summary" => "Legal requested an immediate reply.",
            "recommended_action" => "Reply now with owner and ETA.",
            "dedupe_key" => "mode:act-now"
          }
        ])

      {:ok, [monitor]} =
        Insights.record_many(user_id, agent.id, [
          %{
            "source" => "gmail",
            "category" => "reply_urgent",
            "title" => "Monitor investor thread",
            "summary" => "The investor thread is active, but no direct action is required now.",
            "recommended_action" => "Watch for a blocker or a direct ask back to you.",
            "attention_mode" => "monitor",
            "dedupe_key" => "mode:monitor",
            "tracking_key" => "mode:monitor"
          }
        ])

      assert Enum.map(Insights.list_open_act_now_for_user(user_id), & &1.id) == [act_now.id]
      assert Enum.map(Insights.list_open_monitor_for_user(user_id), & &1.id) == [monitor.id]
      assert act_now.recommended_action == "Reply with a clear owner and timing."
    end
  end

  describe "list_open_with_details_for_user/2" do
    test "preserves ordering and loads related delivery detail", %{user_id: user_id, agent: agent} do
      {:ok, [first]} =
        Insights.record_many(user_id, agent.id, [
          %{
            "source" => "gmail",
            "category" => "commitment_unresolved",
            "title" => "Send the pricing doc to Sarah",
            "summary" => "The pricing doc still appears open.",
            "recommended_action" => "Send the pricing doc now.",
            "priority" => 95,
            "confidence" => 0.92,
            "dedupe_key" => "detail:first",
            "metadata" => %{
              "record" => %{
                "commitment" => "Send the pricing doc to Sarah",
                "person" => "Sarah",
                "status" => "unresolved",
                "evidence" => ["No follow-up email was found."],
                "next_action" => "Send the promised follow-through now."
              }
            }
          }
        ])

      {:ok, [second]} =
        Insights.record_many(user_id, agent.id, [
          %{
            "source" => "calendar",
            "category" => "meeting_follow_up",
            "title" => "Send the board recap",
            "summary" => "The board recap still appears open.",
            "recommended_action" => "Send owners and next steps.",
            "priority" => 70,
            "confidence" => 0.75,
            "dedupe_key" => "detail:second"
          }
        ])

      {:ok, _delivery} =
        %Delivery{}
        |> Delivery.changeset(%{
          insight_id: first.id,
          user_id: user_id,
          channel: "telegram",
          destination: "12345",
          score: 0.95,
          threshold: 0.8,
          status: "sent",
          sent_at: DateTime.utc_now()
        })
        |> Repo.insert()

      cards = Insights.list_open_with_details_for_user(user_id)

      assert Enum.map(cards, & &1.insight.id) == [first.id, second.id]
      assert hd(cards).detail.promise_text.text == "Send the pricing doc to Sarah"
      assert hd(cards).detail.delivery_evidence != []
      assert List.last(cards).detail.delivery_evidence == []
    end
  end

  describe "status updates" do
    test "returns not_found for unknown insight id", %{user_id: user_id} do
      assert {:error, :not_found} = Insights.acknowledge(user_id, Ecto.UUID.generate())
      assert {:error, :not_found} = Insights.dismiss(user_id, Ecto.UUID.generate())

      assert {:error, :not_found} =
               Insights.snooze(user_id, Ecto.UUID.generate(), DateTime.utc_now())
    end
  end
end
