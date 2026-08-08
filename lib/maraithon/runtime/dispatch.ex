defmodule Maraithon.Runtime.Dispatch do
  @moduledoc """
  Cluster-safe message dispatch for agent processes.
  """

  @topic_prefix "runtime:agent"
  @receipt_envelope :maraithon_dispatch_with_receipt

  @doc """
  Build the PubSub topic used for an agent.
  """
  def agent_topic(agent_id) when is_binary(agent_id) do
    "#{@topic_prefix}:#{agent_id}"
  end

  @doc """
  Subscribe the current process to an agent topic.
  """
  def subscribe(agent_id) when is_binary(agent_id) do
    Phoenix.PubSub.subscribe(Maraithon.PubSub, agent_topic(agent_id))
  end

  @doc """
  Dispatch a message to an agent across the cluster.

  When `:receipt` is `{pid, message}`, the receipt is sent immediately after
  at least one PubSub subscriber mailbox accepts the dispatch. No receipt is
  emitted when the topic has no subscribers, so durable callers can retry.
  """
  def dispatch(agent_id, message, opts \\ [])

  def dispatch(agent_id, message, opts) when is_binary(agent_id) and is_list(opts) do
    topic = agent_topic(agent_id)
    dispatched_message = {:agent_dispatch, message}

    case Keyword.fetch(opts, :receipt) do
      :error ->
        Phoenix.PubSub.broadcast(Maraithon.PubSub, topic, dispatched_message)

      {:ok, {receipt_to, receipt}} when is_pid(receipt_to) ->
        Phoenix.PubSub.broadcast(
          Maraithon.PubSub,
          topic,
          {@receipt_envelope, dispatched_message, receipt_to, receipt},
          __MODULE__
        )

      {:ok, invalid_receipt} ->
        raise ArgumentError,
              "expected :receipt to be {pid, message}, got: #{inspect(invalid_receipt)}"
    end
  end

  @doc false
  def dispatch(entries, from, {@receipt_envelope, message, receipt_to, receipt})
      when is_list(entries) and is_pid(receipt_to) do
    if deliver(entries, from, message) do
      send(receipt_to, receipt)
    end

    :ok
  end

  def dispatch(entries, from, message) when is_list(entries) do
    deliver(entries, from, message)
    :ok
  end

  defp deliver(entries, from, message) do
    Enum.reduce(entries, false, fn {pid, _metadata}, delivered? ->
      if from == :none or pid != from do
        send(pid, message)
        true
      else
        delivered?
      end
    end)
  end
end
