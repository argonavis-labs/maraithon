defmodule Maraithon.AssistantChat.DirectIntentTest do
  use ExUnit.Case, async: true

  alias Maraithon.AssistantChat.DirectIntent

  test "classifies tiny social turns as fast chat replies" do
    assert {:ok, %{type: :fast_chat_reply, kind: :greeting, reply: "Hey - I'm here."}} =
             DirectIntent.classify("Hey")

    assert {:ok, %{type: :fast_chat_reply, kind: :acknowledgement, reply: "Got it."}} =
             DirectIntent.classify("sounds good")

    assert {:ok, %{type: :fast_chat_reply, kind: :thanks, reply: "Anytime."}} =
             DirectIntent.classify("Thank you!")
  end

  test "does not classify context-bearing prompts as fast chat" do
    for text <- [
          "Hey what todos need my attention?",
          "Thanks, which contacts are stale?",
          "Ok who should I follow up with?",
          "Hello, what meetings are on my calendar?"
        ] do
      assert DirectIntent.classify(text) == :nomatch
    end
  end
end
