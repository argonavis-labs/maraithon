defmodule Maraithon.OperatorEventsTest do
  use Maraithon.DataCase, async: true

  alias Maraithon.Accounts
  alias Maraithon.OperatorBus
  alias Maraithon.OperatorEvents
  alias Maraithon.Projects

  setup do
    user_id = "operator-events@example.com"
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)
    {:ok, project} = Projects.create_project(user_id, %{"name" => "Operator Core"})
    %{user_id: user_id, project: project}
  end

  test "publishes canonical operator events and broadcasts to user and project topics", %{
    user_id: user_id,
    project: project
  } do
    user_topic = "operator:user:#{user_id}:source:telegram"
    project_topic = "operator:project:#{project.id}"

    Phoenix.PubSub.subscribe(Maraithon.PubSub, user_topic)
    Phoenix.PubSub.subscribe(Maraithon.PubSub, project_topic)

    {:ok, event} =
      OperatorBus.publish(%{
        user_id: user_id,
        project_id: project.id,
        source: "telegram",
        event_type: "conversation_turn.recorded",
        source_item_id: "turn-1",
        dedupe_key: "telegram:conversation_turn.recorded:turn-1",
        occurred_at: DateTime.utc_now(),
        payload: %{"text" => "What matters today?"}
      })

    assert event.scope == "project"

    assert_receive {:pubsub_event, ^user_topic, payload}
    assert payload["kind"] == "operator_event"
    assert payload["event_type"] == "conversation_turn.recorded"
    assert payload["payload"]["text"] == "What matters today?"

    assert_receive {:pubsub_event, ^project_topic, project_payload}
    assert project_payload["project_id"] == project.id

    assert [%{id: id}] = OperatorEvents.list_recent_for_user(user_id, 10)
    assert id == event.id
  end

  test "deduplicates events by user and dedupe key", %{user_id: user_id} do
    attrs = %{
      user_id: user_id,
      source: "telegram",
      event_type: "conversation_turn.recorded",
      source_item_id: "turn-2",
      dedupe_key: "telegram:conversation_turn.recorded:turn-2",
      occurred_at: DateTime.utc_now(),
      payload: %{"text" => "Handled the billing, what else?"}
    }

    {:ok, first} = OperatorEvents.record(attrs)
    {:ok, second} = OperatorEvents.record(attrs)

    assert first.id == second.id
    assert Enum.count(OperatorEvents.list_recent_for_user(user_id, 10), &(&1.id == first.id)) == 1
  end
end
