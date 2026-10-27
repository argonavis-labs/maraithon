defmodule Maraithon.OperatorBus do
  @moduledoc """
  Broadcasts canonical operator events onto PubSub topics that agents can subscribe to.
  """

  alias Maraithon.OperatorEvents
  alias Maraithon.OperatorEvents.OperatorEvent
  alias Maraithon.Repo
  alias Maraithon.Runtime.AgentDirectiveIngress
  alias Maraithon.Runtime.Config, as: RuntimeConfig

  def publish(attrs) when is_map(attrs) do
    if RuntimeConfig.exact_agent_runtime_enabled?() do
      publish_durable(attrs)
    else
      with {:ok, %OperatorEvent{} = event} <- OperatorEvents.record(attrs) do
        :ok = broadcast_legacy(event)
        {:ok, event}
      end
    end
  end

  def broadcast(%OperatorEvent{} = event) do
    if RuntimeConfig.exact_agent_runtime_enabled?() do
      case AgentDirectiveIngress.publish_topics(
             topics_for_event(event),
             serialize_event(event),
             dedupe_key: "operator_event:#{event.id}"
           ) do
        {:ok, _result} -> :ok
        {:error, reason} -> {:error, reason}
      end
    else
      broadcast_legacy(event)
    end
  end

  defp publish_durable(attrs) do
    result =
      Repo.transaction(fn ->
        with {:ok, %OperatorEvent{} = event} <- OperatorEvents.record(attrs),
             {:ok, ingress} <-
               AgentDirectiveIngress.publish_topics_in_transaction(
                 topics_for_event(event),
                 serialize_event(event),
                 dedupe_key: "operator_event:#{event.id}"
               ) do
          %{event: event, ingress: ingress}
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end)

    case result do
      {:ok, %{event: event, ingress: ingress}} ->
        :ok = AgentDirectiveIngress.notify_committed(ingress)
        {:ok, event}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp broadcast_legacy(%OperatorEvent{} = event) do
    payload = serialize_event(event)

    Enum.each(topics_for_event(event), fn topic ->
      Phoenix.PubSub.broadcast(Maraithon.PubSub, topic, {:pubsub_event, topic, payload})
    end)

    :ok
  end

  def topics_for_event(%OperatorEvent{} = event) do
    [
      "operator:user:#{event.user_id}",
      "operator:user:#{event.user_id}:source:#{event.source}",
      "operator:user:#{event.user_id}:type:#{event.event_type}"
    ]
    |> maybe_add_project_topics(event)
    |> Enum.uniq()
  end

  def serialize_event(%OperatorEvent{} = event) do
    %{
      "kind" => "operator_event",
      "id" => event.id,
      "user_id" => event.user_id,
      "project_id" => event.project_id,
      "source" => event.source,
      "event_type" => event.event_type,
      "scope" => event.scope,
      "source_item_id" => event.source_item_id,
      "dedupe_key" => event.dedupe_key,
      "occurred_at" => event.occurred_at,
      "payload" => event.payload || %{},
      "metadata" => event.metadata || %{},
      "topics" => topics_for_event(event),
      "inserted_at" => event.inserted_at
    }
  end

  defp maybe_add_project_topics(topics, %OperatorEvent{project_id: nil}), do: topics

  defp maybe_add_project_topics(topics, %OperatorEvent{
         project_id: project_id,
         source: source,
         event_type: event_type
       }) do
    topics ++
      [
        "operator:project:#{project_id}",
        "operator:project:#{project_id}:source:#{source}",
        "operator:project:#{project_id}:type:#{event_type}"
      ]
  end
end
