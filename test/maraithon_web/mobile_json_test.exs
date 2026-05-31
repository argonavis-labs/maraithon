defmodule MaraithonWeb.MobileJSONTest do
  use ExUnit.Case, async: true

  alias Maraithon.Todos.Todo
  alias MaraithonWeb.MobileJSON

  test "fresh action card buttons use completion and feedback actions" do
    now = DateTime.utc_now()

    todo = %Todo{
      id: Ecto.UUID.generate(),
      user_id: "mobile-json-fresh-buttons@example.com",
      source: "gmail",
      title: "Reply to Alex about launch timing",
      summary: "Alex is waiting on the launch sequencing decision.",
      next_action: "Reply to Alex with the launch sequence and timing.",
      action_draft: %{
        "kind" => "gmail_reply",
        "body" => "Thanks Alex. I can send the launch sequence today."
      },
      priority: 92,
      status: "open",
      metadata: %{
        "source_evidence" => "Alex asked for the launch sequence and timing.",
        "record" => %{"person" => "Alex Morgan", "company" => "Runway"}
      },
      inserted_at: now,
      updated_at: now
    }

    response = MobileJSON.todo(todo, include_card: true, source_health_snapshots: [])
    buttons = get_in(response, [:action_card, :available_buttons])

    assert get_in(response, [:action_card, :draft_preview]) ==
             "Thanks Alex. I can send the launch sequence today."

    assert %{action: "done", label: "Done"} in buttons
    assert %{action: "snooze", label: "Snooze"} in buttons
    assert %{action: "dismiss", label: "Dismiss"} in buttons
    assert %{action: "helpful", label: "Helpful"} in buttons
    assert %{action: "not_helpful", label: "Less useful"} in buttons
    refute Enum.any?(buttons, &(&1.action in ["important", "keep_active"]))
    refute Enum.any?(buttons, &(&1.label == "Keep active"))
  end

  test "stale action card buttons expose one keep-active decision" do
    five_days_ago =
      DateTime.utc_now()
      |> DateTime.add(-5 * 24 * 60 * 60, :second)
      |> DateTime.truncate(:second)

    todo = %Todo{
      id: Ecto.UUID.generate(),
      user_id: "mobile-json-stale-buttons@example.com",
      source: "gmail",
      title: "Confirm Dan Bourke artifact status",
      summary: "Dan Bourke may no longer need the old artifact status follow-up.",
      next_action: "Ask whether this still matters before spending more time on it.",
      priority: 40,
      status: "open",
      metadata: %{
        "source_evidence" => "Dan asked for artifact status and ETA.",
        "record" => %{"person" => "Dan Bourke", "company" => "A-Team"}
      },
      source_occurred_at: five_days_ago,
      inserted_at: five_days_ago,
      updated_at: five_days_ago
    }

    response = MobileJSON.todo(todo, include_card: true, source_health_snapshots: [])
    buttons = get_in(response, [:action_card, :available_buttons])

    assert get_in(response, [:action_card, :attention_mode]) == "stale_check"
    assert %{action: "important", label: "Keep active"} in buttons
    assert %{action: "dismiss", label: "Dismiss"} in buttons
    assert Enum.count(buttons, &(&1.label == "Keep active")) == 1
    refute Enum.any?(buttons, &(&1.action == "keep_active"))
    refute Enum.any?(buttons, &(&1.action == "done"))
  end

  test "action card source context hides raw source health failures" do
    now = DateTime.utc_now()

    todo = %Todo{
      id: Ecto.UUID.generate(),
      user_id: "mobile-json-source-context@example.com",
      source: "gmail",
      title: "Reply to Oak Street School about pickup",
      summary: "Oak Street School asked whether Tuesday pickup should move to 4 PM.",
      next_action: "Confirm the Tuesday pickup plan with the school.",
      priority: 92,
      status: "open",
      metadata: %{
        "life_domain" => "family",
        "source_evidence" => "The school asked whether Tuesday pickup should move to 4 PM.",
        "person" => "Oak Street School",
        "project" => "Tuesday pickup"
      },
      inserted_at: now,
      updated_at: now
    }

    response =
      MobileJSON.todo(todo,
        include_card: true,
        source_health_snapshots: [
          %{
            "provider" => "gmail",
            "status" => "error",
            "stale_reason" => "DBConnection.ConnectionError token=secret stacktrace"
          }
        ]
      )

    source_context = get_in(response, [:action_card, :source_context])
    context_items = get_in(response, [:action_card, :context_items])

    assert source_context == "Gmail context is incomplete; review the source before sending this."
    assert %{label: "Person", value: "Oak Street School"} in context_items
    assert %{label: "Project", value: "Tuesday pickup"} in context_items
    refute source_context =~ "DBConnection"
    refute source_context =~ "token=secret"
    refute source_context =~ "stacktrace"

    encoded = inspect(response)
    refute encoded =~ "source_health"
    refute encoded =~ "DBConnection"
    refute encoded =~ "token=secret"
  end
end
