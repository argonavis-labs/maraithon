defmodule Maraithon.Runtime.AgentDirectiveIngress do
  @moduledoc """
  Converts topic and connector ingress into durable per-Agent Directives.

  Subscriber Agents are locked in stable ID order and the whole fan-out commits
  atomically. The producer acknowledges only that database commit; ID-only
  process notifications are best-effort latency hints sent afterwards.
  """

  import Ecto.Query

  alias Maraithon.AgentSubscriptions.AgentSubscription
  alias Maraithon.Repo
  alias Maraithon.Runtime.AgentDirectives

  def publish_topic(topic, payload, opts \\ [])

  def publish_topic(topic, payload, opts) when is_binary(topic) and is_list(opts) do
    publish_topics([topic], payload, opts)
  end

  def publish_topic(_topic, _payload, _opts), do: {:error, :invalid_ingress}

  def publish_topics(topics, payload, opts \\ [])

  def publish_topics(topics, payload, opts) when is_list(topics) and is_list(opts) do
    with {:ok, prepared} <- prepare(topics, payload, opts),
         {:ok, result} <-
           Repo.transaction(fn ->
             {:ok, result} = enqueue_prepared_in_transaction(prepared)
             result
           end) do
      :ok = notify_committed(result)
      {:ok, result}
    end
  rescue
    _error -> {:error, :ingress_repository_unavailable}
  end

  def publish_topics(_topics, _payload, _opts), do: {:error, :invalid_ingress}

  @doc """
  Adds a topic fan-out to a caller-owned transaction without sending nudges.

  Call `notify_committed/1` only after the outer transaction succeeds.
  """
  def publish_topics_in_transaction(topics, payload, opts \\ [])

  def publish_topics_in_transaction(topics, payload, opts)
      when is_list(topics) and is_list(opts) do
    with true <- Repo.in_transaction?(),
         {:ok, prepared} <- prepare(topics, payload, opts) do
      enqueue_prepared_in_transaction(prepared)
    else
      false -> {:error, :transaction_required}
      {:error, _reason} = error -> error
    end
  end

  def publish_topics_in_transaction(_topics, _payload, _opts),
    do: {:error, :invalid_ingress}

  def notify_committed(%{directives: directives}) when is_list(directives) do
    Enum.each(directives, &AgentDirectives.notify_committed/1)
    :ok
  end

  def notify_committed(_result), do: :ok

  defp enqueue_prepared_in_transaction(prepared) do
    directives =
      prepared.topics
      |> active_subscribers()
      |> Enum.map(fn subscriber ->
        directive_payload = %{
          "topic" => hd(subscriber.topics),
          "topics" => subscriber.topics,
          "payload" => prepared.payload
        }

        case AgentDirectives.enqueue_in_transaction(
               subscriber.agent_id,
               subscriber.user_id,
               "channel_ingress",
               directive_payload,
               prepared.dedupe_key
             ) do
          {:ok, directive} -> directive
          {:error, reason} -> Repo.rollback(reason)
        end
      end)

    {:ok,
     %{
       directives: directives,
       accepted_count: length(directives),
       dedupe_key: prepared.dedupe_key
     }}
  end

  defp active_subscribers(topics) do
    AgentSubscription
    |> where([subscription], subscription.status == "active")
    |> where([subscription], subscription.topic in ^topics)
    |> select([subscription], %{
      agent_id: subscription.agent_id,
      user_id: subscription.user_id,
      topic: subscription.topic
    })
    |> order_by([subscription], asc: subscription.agent_id, asc: subscription.topic)
    |> Repo.all()
    |> Enum.group_by(& &1.agent_id)
    |> Enum.map(fn {agent_id, matches} ->
      %{
        agent_id: agent_id,
        user_id: matches |> hd() |> Map.fetch!(:user_id),
        topics: matches |> Enum.map(& &1.topic) |> Enum.uniq() |> Enum.sort()
      }
    end)
    |> Enum.filter(&(is_binary(&1.user_id) and &1.user_id != ""))
    |> Enum.sort_by(& &1.agent_id)
  end

  defp prepare(topics, payload, opts) do
    with {:ok, topics} <- normalize_topics(topics),
         {:ok, payload} <- canonical_payload(payload),
         {:ok, dedupe_key} <- ingress_dedupe_key(topics, payload, opts) do
      {:ok, %{topics: topics, payload: payload, dedupe_key: dedupe_key}}
    end
  end

  defp normalize_topics(topics) do
    normalized =
      topics
      |> Enum.map(fn
        topic when is_binary(topic) -> String.trim(topic)
        _invalid -> ""
      end)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()
      |> Enum.sort()

    if normalized != [] and length(normalized) <= 64 and
         Enum.all?(normalized, &(byte_size(&1) <= 500 and String.valid?(&1))) do
      {:ok, normalized}
    else
      {:error, :invalid_ingress}
    end
  end

  defp canonical_payload(payload) do
    with {:ok, encoded} <- Jason.encode(payload),
         true <- byte_size(encoded) <= 120_000,
         {:ok, canonical} <- Jason.decode(encoded) do
      {:ok, canonical}
    else
      _invalid -> {:error, :invalid_ingress_payload}
    end
  rescue
    _error -> {:error, :invalid_ingress_payload}
  end

  defp ingress_dedupe_key(topics, payload, opts) do
    if Keyword.keyword?(opts) and Enum.all?(Keyword.keys(opts), &(&1 == :dedupe_key)) do
      source_key = Keyword.get(opts, :dedupe_key)

      cond do
        is_binary(source_key) and byte_size(source_key) in 1..220 and
            String.valid?(source_key) ->
          {:ok, "ingress:#{source_key}"}

        is_nil(source_key) ->
          {:ok, "ingress:sha256:#{canonical_digest(topics, payload)}"}

        true ->
          {:error, :invalid_ingress_dedupe_key}
      end
    else
      {:error, :invalid_ingress}
    end
  end

  defp canonical_digest(topics, payload) do
    Jason.encode!(%{"topics" => topics, "payload" => payload})
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end
end
