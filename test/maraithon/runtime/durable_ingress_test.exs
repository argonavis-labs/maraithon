defmodule Maraithon.Runtime.DurableIngressTest do
  use Maraithon.DataCase, async: false

  alias Maraithon.Accounts
  alias Maraithon.AgentIsolation
  alias Maraithon.AgentSubscriptions
  alias Maraithon.Agents
  alias Maraithon.OperatorBus
  alias Maraithon.OperatorEvents.OperatorEvent
  alias Maraithon.Runtime
  alias Maraithon.Runtime.AgentDirective
  alias Maraithon.Runtime.AgentDirectiveIngress

  test "Runtime.send_message acknowledges only a committed idempotent Directive" do
    agent = running_agent("runtime-message", [])
    message_id = "api-message-123"

    assert {:ok, %{message_id: ^message_id, directive_id: directive_id}} =
             Runtime.send_message(agent.id, "hello", %{
               "message_id" => message_id,
               "correlation_id" => "request-1"
             })

    directive = Repo.get!(AgentDirective, directive_id)
    assert directive.status == "pending"
    assert directive.kind == "message"
    assert directive.payload["message"] == "hello"
    assert directive.payload["message_id"] == message_id

    assert {:ok, %{directive_id: ^directive_id}} =
             Runtime.send_message(agent.id, "hello", %{
               "message_id" => message_id,
               "correlation_id" => "request-1"
             })

    assert Repo.aggregate(AgentDirective, :count, :id) == 1

    assert {:error, :directive_idempotency_conflict} =
             Runtime.send_message(agent.id, "changed", %{"message_id" => message_id})
  end

  test "topic fan-out creates one Directive per Agent across overlapping subscriptions" do
    agent = running_agent("topic-fanout", ["topic:a", "topic:b"])

    assert {:ok, %{accepted_count: 1, directives: [directive]}} =
             AgentDirectiveIngress.publish_topics(
               ["topic:b", "topic:a"],
               %{"id" => "event-1", "body" => "durable"},
               dedupe_key: "source:event-1"
             )

    assert directive.agent_id == agent.id
    assert directive.payload["topic"] == "topic:a"
    assert directive.payload["topics"] == ["topic:a", "topic:b"]

    assert {:ok, %{accepted_count: 1, directives: [same]}} =
             AgentDirectiveIngress.publish_topics(
               ["topic:a", "topic:b"],
               %{"id" => "event-1", "body" => "durable"},
               dedupe_key: "source:event-1"
             )

    assert same.id == directive.id
    assert Repo.aggregate(AgentDirective, :count, :id) == 1
  end

  test "OperatorBus rolls its source event back when durable subscriber fan-out fails" do
    agent = running_agent("operator-rollback", ["operator:user:operator-rollback@example.com"])
    binding = AgentIsolation.get_binding(agent.id)
    {:ok, _revoked} = binding |> Ecto.Changeset.change(status: "revoked") |> Repo.update()

    attrs = %{
      user_id: agent.user_id,
      source: "test",
      event_type: "test.failed_fanout",
      source_item_id: "item-1",
      dedupe_key: "test:item-1",
      payload: %{"value" => 1}
    }

    assert {:error, :agent_binding_not_active} = OperatorBus.publish(attrs)
    refute Repo.get_by(OperatorEvent, user_id: agent.user_id, dedupe_key: "test:item-1")
    assert Repo.aggregate(AgentDirective, :count, :id) == 0
  end

  defp running_agent(local_part, topics) do
    user_id =
      if String.contains?(local_part, "@"), do: local_part, else: "#{local_part}@example.com"

    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

    {:ok, agent} =
      Agents.create_agent(%{
        user_id: user_id,
        behavior: "prompt_agent",
        status: "running",
        started_at: DateTime.utc_now(),
        config: %{
          "name" => local_part,
          "prompt" => "test",
          "subscribe" => topics,
          "tools" => []
        }
      })

    {:ok, _binding} = AgentIsolation.grant_binding_consent(agent, binding_consent(agent))
    {:ok, _subscriptions} = AgentSubscriptions.sync_for_agent(agent)
    agent
  end
end
