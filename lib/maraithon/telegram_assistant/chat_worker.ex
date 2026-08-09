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
  alias Maraithon.TelegramAssistant.VoiceCapture
  alias Maraithon.TelegramConversations
  alias Maraithon.TelegramResponder
  alias Maraithon.TelegramRouter

  @registry Maraithon.TelegramAssistant.ChatRegistry
  @supervisor Maraithon.TelegramAssistant.ChatSupervisor
  # Remember the last N message ids per chat to drop duplicate webhook
  # deliveries (Telegram retries). Small and bounded — N recent ids.
  @dedupe_window 100
  @default_durable_timeout_ms 120_000

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
      _ = router_module().handle_message(data)
      :ok
    end
  end

  @doc """
  Processes a durably accepted message in per-chat order.

  The call returns only after routing (or the existing fallback path) finishes,
  allowing the background job to remain claimed until work is actually done.
  """
  @spec process_durable(String.t(), map()) ::
          :ok | {:noop, atom()} | {:error, term()}
  def process_durable(chat_id, data) when is_binary(chat_id) and is_map(data) do
    # Durable work is owned directly by the claimed job task. It must not be
    # queued in the resident per-chat GenServer: after a timeout that server
    # would keep executing while the durable receipt retried.
    task = Task.async(fn -> process_durable_inline(chat_id, data) end)

    case Task.yield(task, durable_timeout_ms()) do
      {:ok, result} ->
        normalize_durable_result(result)

      {:exit, reason} ->
        {:error, {:durable_processing_exit, reason}}

      nil ->
        case Task.shutdown(task, :brutal_kill) do
          {:ok, result} -> normalize_durable_result(result)
          _terminated -> {:error, :durable_processing_timeout}
        end
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
    {_result, state} = process_message(data, state, true)
    {:noreply, state}
  end

  defp process_message(data, state, send_typing?) do
    message_id = message_id(data)

    cond do
      message_id != nil and MapSet.member?(state.seen_set, message_id) ->
        # Duplicate delivery already handled during this worker lifetime.
        {{:noop, :already_completed}, state}

      message_id != nil and already_completed?(state.chat_id, message_id) ->
        # Persisted completion survives worker restarts and prevents a retry
        # from repeating non-idempotent tools after the user got a reply.
        {{:noop, :already_completed}, remember(state, message_id)}

      true ->
        if send_typing?, do: send_early_typing_ping(state.chat_id)

        result = prepare_and_run(data, state.chat_id)

        if successful_result?(result),
          do: {result, remember(state, message_id)},
          else: {result, state}
    end
  end

  defp process_durable_inline(chat_id, data) do
    message_id = message_id(data)

    if message_id != nil and already_completed?(chat_id, message_id) do
      {:noop, :already_completed}
    else
      prepare_and_run(data, chat_id)
    end
  end

  # A failed typing ping must never affect message processing or retry
  # logic — `:ok` is a no-op continuation, errors are logged (ids/reason
  # only) and swallowed.
  defp send_early_typing_ping(chat_id) do
    case TelegramResponder.send_chat_action(chat_id, :typing) do
      {:ok, _result} ->
        :ok

      {:error, reason} ->
        Logger.warning("[telegram] early typing ping failed",
          chat_id: chat_id,
          reason: inspect(reason)
        )

        :ok
    end
  rescue
    error ->
      Logger.warning("[telegram] early typing ping crashed",
        chat_id: chat_id,
        reason: Exception.message(error)
      )

      :ok
  catch
    kind, reason ->
      Logger.warning("[telegram] early typing ping crashed",
        chat_id: chat_id,
        reason: inspect({kind, reason})
      )

      :ok
  end

  defp already_completed?(chat_id, message_id) do
    TelegramConversations.assistant_reply_recorded?(chat_id, message_id)
  rescue
    error ->
      log_retry_completion_failure(chat_id, error)
      false
  catch
    kind, reason ->
      log_retry_completion_failure(chat_id, {kind, reason})
      false
  end

  defp log_retry_completion_failure(chat_id, reason) do
    Logger.warning("[telegram_fallback] retry-completion check failed",
      chat_reference: Maraithon.Redaction.fingerprint(chat_id),
      reason: Maraithon.Redaction.error_summary(reason)
    )
  end

  # SPEC 02: a voice/audio message has no `text` yet when it reaches here —
  # the webhook already acked, so downloading + transcribing happens in this
  # worker, before the message is handed to `TelegramRouter`. Any exception
  # escaping either step (transcription included) still lands on the same
  # "never silence" fallback path as a router crash.
  defp prepare_and_run(data, chat_id) do
    case VoiceCapture.maybe_transcribe(data) do
      {:ok, prepared_data} ->
        run_router(prepared_data, chat_id)

      {:error, reason} ->
        handle_voice_capture_failure(data, chat_id, reason)
    end
  rescue
    error ->
      handle_router_failure(data, chat_id, :exception, Exception.message(error))
  catch
    :exit, reason ->
      handle_router_failure(data, chat_id, :exit, inspect(reason))

    :throw, value ->
      handle_router_failure(data, chat_id, :throw, inspect(value))
  end

  defp run_router(data, chat_id) do
    router_module().handle_message(data)
    |> normalize_durable_result()
  rescue
    error ->
      handle_router_failure(data, chat_id, :exception, Exception.message(error))
  catch
    :exit, reason ->
      handle_router_failure(data, chat_id, :exit, inspect(reason))

    :throw, value ->
      handle_router_failure(data, chat_id, :throw, inspect(value))
  end

  # R5: download/transcription failure (including R6 cap violations) must
  # still produce a short user-visible reply — never silence — using the
  # same fallback delivery + operator-event recording as a router crash,
  # just with copy specific to the voice failure reason
  # (`AssistantHarness.failure_message/1`).
  defp handle_voice_capture_failure(data, chat_id, reason) do
    Logger.warning("[telegram_fallback] voice capture failed",
      chat_id: chat_id,
      reason: inspect(reason)
    )

    text = AssistantHarness.failure_message(reason)
    send_result = send_fallback_reply(data, chat_id, text)
    _ = record_fallback_event(data, chat_id, :voice_capture, inspect(reason), send_result)

    case send_result do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, {:telegram_send_failed, reason}}
      other -> {:error, {:invalid_telegram_send_result, other}}
    end
  end

  # Any crash anywhere inside `TelegramRouter.handle_message/1` — including a
  # `GenServer.call` timeout (`:exit`) surfacing from deep in the tool/agent
  # stack — lands here instead of killing the worker. The failure is only
  # considered "handled" (and the message id eligible to be marked seen)
  # once the fallback reply has actually been delivered to the user.
  defp handle_router_failure(data, chat_id, kind, reason) do
    Logger.warning("[telegram_fallback] ChatWorker message handling failed",
      chat_id: chat_id,
      kind: kind,
      reason: reason
    )

    text = AssistantHarness.failure_message(:chat_worker_crash)
    send_result = send_fallback_reply(data, chat_id, text)
    _ = record_fallback_event(data, chat_id, kind, reason, send_result)

    case send_result do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, {:telegram_send_failed, reason}}
      other -> {:error, {:invalid_telegram_send_result, other}}
    end
  end

  defp send_fallback_reply(data, chat_id, text) do
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

  defp successful_result?(:ok), do: true
  defp successful_result?({:noop, reason}) when is_atom(reason), do: true
  defp successful_result?(_result), do: false

  defp normalize_durable_result(:ok), do: :ok
  defp normalize_durable_result({:noop, reason}) when is_atom(reason), do: {:noop, reason}
  defp normalize_durable_result({:error, reason}), do: {:error, reason}
  defp normalize_durable_result(other), do: {:error, {:invalid_durable_processing_result, other}}

  defp durable_timeout_ms do
    case Keyword.get(config(), :durable_timeout_ms, @default_durable_timeout_ms) do
      timeout when is_integer(timeout) and timeout > 0 -> timeout
      _invalid -> @default_durable_timeout_ms
    end
  end

  defp router_module do
    Keyword.get(config(), :router_module, TelegramRouter)
  end

  defp config, do: Application.get_env(:maraithon, __MODULE__, [])

  defp async_enabled? do
    config()
    |> Keyword.get(:async_enabled, true)
  end
end
