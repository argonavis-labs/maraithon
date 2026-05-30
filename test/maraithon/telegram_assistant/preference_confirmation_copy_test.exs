defmodule Maraithon.TelegramAssistant.PreferenceConfirmationCopyTest do
  use ExUnit.Case, async: true

  alias Maraithon.TelegramAssistant.PreferenceConfirmationCopy

  test "renders direct approval copy for one pending preference" do
    text =
      PreferenceConfirmationCopy.text([
        %{
          "label" => "Treat investors as urgent",
          "instruction" =>
            "Treat investor-related loops as urgent across Gmail, Calendar, Slack, and Telegram."
        }
      ])

    assert text =~ "Remember this for future triage?"
    assert text =~ "Treat investors as urgent"
    assert text =~ "Reply `yes` to remember it"
    refute text =~ "I think"
    refute text =~ "durable memory"
    refute text =~ "preference rule"
  end

  test "renders saved and local-only outcome copy" do
    saved =
      PreferenceConfirmationCopy.saved_text([
        %{"label" => "Treat investors as urgent"},
        %{"label" => "Ignore receipt-style notifications"}
      ])

    assert saved =~ "Preferences saved:"
    assert saved =~ "Treat investors as urgent"
    assert saved =~ "Maraithon will apply them when ranking future work."
    refute saved =~ "Understood"
    refute saved =~ "I'll"

    assert PreferenceConfirmationCopy.local_only_text() ==
             "Got it. This stays in the conversation and will not be saved as a standing preference."

    assert PreferenceConfirmationCopy.no_pending_text() ==
             "There is no pending preference to approve or dismiss."

    assert PreferenceConfirmationCopy.failed_text() ==
             "Could not turn that into a clear standing preference yet. Send /prefer with the rule you want remembered."
  end

  test "escapes HTML in assistant approval prompts" do
    text =
      PreferenceConfirmationCopy.text(
        [
          %{
            "label" => "VIP <investors>",
            "instruction" => "Prioritize A&B threads."
          }
        ],
        format: :html
      )

    assert text =~ "VIP &lt;investors&gt;"
    assert text =~ "A&amp;B"
    assert text =~ "<code>yes</code>"
    assert text =~ "remember it"
    refute text =~ "<investors>"
  end
end
