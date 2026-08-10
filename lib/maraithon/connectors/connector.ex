defmodule Maraithon.Connectors.Connector do
  @moduledoc """
  Behavior for external service connectors.

  A connector bridges external services (GitHub, Slack, etc.) to the agent
  framework by:

  1. Receiving webhooks from external services
  2. Validating/authenticating requests
  3. Normalizing events to a standard format
  4. Publishing to PubSub topics for agents to consume

  ## Implementing a Connector

      defmodule MyApp.Connectors.GitHub do
        @behaviour Maraithon.Connectors.Connector

        @impl true
        def handle_webhook(conn, params) do
          # Parse the webhook, return normalized event
          {:ok, "github:owner/repo", %{type: "issue_opened", ...}}
        end

        @impl true
        def verify_signature(conn, payload) do
          # Verify webhook signature
          :ok
        end
      end

  ## Standard Event Format

  All connectors should normalize events to:

      %{
        type: "event_type",           # e.g., "issue_opened", "message_received"
        source: "connector_name",     # e.g., "github", "slack"
        timestamp: DateTime.t(),
        data: %{...},                 # Event-specific data
        raw: %{...}                   # Original payload (optional)
      }
  """

  alias Maraithon.Runtime.AgentDirectiveIngress
  alias Maraithon.Runtime.Config, as: RuntimeConfig

  @type event :: %{
          type: String.t(),
          source: String.t(),
          timestamp: DateTime.t(),
          data: map(),
          raw: map() | nil
        }

  @doc """
  Handle an incoming webhook request.

  Should parse the webhook payload and return a normalized event
  with the topic to publish to.

  Returns:
    - `{:ok, topic, event}` - Event parsed successfully
    - `{:error, reason}` - Failed to parse or invalid webhook
    - `{:ignore, reason}` - Valid webhook but should not be published (e.g., ping)
  """
  @callback handle_webhook(conn :: Plug.Conn.t(), params :: map()) ::
              {:ok, topic :: String.t(), event()}
              | {:error, reason :: term()}
              | {:ignore, reason :: String.t()}

  @doc """
  Verify the webhook signature/authenticity.

  Called before handle_webhook to ensure the request is legitimate.

  Returns:
    - `:ok` - Signature valid
    - `{:error, reason}` - Signature invalid
  """
  @callback verify_signature(conn :: Plug.Conn.t(), raw_body :: binary()) ::
              :ok | {:error, reason :: term()}

  @doc """
  Helper to publish an event to PubSub.
  """
  def publish(topic, event) do
    if RuntimeConfig.exact_agent_runtime_enabled?() do
      case AgentDirectiveIngress.publish_topic(topic, event,
             dedupe_key: connector_dedupe_key(topic, event)
           ) do
        {:ok, _result} -> :ok
        {:error, reason} -> {:error, reason}
      end
    else
      Phoenix.PubSub.broadcast(
        Maraithon.PubSub,
        topic,
        {:pubsub_event, topic, event}
      )
    end
  end

  defp connector_dedupe_key(topic, event) when is_map(event) do
    identity =
      event["dedupe_key"] || event[:dedupe_key] || event["id"] || event[:id] ||
        event["source_item_id"] || event[:source_item_id]

    if is_binary(identity) and identity != "" do
      source = event["source"] || event[:source] || "connector"
      type = event["type"] || event[:type] || "event"
      candidate = "connector:#{source}:#{type}:#{identity}"

      if byte_size(candidate) <= 220 do
        candidate
      else
        "connector:sha256:" <>
          (:crypto.hash(:sha256, topic <> ":" <> candidate)
           |> Base.encode16(case: :lower))
      end
    else
      nil
    end
  end

  defp connector_dedupe_key(_topic, _event), do: nil

  @doc """
  Build a standard event struct.
  """
  def build_event(type, source, data, raw \\ nil) do
    %{
      type: type,
      source: source,
      timestamp: DateTime.utc_now(),
      data: data,
      raw: raw
    }
  end
end
