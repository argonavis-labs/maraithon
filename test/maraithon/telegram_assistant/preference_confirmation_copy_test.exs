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

    assert text =~ "Save this preference?"
    assert text =~ "Treat investors as urgent"
    assert text =~ "Reply `yes` to save"
    refute text =~ "I think"
    refute text =~ "durable memory"
  end

  test "renders saved and local-only outcome copy" do
    saved =
      PreferenceConfirmationCopy.saved_text([
        %{"label" => "Treat investors as urgent"},
        %{"label" => "Ignore receipt-style notifications"}
      ])

    assert saved =~ "Preferences saved:"
    assert saved =~ "Treat investors as urgent"
    assert saved =~ "Future triage will apply them automatically."
    refute saved =~ "Understood"
    refute saved =~ "I'll"

    assert PreferenceConfirmationCopy.local_only_text() ==
             "Kept as local feedback. No saved preference rule added."
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
    refute text =~ "<investors>"
  end
end
