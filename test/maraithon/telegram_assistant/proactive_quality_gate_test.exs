defmodule Maraithon.TelegramAssistant.ProactiveQualityGateTest do
  use ExUnit.Case, async: true

  alias Maraithon.TelegramAssistant.ProactiveQualityGate

  test "rewrites stale backlog dumps into one confirmation item" do
    plan = %{
      "decision" => "send_now",
      "assistant_message" => """
      You have several overdue follow-ups that need your attention:
      • Dan Bourke: confirm the artifact status and give a concrete ETA.
      • Matthew Diakonov: confirm the artifact status and give a concrete ETA.
      • Faye Pang: update on shared materials and next steps.
      • Halah AlQahtani: confirm introduction and follow-up status.
      • Matthew Raue: reply about setup help and pricing with owner and ETA.
      • Renat Gabitov: clarify video partner decision and provide ETA.
      Also, several recent meetings need a follow-up recap with owners and next steps, including Emma's Soccer Practice and Boardy Pro Kickoff.
      Prioritize sending these follow-ups now to keep commitments on track and maintain relationships.
      """,
      "message_class" => "assistant_push",
      "urgency" => 0.91,
      "interrupt_now" => true,
      "todo_ids" => ["dan"],
      "summary" => "Several overdue follow-ups need attention."
    }

    payload = %{
      trigger: %{"local_time" => %{"weekend" => true}},
      context: %{
        todos: [
          %{
            id: "dan",
            title: "Dan Bourke: confirm artifact status and ETA",
            summary: "This old follow-up may no longer be important.",
            priority: 40,
            source_occurred_at: "2026-05-01T14:00:00Z",
            metadata: %{
              "record" => %{
                "person" => "Dan Bourke",
                "company" => "A-Team",
                "relationship_context" => "video project contact"
              }
            }
          }
        ]
      }
    }

    verified = ProactiveQualityGate.verify_proactive_plan(plan, payload)

    assert verified["decision"] == "send_now"
    assert verified["message_class"] == "todo_digest"
    assert verified["todo_ids"] == ["dan"]
    assert verified["assistant_message"] =~ "Older follow-up, not urgent"
    assert verified["assistant_message"] =~ "Dan Bourke (A-Team; video project contact)"
    assert verified["assistant_message"] =~ "Keep it active"
    refute verified["assistant_message"] =~ ".."
    refute verified["assistant_message"] =~ "several overdue follow-ups"
    refute verified["assistant_message"] =~ "I found"
    refute verified["assistant_message"] =~ "not treating it as urgent"
    refute verified["assistant_message"] =~ "look stale"
    refute verified["assistant_message"] =~ "Emma's Soccer Practice"
    assert verified["_quality_verification"]["score"] == 10
  end

  test "rewrites delivery digest intros without assistant-centric hedging" do
    personal_candidate = %{
      "id" => "candidate-personal",
      "title" => "Emma's soccer pickup",
      "body" => "Emma's soccer pickup starts soon.",
      "urgency" => 0.72,
      "attention_profile" => %{"bucket" => "personal_family"},
      "related_todos" => []
    }

    stale_candidate = %{
      "id" => "candidate-stale-work",
      "title" => "Old artifact follow-up",
      "body" => "Old artifact follow-up remains open.",
      "urgency" => 0.34,
      "attention_profile" => %{
        "bucket" => "business_project_waiting",
        "stale_confirmation_candidate" => true
      },
      "related_todos" => []
    }

    verified =
      ProactiveQualityGate.verify_delivery_plan(
        %{
          "dispositions" => [
            %{"candidate_id" => "candidate-personal", "disposition" => "digest"},
            %{"candidate_id" => "candidate-stale-work", "disposition" => "hold"}
          ],
          "digest_intro" => "Several overdue follow-ups need your attention now."
        },
        %{
          "candidates" => [personal_candidate, stale_candidate],
          "context" => %{},
          "recent_pushes" => []
        }
      )

    assert verified["digest_intro"] ==
             "Personal/family logistics are the highest-signal item right now."

    refute verified["digest_intro"] =~ "I grouped"
    refute verified["digest_intro"] =~ "looks worth"
    refute verified["digest_intro"] =~ "overdue"
    refute verified["digest_intro"] =~ "follow-ups"
  end

  test "holds personal logistics framed as business follow-up when no confirmation card is possible" do
    plan = %{
      "decision" => "send_now",
      "assistant_message" =>
        "Several recent meetings need a follow-up recap with owners and next steps, including Emma's Soccer Practice.",
      "message_class" => "assistant_push",
      "urgency" => 0.8,
      "interrupt_now" => true,
      "todo_ids" => [],
      "summary" => "Meetings need recaps."
    }

    verified =
      ProactiveQualityGate.verify_proactive_plan(plan, %{
        trigger: %{"local_time" => %{"weekend" => true}},
        context: %{}
      })

    assert verified["decision"] == "hold"
    assert verified["assistant_message"] == ""
    assert "personal_as_business" in verified["_quality_verification"]["findings"]
  end
end
