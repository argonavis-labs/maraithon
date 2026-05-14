defmodule Maraithon.TelegramAssistant.ChatWorker do
  @moduledoc """
  One supervised process per Telegram chat.

  Inbound messages for a chat are cast here and processed one at a time. This
  does two things the old synchronous webhook path could not:

    * **Fast ack** — the webhook returns HTTP 200 immediately instead of
      blocking for the full multi-step LLM run (the "Sent 200 in 6382ms" bug).
      Telegram retries slow webhooks, so a slow synchronous handler also caused
      duplicate processing.
    * **Per-chat serialization** — two messages that arrive close together in
      the same chat are processed in order by the one worker, instead of
      spawning concurrent runs that race on the shared conversation row.
      Different chats get different workers and still run concurrently.

  Workers are keyed by `chat_id` in `ChatRegistry` and supervised by
  `ChatSupervisor`. They are kept alive for the node's lifetime — the count is
  bounded by the number of distinct chats, which is small for a personal
  assistant, and keeping them resident avoids a start/stop race that could drop
  a cast.

  In test (and any env where `async_enabled: false`) `enqueue/2` runs the
  router synchronously so existing tests keep their straight-line assertions.
  """

  use GenServer, restart: :temporary

  require Logger

  alias Maraithon.TelegramRouter

  @registry Maraithon.TelegramAssistant.ChatRegistry
  @supervisor Maraithon.TelegramAssistant.ChatSupervisor
  # Remember the last N message ids per chat to drop duplicate webhook
  # deliveries (Telegram retries). Small and bounded — N recent ids.
  @dedupe_window 100

  @doc """
  Enqueue an inbound Telegram message for per-chat-serialized processing.

  Returns `:ok` immediately when async is enabled (starts the chat's worker if
  needed). When async is disabled the router runs inline and `:ok` is returned
  once it finishes.
  """
  @spec enqueue(String.t(), map()) :: :ok
  def enqueue(chat_id, data) when is_binary(chat_id) and is_map(data) do
    if async_enabled?() do
      chat_id
      |> ensure_worker()
      |> GenServer.cast({:handle_message, data})

      :ok
    else
      _ = TelegramRouter.handle_message(data)
      :ok
    end
  end

  defp ensure_worker(chat_id) do
    case Registry.lookup(@registry, chat_id) do
      [{pid, _}] ->
        pid

      [] ->
        case DynamicSupervisor.start_child(@supervisor, {__MODULE__, chat_id}) do
          {:ok, pid} -> pid
          {:error, {:already_started, pid}} -> pid
        end
    end
  end

  def start_link(chat_id) do
    GenServer.start_link(__MODULE__, chat_id, name: {:via, Registry, {@registry, chat_id}})
  end

  def child_spec(chat_id) do
    %{
      id: {__MODULE__, chat_id},
      start: {__MODULE__, :start_link, [chat_id]},
      restart: :temporary
    }
  end

  @impl true
  def init(chat_id) do
    {:ok, %{chat_id: chat_id, seen: :queue.new(), seen_set: MapSet.new()}}
  end

  @impl true
  def handle_cast({:handle_message, data}, state) do
    message_id = message_id(data)

    if message_id != nil and MapSet.member?(state.seen_set, message_id) do
      # Duplicate webhook delivery — Telegram retried. Already handled.
      {:noreply, state}
    else
      run_router(data, state.chat_id)
      {:noreply, remember(state, message_id)}
    end
  end

  defp run_router(data, chat_id) do
    TelegramRouter.handle_message(data)
  rescue
    error ->
      Logger.warning("ChatWorker message handling crashed",
        chat_id: chat_id,
        reason: Exception.message(error)
      )

      :ok
  end

  defp remember(state, nil), do: state

  defp remember(state, message_id) do
    seen = :queue.in(message_id, state.seen)
    seen_set = MapSet.put(state.seen_set, message_id)

    if :queue.len(seen) > @dedupe_window do
      {{:value, oldest}, trimmed} = :queue.out(seen)
      %{state | seen: trimmed, seen_set: MapSet.delete(seen_set, oldest)}
    else
      %{state | seen: seen, seen_set: seen_set}
    end
  end

  defp message_id(data) do
    case Map.get(data, "message_id") || Map.get(data, :message_id) do
      nil -> nil
      value -> to_string(value)
    end
  end

  defp async_enabled? do
    :maraithon
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:async_enabled, true)
  end
end
