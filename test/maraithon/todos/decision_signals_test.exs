defmodule Maraithon.Todos.DecisionSignalsTest do
  use ExUnit.Case, async: true

  alias Maraithon.Todos.DecisionSignals
  alias Maraithon.Todos.Todo

  # SPEC 05 review (Finding 1): explicit_direction?/1 must read the
  # `direction` column first (the general assistant writer contract only
  # sets that column, not the legacy metadata vocabulary), and only fall
  # back to the legacy metadata.commitment_direction/thread_state checks
  # when `direction` is nil/absent.
  test "an owed_to_me direction alone marks a todo as needing a decision" do
    todo = %Todo{
      status: "open",
      direction: "owed_to_me",
      title: "Vendor contract",
      summary: "This is a reference note with plain background context.",
      next_action: "Check back later.",
      notes: nil,
      action_plan: nil,
      metadata: %{}
    }

    assert DecisionSignals.needs_decision?(todo)
  end

  test "an owed_by_me direction alone does not flood Decisions without waiting evidence" do
    todo = %Todo{
      status: "open",
      direction: "owed_by_me",
      title: "Vendor contract",
      summary: "This is a reference note with plain background context.",
      next_action: "Check back later.",
      notes: nil,
      action_plan: nil,
      metadata: %{}
    }

    refute DecisionSignals.needs_decision?(todo)
  end

  test "owed_by_me with explicit waiting metadata still needs a decision" do
    todo = %Todo{
      status: "open",
      direction: "owed_by_me",
      title: "Vendor contract",
      summary: "This is a reference note with plain background context.",
      next_action: "Check back later.",
      notes: nil,
      action_plan: nil,
      metadata: %{"commitment_direction" => "pending_reply"}
    }

    assert DecisionSignals.needs_decision?(todo)
  end

  test "an fyi direction is not treated as needing a decision on its own" do
    todo = %Todo{
      status: "open",
      direction: "fyi",
      title: "Vendor contract",
      summary: "This is a reference note with plain background context.",
      next_action: "Check back later.",
      notes: nil,
      action_plan: nil,
      metadata: %{}
    }

    refute DecisionSignals.needs_decision?(todo)
  end

  test "falls back to legacy commitment_direction metadata when direction is absent" do
    todo = %Todo{
      status: "open",
      direction: nil,
      title: "Vendor contract",
      summary: "This is a reference note with plain background context.",
      next_action: "Check back later.",
      notes: nil,
      action_plan: nil,
      metadata: %{"commitment_direction" => "pending_reply"}
    }

    assert DecisionSignals.needs_decision?(todo)
  end

  test "plain map input reads the direction key the same way as a Todo struct" do
    todo = %{
      "status" => "open",
      "direction" => "owed_to_me",
      "title" => "Vendor contract",
      "summary" => "This is a reference note with plain background context.",
      "next_action" => "Check back later."
    }

    assert DecisionSignals.needs_decision?(todo)
  end
end
