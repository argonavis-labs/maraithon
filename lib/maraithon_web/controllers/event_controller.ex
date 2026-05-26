defmodule MaraithonWeb.EventController do
  use MaraithonWeb, :controller

  alias Maraithon.AgentSubscriptions

  require Logger

  @doc """
  Publish an event to PubSub for agents to receive.

  POST /api/v1/events
  {
    "topic": "calendar",
    "payload": { ... }
  }

  This is the ingress point for external systems to send events
  to agents subscribed to topics.
  """
  def publish(conn, params) do
    topic = params["topic"]
    payload = params["payload"] || %{}

    if is_nil(topic) or topic == "" do
      conn
      |> put_status(:bad_request)
      |> json(%{error: "topic is required"})
    else
      # Broadcast to all subscribers of this topic
      Phoenix.PubSub.broadcast(
        Maraithon.PubSub,
        topic,
        {:pubsub_event, topic, payload}
      )

      Logger.info("Event published", topic: topic)

      conn
      |> put_status(:accepted)
      |> json(%{
        status: "published",
        topic: topic
      })
    end
  end

  @doc """
  List all topics that have active subscribers.
  Useful for debugging and observability.
  """
  def topics(conn, _params) do
    topics =
      AgentSubscriptions.list_active_topic_summaries()
      |> Enum.map(&serialize_topic_summary/1)

    conn
    |> json(%{
      count: length(topics),
      topics: topics
    })
  end

  defp serialize_topic_summary(summary) do
    %{
      topic: summary.topic,
      subscriber_count: summary.subscriber_count,
      agent_ids: summary.agent_ids,
      user_ids: summary.user_ids,
      project_ids: summary.project_ids,
      updated_at: format_datetime(summary.updated_at)
    }
  end

  defp format_datetime(nil), do: nil
  defp format_datetime(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)
end
