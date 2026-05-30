defmodule MaraithonWeb.MobileJSONTest do
  use ExUnit.Case, async: true

  alias Maraithon.Todos.Todo
  alias MaraithonWeb.MobileJSON

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
        "person" => "Oak Street School"
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

    assert source_context == "Could not fully check Gmail before sending this."
    refute source_context =~ "DBConnection"
    refute source_context =~ "token=secret"
    refute source_context =~ "stacktrace"

    encoded = inspect(response)
    refute encoded =~ "source_health"
    refute encoded =~ "DBConnection"
    refute encoded =~ "token=secret"
  end
end
