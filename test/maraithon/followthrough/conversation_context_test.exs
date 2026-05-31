defmodule Maraithon.Followthrough.ConversationContextTest do
  use ExUnit.Case, async: true

  alias Maraithon.Followthrough.ConversationContext

  test "default unresolved summary is evidence-centered" do
    summary =
      ConversationContext.conversation_summary(%{"notification_posture" => "interrupt_now"})

    assert summary == "No later reply or delivery clearly closes the loop."
    refute summary =~ "I found"
  end

  test "insufficient context copy uses product language" do
    context = %{"notification_posture" => "insufficient_context"}

    summary = ConversationContext.conversation_summary(context)

    candidate =
      ConversationContext.apply_to_candidate(
        %{"title" => "Follow-up", "summary" => "Thread may need attention."},
        context
      )

    assert summary =~ "direct ask"
    assert candidate["recommended_action"] =~ "direct ask"
    refute summary =~ "debt"
    refute candidate["recommended_action"] =~ "debt"
  end

  test "acknowledgment-only follow-through stays visible as a heads-up" do
    trigger = %{
      "message_id" => "msg-1",
      "thread_id" => "thread-1",
      "from" => "David <david@example.com>",
      "to" => "kent@example.com",
      "subject" => "Board deck",
      "snippet" => "Can you send the updated board deck today?",
      "internal_date" => ~U[2026-05-31 10:00:00Z]
    }

    context =
      ConversationContext.from_gmail(
        [
          trigger,
          %{
            "message_id" => "msg-2",
            "thread_id" => "thread-1",
            "from" => "Charlie <charlie@example.com>",
            "to" => "kent@example.com",
            "subject" => "Re: Board deck",
            "snippet" => "Thanks, received.",
            "internal_date" => ~U[2026-05-31 10:20:00Z]
          }
        ],
        trigger,
        self_refs: ["kent@example.com"]
      )

    assert context["closure_state"] == "acknowledged"
    assert context["momentum_state"] == "active"
    assert context["notification_posture"] == "heads_up"

    candidate =
      ConversationContext.apply_to_candidate(
        %{
          "source" => "gmail",
          "category" => "reply_urgent",
          "title" => "Reply owed: Board deck",
          "summary" => "David is waiting on the board deck.",
          "recommended_action" => "Reply to David.",
          "priority" => 88,
          "confidence" => 0.9
        },
        context
      )

    assert candidate["title"] == "Gmail thread moving with Charlie"
    assert candidate["summary"] =~ "Charlie acknowledged the thread"
    assert candidate["summary"] =~ "No immediate action is required from you right now."
    assert candidate["recommended_action"] =~ "Monitor the thread"
    assert candidate["metadata"]["interrupt_now"] == false
  end

  test "completion language still resolves follow-through" do
    trigger = %{
      "message_id" => "msg-1",
      "thread_id" => "thread-1",
      "from" => "David <david@example.com>",
      "to" => "kent@example.com",
      "subject" => "Board deck",
      "snippet" => "Can you send the updated board deck today?",
      "internal_date" => ~U[2026-05-31 10:00:00Z]
    }

    context =
      ConversationContext.from_gmail(
        [
          trigger,
          %{
            "message_id" => "msg-2",
            "thread_id" => "thread-1",
            "from" => "Charlie <charlie@example.com>",
            "to" => "kent@example.com",
            "subject" => "Re: Board deck",
            "snippet" => "Done, I shared it with the board.",
            "internal_date" => ~U[2026-05-31 10:20:00Z]
          }
        ],
        trigger,
        self_refs: ["kent@example.com"]
      )

    assert context["closure_state"] == "resolved"
    assert context["momentum_state"] == "resolved"
    assert context["notification_posture"] == "resolved"
  end
end
