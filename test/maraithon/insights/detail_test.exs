defmodule Maraithon.Insights.DetailTest do
  use ExUnit.Case, async: true

  alias Maraithon.InsightNotifications.Delivery
  alias Maraithon.Insights.Detail
  alias Maraithon.Insights.Insight

  test "prefers metadata.detail and redacts delivery destinations" do
    now = ~U[2026-03-12 14:00:00Z]

    insight =
      build_insight(%{
        metadata: %{
          "detail" => %{
            "promise_text" => "Send the revised pricing doc to Sarah by Friday.",
            "requested_by" => "Sarah Chen",
            "open_loop_reason" => "No sent artifact confirms delivery.",
            "checked_evidence" => [
              %{
                "kind" => "source_evidence",
                "label" => "Promise stated in email thread",
                "detail" => "Send the revised pricing doc by Friday.",
                "source_ref" => "gmail:thread:abc123",
                "occurred_at" => DateTime.to_iso8601(now)
              }
            ],
            "evaluated_at" => DateTime.to_iso8601(now)
          },
          "record" => %{"status" => "unresolved"}
        }
      })

    delivery = %Delivery{
      channel: "telegram",
      destination: "123456789",
      status: "sent",
      sent_at: now,
      error_message: "send failed for 123456789 and sarah@example.com"
    }

    detail = Detail.build(insight, [delivery])

    assert detail.promise_text == %{
             text: "Send the revised pricing doc to Sarah by Friday.",
             origin: :stored
           }

    assert detail.requested_by == %{text: "Sarah Chen", origin: :stored}
    assert detail.open_loop_reason.origin == :stored
    assert detail.open_loop_reason.text == "No sent artifact confirms delivery."
    assert hd(detail.evidence_checked).label == "Promise stated in email thread"
    assert hd(detail.delivery_evidence).destination_label == "Telegram linked chat"

    assert hd(detail.delivery_evidence).error_message ==
             "Delivery failed. Check the connected channel before sending another delivery."

    refute hd(detail.delivery_evidence).error_message =~ "123456789"
    refute hd(detail.delivery_evidence).error_message =~ "sarah@example.com"
    assert detail.data_gaps == []

    summary = Detail.summary_text(detail, insight)

    assert summary =~ "Reason sent:"

    assert summary =~
             "Sarah Chen is tied to this unresolved commitment: Send the revised pricing doc to Sarah by Friday."

    assert summary =~ "Why now:"
    assert summary =~ "No sent artifact confirms delivery."
    assert summary =~ "Evidence checked:"
    assert summary =~ "Promise stated in email thread: Send the revised pricing doc by Friday."
    refute summary =~ "I surfaced"
    refute summary =~ "looks like"
    refute summary =~ "I didn't find"
  end

  test "falls back to record metadata and derives the open loop reason" do
    now = ~U[2026-03-12 09:30:00Z]
    due_at = ~U[2026-03-13 17:00:00Z]

    insight =
      build_insight(%{
        source_id: "msg-42",
        source_occurred_at: now,
        due_at: due_at,
        metadata: %{
          "missing_followthrough_evidence" => true,
          "record" => %{
            "commitment" => "Send the revised pricing doc to Sarah",
            "person" => "Sarah",
            "status" => "unresolved",
            "source" => "gmail:thread:thread-42",
            "deadline" => DateTime.to_iso8601(due_at),
            "evidence" => ["No follow-up reply or attachment was found."],
            "next_action" => "Send the promised follow-through now."
          }
        }
      })

    detail = Detail.build(insight, [])

    assert detail.promise_text == %{
             text: "Send the revised pricing doc to Sarah",
             origin: :stored
           }

    assert detail.requested_by == %{text: "Sarah", origin: :stored}
    assert Enum.any?(detail.evidence_checked, &(&1.kind == :deadline))

    assert Enum.any?(
             detail.evidence_checked,
             &(&1.label == "Source activity" and
                 &1.detail == "Seen Mar 12, 2026 at 9:30 AM UTC")
           )

    assert Enum.any?(
             detail.evidence_checked,
             &(&1.label == "Deadline" and &1.detail == "Due Mar 13, 2026 at 5:00 PM UTC")
           )

    assert detail.open_loop_reason.origin == :derived
    assert detail.open_loop_reason.text =~ "unresolved"
    assert "No follow-up delivery has been recorded yet." in detail.data_gaps

    summary = Detail.summary_text(detail, insight)

    assert summary =~ "Source activity: Seen Mar 12, 2026 at 9:30 AM UTC"
    assert summary =~ "Deadline: Due Mar 13, 2026 at 5:00 PM UTC"
    refute summary =~ "2026-03-12T09:30:00Z"
    refute summary =~ "2026-03-13T17:00:00Z"
  end

  test "can derive evidence timestamps in a product timezone" do
    now = ~U[2026-03-12 09:30:00Z]
    due_at = ~U[2026-03-13 17:00:00Z]

    insight =
      build_insight(%{
        source_occurred_at: now,
        due_at: due_at,
        metadata: %{
          "record" => %{
            "commitment" => "Send the revised pricing doc to Sarah",
            "person" => "Sarah",
            "status" => "unresolved"
          }
        }
      })

    detail =
      Detail.build(insight, [], timezone_info: %{name: "America/Toronto", offset_hours: -5})

    summary = Detail.summary_text(detail, insight)

    assert summary =~ "Source activity: Seen Mar 12, 2026 at 5:30 AM ET"
    assert summary =~ "Deadline: Due Mar 13, 2026 at 1:00 PM ET"
    refute summary =~ "9:30 AM UTC"
    refute summary =~ "5:00 PM UTC"
  end

  test "reports explicit data gaps for sparse insights" do
    insight =
      build_insight(%{
        title: "Reply owed: Board deck",
        summary: "You still owe an update.",
        recommended_action: "Reply now with the promised update.",
        metadata: %{}
      })

    detail = Detail.build(insight, [])

    assert detail.promise_text == %{text: "Reply owed: Board deck", origin: :reconstructed}
    assert detail.requested_by == nil
    assert detail.open_loop_reason.origin == :derived
    assert "Requester not captured for this insight." in detail.data_gaps
    assert "No saved evidence was captured for this item." in detail.data_gaps
    assert "No follow-up delivery has been recorded yet." in detail.data_gaps

    summary = Detail.summary_text(detail, insight)

    assert summary =~ "Reason sent:"
    assert summary =~ "Unresolved commitment: Reply owed: Board deck"
    assert summary =~ "No completion evidence was found after the original commitment."
    refute summary =~ "Persisted"
    refute summary =~ "open loop"
    refute summary =~ "I surfaced"
    refute summary =~ "looks like"
    refute summary =~ "I didn't find"
  end

  defp build_insight(attrs) do
    struct(Insight, Map.merge(default_insight_attrs(), attrs))
  end

  defp default_insight_attrs do
    %{
      id: Ecto.UUID.generate(),
      user_id: "detail-user@example.com",
      agent_id: Ecto.UUID.generate(),
      source: "gmail",
      category: "commitment_unresolved",
      title: "Follow up on pricing doc",
      summary: "The pricing doc still appears open.",
      recommended_action: "Send the pricing doc now.",
      priority: 90,
      confidence: 0.83,
      status: "new",
      metadata: %{}
    }
  end
end
