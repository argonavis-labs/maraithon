defmodule Maraithon.SourceLabelsTest do
  use ExUnit.Case, async: true

  alias Maraithon.SourceLabels

  test "labels common remote and local sources for product copy" do
    assert SourceLabels.label("gmail") == "Gmail"
    assert SourceLabels.label("google_calendar") == "Google Calendar"
    assert SourceLabels.label("voice_memos") == "Voice Memos"
    assert SourceLabels.label("browser_history") == "Browser History"
    assert SourceLabels.label("imessage") == "iMessage"
  end

  test "labels chief-of-staff sources without internal behavior names" do
    assert SourceLabels.label("chief_of_staff_commitment_tracker") == "Open work review"
    assert SourceLabels.label("chief_of_staff_morning_briefing") == "Morning briefing"
    assert SourceLabels.label("chief_of_staff_holiday") == "Holiday review"
    assert SourceLabels.label("chief_of_staff_weekend") == "Weekend review"
  end

  test "labels namespaced and unknown source keys without raw separators" do
    assert SourceLabels.label("gmail_thread:thread-123") == "Gmail"
    assert SourceLabels.label("open_loop_model") == "Open Loop Model"
    assert SourceLabels.label("custom-source") == "Custom Source"
    assert SourceLabels.label("", fallback: "Source") == "Source"
  end
end
