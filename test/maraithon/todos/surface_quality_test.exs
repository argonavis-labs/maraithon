defmodule Maraithon.Todos.SurfaceQualityTest do
  use ExUnit.Case, async: true

  alias Maraithon.Todos.SurfaceQuality

  test "generic commitment copy is not surfaceable even when source metadata exists" do
    quality =
      SurfaceQuality.assess(%{
        "id" => "todo-alex",
        "source" => "gmail",
        "attention_mode" => "act_now",
        "title" => "User committed to follow-up with Alex Müller; follow-up not yet sent.",
        "summary" => "User committed to follow-up with Alex Müller; follow-up not yet sent.",
        "next_action" =>
          "Reply now with owner, ETA, and the exact artifact or update you committed to.",
        "source_item_id" => "gmail-thread-alex-starteryou",
        "dedupe_key" => "gmail:alex-starteryou",
        "metadata" => %{
          "subject" => "Starteryou UGC Campaigns",
          "why_now" => "Deadline is today and no sent follow-up found.",
          "source_evidence" => "You said you would follow up on Starteryou UGC campaign timing.",
          "confidence" => 0.92,
          "record" => %{
            "person" => "Alex Müller",
            "company" => "Starteryou",
            "relationship_context" => "UGC campaign contact"
          }
        }
      })

    refute quality["surfaceable"]
    assert "personalized_copy" in quality["missing"]
    assert "generic_copy" in quality["warnings"]
  end

  test "personalized source-backed copy remains surfaceable" do
    quality =
      SurfaceQuality.assess(%{
        "id" => "todo-alex",
        "source" => "gmail",
        "attention_mode" => "act_now",
        "title" => "Follow up with Alex Müller about Starteryou UGC Campaigns",
        "summary" =>
          "You committed to follow up with Alex Müller (Starteryou) about Starteryou UGC Campaigns. Context: Alex is waiting on the UGC campaign materials decision.",
        "next_action" =>
          "Reply to Alex Müller about Starteryou UGC Campaigns with the promised update, current status, and a concrete ETA.",
        "source_item_id" => "gmail-thread-alex-starteryou",
        "dedupe_key" => "gmail:alex-starteryou",
        "metadata" => %{
          "subject" => "Starteryou UGC Campaigns",
          "why_now" => "Deadline is today and no sent follow-up found.",
          "source_evidence" => "You said you would follow up on Starteryou UGC campaign timing.",
          "confidence" => 0.92,
          "record" => %{
            "person" => "Alex Müller",
            "company" => "Starteryou",
            "relationship_context" => "UGC campaign contact"
          }
        }
      })

    assert quality["surfaceable"]
    refute "personalized_copy" in quality["missing"]
    refute "generic_copy" in quality["warnings"]
  end

  test "person-only follow-up is not surfaceable without what or why context" do
    quality =
      SurfaceQuality.assess(%{
        "id" => "todo-alex-thin",
        "source" => "gmail",
        "attention_mode" => "act_now",
        "title" => "Follow up with Alex Müller",
        "summary" => "You committed to follow up with Alex Müller.",
        "next_action" => "Reply to Alex Müller with the next step.",
        "source_item_id" => "gmail-thread-alex",
        "metadata" => %{
          "record" => %{"person" => "Alex Müller"},
          "confidence" => 0.72
        }
      })

    refute quality["surfaceable"]
    assert "specific_context" in quality["missing"]
  end
end
