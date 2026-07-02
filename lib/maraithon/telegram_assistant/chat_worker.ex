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

  alias Maraithon.AssistantHarness
  alias Maraithon.ConnectedAccounts
  alias Maraithon.OperatorEvents
  alias Maraithon.TelegramResponder
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
      # `run_router/2` never lets an exception, exit, or throw escape — it
      # always resolves to a handled outcome (success, or a caught failure
      # with a fallback reply attempted). Only once that's true do we mark
      # the message id as seen: if the worker somehow still died before this
      # point (e.g. the BEAM itself killed it), the id is never remembered,
      # so a Telegram webhook retry can still be processed by a fresh worker.
      run_router(data, state.chat_id)
      {:noreply, remember(state, message_id)}
    end
  end

  defp run_router(data, chat_id) do
    TelegramRouter.handle_message(data)
    :ok
  rescue
    error ->
      handle_router_failure(data, chat_id, :exception, Exception.message(error))
  catch
    :exit, reason ->
      handle_router_failure(data, chat_id, :exit, inspect(reason))

    :throw, value ->
      handle_router_failure(data, chat_id, :throw, inspect(value))
  end

  # Any crash anywhere inside `TelegramRouter.handle_message/1` — including a
  # `GenServer.call` timeout (`:exit`) surfacing from deep in the tool/agent
  # stack — lands here instead of killing the worker. The failure is only
  # considered "handled" once a fallback reply has been attempted, so the
  # user is never left with silence.
  defp handle_router_failure(data, chat_id, kind, reason) do
    Logger.warning("[telegram_fallback] ChatWorker message handling failed",
      chat_id: chat_id,
      kind: kind,
      reason: reason
    )

    send_result = send_fallback_reply(data, chat_id)
    _ = record_fallback_event(data, chat_id, kind, reason, send_result)

    :ok
  end

  defp send_fallback_reply(data, chat_id) do
    text = AssistantHarness.failure_message(:chat_worker_crash)

    case message_id(data) do
      nil -> TelegramResponder.send(chat_id, text)
      reply_to_message_id -> TelegramResponder.reply(chat_id, reply_to_message_id, text)
    end
  rescue
    error ->
      Logger.warning("[telegram_fallback] fallback reply send crashed",
        chat_id: chat_id,
        reason: Exception.message(error)
      )

      {:error, :fallback_send_crashed}
  catch
    kind, reason ->
      Logger.warning("[telegram_fallback] fallback reply send crashed",
        chat_id: chat_id,
        reason: inspect({kind, reason})
      )

      {:error, :fallback_send_crashed}
  end

  defp record_fallback_event(data, chat_id, kind, reason, send_result) do
    case resolve_user_id(chat_id) do
      nil ->
        :ok

      user_id ->
        OperatorEvents.record(%{
          user_id: user_id,
          source: "telegram",
          event_type: "telegram_fallback.message_recovered",
          source_item_id: message_id(data) || chat_id,
          dedupe_key:
            "telegram_fallback:message_recovered:#{chat_id}:#{message_id(data) || Ecto.UUID.generate()}",
          payload: %{
            "chat_id" => chat_id,
            "message_id" => message_id(data),
            "kind" => to_string(kind),
            "reason" => reason,
            "fallback_sent" => match?({:ok, _}, send_result)
          }
        })
    end
  rescue
    error ->
      Logger.warning("[telegram_fallback] failed to record operator event",
        chat_id: chat_id,
        reason: Exception.message(error)
      )

      :ok
  end

  defp resolve_user_id(chat_id) do
    case ConnectedAccounts.get_connected_by_external_account("telegram", chat_id) do
      %{user_id: user_id} -> user_id
      _ -> nil
    end
  rescue
    _ -> nil
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
