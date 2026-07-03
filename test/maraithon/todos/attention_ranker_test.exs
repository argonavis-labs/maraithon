defmodule Maraithon.Todos.AttentionRankerTest do
  use ExUnit.Case, async: true

  alias Maraithon.Todos.AttentionRanker

  @now ~U[2026-05-24 16:00:00Z]

  test "puts personal and family work ahead of routine work backlog" do
    family = %{
      "title" => "Confirm Emma camp pickup",
      "summary" => "Family logistics need a reply before pickup.",
      "next_action" => "Text the camp coordinator with pickup timing.",
      "priority" => 55,
      "source_occurred_at" => DateTime.add(@now, -2 * 3_600, :second),
      "metadata" => %{"life_domain" => "family"}
    }

    work = %{
      "title" => "Reply to old vendor meeting request",
      "summary" => "A vendor asked for a meeting last week.",
      "next_action" => "Book time if it still matters.",
      "priority" => 92,
      "source_occurred_at" => DateTime.add(@now, -6 * 86_400, :second)
    }

    assert [^family, ^work] = AttentionRanker.sort([work, family], now: @now)
    assert AttentionRanker.profile(family, now: @now)["bucket"] == "personal_family"
  end

  test "flags stale low-priority backlog for confirmation instead of urgency" do
    stale = %{
      "title" => "Follow up with Dan Bourke",
      "summary" => "Old follow-up with no recent movement.",
      "next_action" => "Ask whether this still matters.",
      "priority" => 60,
      "source_occurred_at" => DateTime.add(@now, -8 * 86_400, :second)
    }

    profile = AttentionRanker.profile(stale, now: @now)

    assert profile["stale_confirmation_candidate"] == true
    assert profile["age_days"] >= 8
  end

  test "prioritizes strong relationships who are waiting" do
    strong_relationship = %{
      "title" => "Send Charlie the launch notes",
      "summary" => "Charlie is waiting on the launch notes.",
      "next_action" => "Send the promised notes.",
      "priority" => 70,
      "metadata" => %{
        "relationship_strength" => 88,
        "commitment_direction" => "i_owe"
      }
    }

    profile = AttentionRanker.profile(strong_relationship, now: @now)

    assert profile["bucket"] == "strong_relationship_waiting"
    assert profile["relationship_strength"] == 88
  end

  test "does not classify business campaigns as family camp logistics" do
    campaign = %{
      "title" => "Reply to Michael about Starteryou UGC Campaigns",
      "summary" => "Michael is waiting on UGC campaign materials.",
      "next_action" => "Send the campaign owner and next artifact.",
      "priority" => 88,
      "metadata" => %{
        "record" => %{
          "company" => "Starteryou",
          "relationship_context" => "UGC campaign contact"
        }
      }
    }

    profile = AttentionRanker.profile(campaign, now: @now)

    refute profile["personal_family"]
    assert profile["bucket"] == "business_project_waiting"
  end

  test "does not treat tenant-specific source tags as a generic business signal" do
    tagged = %{
      "title" => "Review the note",
      "summary" => "No durable context was attached.",
      "next_action" => "Review it later if it still matters.",
      "metadata" => %{"source_tags" => ["runner"]}
    }

    profile = AttentionRanker.profile(tagged, now: @now)

    refute profile["business_project"]
  end

  # SPEC 05 review (Finding 1): the direction column, not just the legacy
  # metadata.commitment_direction vocabulary, must be read for
  # "actively_waiting" so todos written via the general assistant path
  # (which only sets `direction`, not the legacy metadata fields) are still
  # recognized as waiting on a counterparty.
  test "direction column alone marks a todo as actively waiting" do
    waiting_on_counterparty = %{
      "title" => "Vendor contract",
      "summary" => "No wording hints here at all.",
      "next_action" => "Check back later.",
      "priority" => 60,
      "direction" => "owed_to_me"
    }

    profile = AttentionRanker.profile(waiting_on_counterparty, now: @now)

    assert profile["actively_waiting"] == true
  end

  test "owed_by_me direction alone does not force actively waiting" do
    self_owned = %{
      "title" => "Vendor contract",
      "summary" => "No wording hints here at all.",
      "next_action" => "Check back later.",
      "priority" => 60,
      "direction" => "owed_by_me"
    }

    profile = AttentionRanker.profile(self_owned, now: @now)

    refute profile["actively_waiting"]
  end

  test "falls back to legacy commitment_direction metadata when direction is absent" do
    legacy_waiting = %{
      "title" => "Vendor contract",
      "summary" => "No wording hints here at all.",
      "next_action" => "Check back later.",
      "priority" => 60,
      "metadata" => %{"commitment_direction" => "pending_reply"}
    }

    profile = AttentionRanker.profile(legacy_waiting, now: @now)

    assert profile["actively_waiting"] == true
  end
end
