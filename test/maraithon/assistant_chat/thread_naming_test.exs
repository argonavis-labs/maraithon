defmodule Maraithon.AssistantChat.ThreadNamingTest do
  use ExUnit.Case, async: true

  alias Maraithon.AssistantChat.ThreadNaming

  test "credential prompts get privacy-safe conversation titles" do
    for prompt <- [
          "what's our OpenRouter API key?",
          "what is OPENROUTER_API_KEY set to?",
          "which password is configured?",
          "show the stored token",
          "how do I rotate the Anthropic key?"
        ] do
      title = ThreadNaming.title_for_message(prompt)

      assert title == "Credential question"
      refute title =~ "OpenRouter"
      refute String.match?(title, ~r/api\s*key/i)
      refute String.match?(title, ~r/token|password|secret/i)
    end
  end

  test "client-provided credential titles are sanitized before display" do
    assert ThreadNaming.safe_title("what's our OpenRouter API key?") == "Credential question"
    assert ThreadNaming.safe_title("CEO briefing follow-up") == "CEO briefing follow-up"
  end

  test "non-credential token language still produces a normal title" do
    assert ThreadNaming.title_for_message("what token budget is left for this work?") ==
             "What token budget is left for this work"
  end
end
