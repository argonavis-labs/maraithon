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
end
