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
end
