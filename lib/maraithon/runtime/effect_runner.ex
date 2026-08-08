defmodule Maraithon.Runtime.EffectRunner do
  @moduledoc """
  Polls and executes effects from the outbox.
  """

  use GenServer

  import Ecto.Query
  alias Maraithon.Repo
  alias Maraithon.Effects.Effect
  alias Maraithon.Runtime.Config, as: RuntimeConfig
  alias Maraithon.Runtime.DbResilience
  alias Maraithon.Runtime.Dispatch
  alias Maraithon.Runtime.Effects.CommandFactory
  alias Maraithon.Runtime.Effects.LLMRateLimiter

  require Logger

  @default_poll_interval_ms 1_000
  # Must exceed the longest-running effect (LLM calls may take up to 20 minutes
  # plus busy retries); crashed local tasks release their claim immediately via
  # the :DOWN handler, so this only bounds recovery after a node death.
  @default_claim_timeout_ms 1_500_000
  @default_batch_size 10
  @default_rate_limit_retry_ms 60_000
  @max_rate_limit_retry_ms 300_000

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    poll_interval_ms =
      RuntimeConfig.positive_integer(:effect_poll_interval_ms, @default_poll_interval_ms)

    claim_timeout_ms =
      RuntimeConfig.positive_integer(:effect_claim_timeout_ms, @default_claim_timeout_ms)

    batch_size = RuntimeConfig.positive_integer(:effect_batch_size, @default_batch_size)

    schedule_poll(poll_interval_ms)

    {:ok,
     %{
       running: %{},
       monitors: %{},
       poll_interval_ms: poll_interval_ms,
       claim_timeout_ms: claim_timeout_ms,
       batch_size: batch_size,
       poll_retry_attempts: 0
     }}
  end

  @impl true
  def handle_info(:poll, state) do
    case DbResilience.with_database("effect runner poll", fn ->
           reclaim_stale_effects(state.claim_timeout_ms)
           fetch_pending_effects(state.batch_size, state.running)
         end) do
      {:ok, effects} ->
        state =
          Enum.reduce(effects, state, fn effect, acc ->
            case claim_effect(effect) do
              {:ok, claimed} ->
                ref = execute_effect_async(claimed)

                %{
                  acc
                  | running: Map.put(acc.running, effect.id, claimed),
                    monitors: Map.put(acc.monitors, ref, effect.id)
                }

              :already_claimed ->
                acc

              {:error, _reason} ->
                acc
            end
          end)

        schedule_poll(state.poll_interval_ms)
        {:noreply, %{state | poll_retry_attempts: 0}}

      {:error, _reason} ->
        retry_in_ms = DbResilience.backoff_ms(state.poll_interval_ms, state.poll_retry_attempts)
        schedule_poll(retry_in_ms)
        {:noreply, %{state | poll_retry_attempts: state.poll_retry_attempts + 1}}
    end
  end

  @impl true
  def handle_info({:effect_done, effect_id, _result}, state) do
    monitors =
      case Enum.find(state.monitors, fn {_ref, id} -> id == effect_id end) do
        {ref, _id} ->
          Process.demonitor(ref, [:flush])
          Map.delete(state.monitors, ref)

        nil ->
          state.monitors
      end

    {:noreply, %{state | running: Map.delete(state.running, effect_id), monitors: monitors}}
  end

  # Task.Supervisor.async_nolink reply for a task whose :effect_done message
  # already cleaned up — nothing left to do beyond dropping the monitor.
  @impl true
  def handle_info({ref, _result}, state) when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    {:noreply, %{state | monitors: Map.delete(state.monitors, ref)}}
  end

  # A task died before reporting back (raise the command didn't rescue, kill,
  # OOM). Without this, the `running` entry leaked forever and blocked every
  # future llm_call effect on this node.
  @impl true
  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    case Map.pop(state.monitors, ref) do
      {nil, _monitors} ->
        {:noreply, state}

      {effect_id, monitors} ->
        {effect, running} = Map.pop(state.running, effect_id)

        if effect && reason != :normal do
          Logger.error("Effect task crashed for effect #{effect_id}: #{inspect(reason)}")
          release_crashed_effect(effect, reason)
        end

        {:noreply, %{state | running: running, monitors: monitors}}
    end
  end

  @impl true
  def handle_info(msg, state) do
    Logger.debug("EffectRunner ignoring unexpected message: #{inspect(msg)}")
    {:noreply, state}
  end

  @impl true
  def handle_call(:clear_running, _from, state) do
    Enum.each(state.monitors, fn {ref, _id} -> Process.demonitor(ref, [:flush]) end)
    {:reply, :ok, %{state | running: %{}, monitors: %{}}}
  end

  # Private functions

  defp fetch_pending_effects(limit, running) do
    now = DateTime.utc_now()
    llm_available? = llm_effect_available?(running)
    llm_limit = if llm_available?, do: 1, else: 0
    non_llm_limit = max(limit - llm_limit, 0)

    non_llm_effects =
      now
      |> pending_effects_query()
      |> where([e], e.effect_type != "llm_call")
      |> limit(^non_llm_limit)
      |> Repo.all()

    llm_effects =
      if llm_limit > 0 do
        now
        |> pending_effects_query()
        |> where([e], e.effect_type == "llm_call")
        |> limit(^llm_limit)
        |> Repo.all()
      else
        []
      end

    (non_llm_effects ++ llm_effects)
    |> Enum.sort_by(&DateTime.to_unix(&1.inserted_at, :microsecond))
  end

  defp pending_effects_query(now) do
    from(e in Effect,
      where: e.status == "pending",
      where: is_nil(e.retry_after) or e.retry_after <= ^now,
      order_by: [asc: e.inserted_at]
    )
  end

  defp llm_effect_available?(running) do
    status = LLMRateLimiter.status()

    not running_llm_effect?(running) and
      Map.get(status, :blocked_for_ms, 0) <= 0 and
      Map.get(status, :in_flight, 0) < Map.get(status, :max_concurrency, 1)
  end

  defp running_llm_effect?(running) when is_map(running) do
    Enum.any?(running, fn {_id, effect} -> match?(%Effect{effect_type: "llm_call"}, effect) end)
  end

  defp running_llm_effect?(_running), do: false

  defp claim_effect(effect) do
    node_id = node() |> to_string()
    claimed_at = DateTime.utc_now()

    case DbResilience.with_database("effect runner claim effect", fn ->
           Repo.update_all(
             from(e in Effect,
               where: e.id == ^effect.id,
               where: e.status == "pending",
               where: is_nil(e.retry_after) or e.retry_after <= ^claimed_at,
               select: e
             ),
             set: [
               status: "claimed",
               claimed_by: node_id,
               claimed_at: claimed_at
             ]
           )
         end) do
      {:ok, {1, [%Effect{} = claimed]}} ->
        {:ok, claimed}

      {:ok, {0, _rows}} ->
        :already_claimed

      {:ok, {_count, _rows}} ->
        {:error, :unexpected_claim_result}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp execute_effect_async(effect) do
    parent = self()

    %Task{ref: ref} =
      Task.Supervisor.async_nolink(Maraithon.Runtime.EffectSupervisor, fn ->
        result = execute_effect(effect)
        send(parent, {:effect_done, effect.id, result})
        :ok
      end)

    ref
  end

  defp release_crashed_effect(effect, reason) do
    attempts = effect.attempts + 1
    error = {:effect_task_crashed, reason}

    if attempts < effect.max_attempts do
      mark_pending_retry(effect, error, attempts)
    else
      case mark_failed(effect, error, attempts) do
        :ok -> notify_agent(effect.agent_id, effect.id, {:error, error})
        :claim_lost -> :ok
        {:error, _reason} -> :ok
      end
    end
  end

  defp execute_effect(effect) do
    Logger.info("Executing effect #{effect.id}", effect_id: effect.id, type: effect.effect_type)

    result =
      try do
        execute_with_command(effect)
      rescue
        exception ->
          {:error, {:effect_exception, Exception.message(exception)}}
      catch
        kind, value ->
          {:error, {:effect_exception, "#{kind}: #{inspect(value)}"}}
      end

    case result do
      {:ok, data} ->
        case mark_completed(effect, data) do
          :ok -> notify_agent(effect.agent_id, effect.id, {:ok, data})
          :claim_lost -> :ok
          {:error, _reason} -> :ok
        end

      {:error, reason} ->
        attempts = next_attempt_count(effect, reason)

        if should_retry?(effect, reason, attempts) do
          mark_pending_retry(effect, reason, attempts)
        else
          case mark_failed(effect, reason, attempts) do
            :ok -> notify_agent(effect.agent_id, effect.id, {:error, reason})
            :claim_lost -> :ok
            {:error, _reason} -> :ok
          end
        end
    end

    result
  end

  defp execute_with_command(effect) do
    with {:ok, command_module} <- CommandFactory.fetch(effect.effect_type) do
      command_module.execute(effect)
    else
      {:error, :unknown_effect_type} ->
        {:error, "unknown_effect_type"}
    end
  end

  defp mark_completed(effect, result) do
    update_claimed_effect(effect, "mark completed",
      status: "completed",
      result: result,
      claimed_by: nil,
      claimed_at: nil
    )
  end

  defp mark_pending_retry(effect, reason, attempts) do
    backoff_ms = calculate_backoff(attempts, reason)
    retry_after = DateTime.add(DateTime.utc_now(), backoff_ms, :millisecond)

    update_claimed_effect(effect, "mark retry",
      status: "pending",
      claimed_by: nil,
      claimed_at: nil,
      attempts: attempts,
      retry_after: retry_after,
      error: inspect(reason)
    )
  end

  defp mark_failed(effect, reason, attempts) do
    update_claimed_effect(effect, "mark failed",
      status: "failed",
      error: inspect(reason),
      attempts: attempts,
      claimed_by: nil,
      claimed_at: nil
    )
  end

  # A worker may finish after its claim was cancelled or reclaimed. Fence every
  # terminal/retry write by the exact claim generation so stale work cannot
  # overwrite the newer status or notify an unrelated Agent incarnation.
  defp update_claimed_effect(
         %Effect{claimed_by: claimed_by, claimed_at: claimed_at} = effect,
         operation,
         updates
       )
       when is_binary(claimed_by) and not is_nil(claimed_at) do
    updates = Keyword.put(updates, :updated_at, DateTime.utc_now())

    case DbResilience.with_database("effect runner #{operation}", fn ->
           Repo.update_all(claimed_effect_query(effect), set: updates)
         end) do
      {:ok, {1, _rows}} ->
        :ok

      {:ok, {0, _rows}} ->
        Logger.info("Discarded late effect result after claim ownership changed",
          effect_id: effect.id,
          operation: operation
        )

        :claim_lost

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp update_claimed_effect(%Effect{} = effect, operation, _updates) do
    Logger.warning("Discarded effect result without claim ownership",
      effect_id: effect.id,
      operation: operation
    )

    :claim_lost
  end

  defp claimed_effect_query(%Effect{} = effect) do
    from(e in Effect,
      where: e.id == ^effect.id,
      where: e.status == "claimed",
      where: e.claimed_by == ^effect.claimed_by,
      where: e.claimed_at == ^effect.claimed_at
    )
  end

  defp next_attempt_count(%Effect{} = effect, reason) do
    if no_attempt_deferrable_effect_error?(effect, reason) do
      effect.attempts
    else
      effect.attempts + 1
    end
  end

  defp should_retry?(%Effect{} = effect, reason, attempts) do
    not terminal_effect_error?(reason) and
      (no_attempt_deferrable_effect_error?(effect, reason) or attempts < effect.max_attempts)
  end

  defp terminal_effect_error?({:insufficient_quota, _message}), do: true
  defp terminal_effect_error?(:insufficient_quota), do: true
  defp terminal_effect_error?(_reason), do: false

  defp no_attempt_deferrable_effect_error?(
         %Effect{effect_type: "llm_call"},
         {:llm_busy, _retry_after}
       ),
       do: true

  defp no_attempt_deferrable_effect_error?(_effect, _reason), do: false

  defp notify_agent(agent_id, effect_id, result) do
    :ok = Dispatch.dispatch(agent_id, {:effect_result, effect_id, result})
  end

  defp reclaim_stale_effects(claim_timeout_ms) do
    cutoff = DateTime.add(DateTime.utc_now(), -claim_timeout_ms, :millisecond)

    {count, _} =
      Repo.update_all(
        from(e in Effect,
          where: e.status == "claimed",
          where: e.claimed_at < ^cutoff
        ),
        set: [status: "pending", claimed_by: nil, claimed_at: nil]
      )

    if count > 0 do
      Logger.info("Reclaimed #{count} stale effects")
    end
  end

  defp calculate_backoff(attempt, reason) do
    case retry_after_ms(reason) do
      nil -> calculate_exponential_backoff(attempt)
      retry_after_ms -> add_jitter(retry_after_ms)
    end
  end

  defp calculate_exponential_backoff(attempt) do
    base = 1_000
    max = 60_000
    delay = base * :math.pow(2, attempt)
    jitter = :rand.uniform() * delay * 0.3
    round(min(delay + jitter, max))
  end

  defp retry_after_ms({:rate_limited, value}), do: normalize_retry_after_ms(value)
  defp retry_after_ms({:llm_busy, value}), do: normalize_retry_after_ms(value)

  defp retry_after_ms({:llm_fallbacks_failed, original_reason, fallback_errors}) do
    retry_after_values =
      ([retry_after_ms(original_reason)] ++ Enum.map(fallback_errors, &fallback_retry_after_ms/1))
      |> Enum.reject(&is_nil/1)

    case retry_after_values do
      [] -> nil
      values -> Enum.max(values)
    end
  end

  defp retry_after_ms(_reason), do: nil

  defp fallback_retry_after_ms(%{reason: reason}), do: retry_after_text_ms(reason)
  defp fallback_retry_after_ms(%{"reason" => reason}), do: retry_after_text_ms(reason)
  defp fallback_retry_after_ms(_reason), do: nil

  defp retry_after_text_ms(reason) when is_binary(reason) do
    case Regex.run(~r/rate_limited,\s*(\d+)/, reason) do
      [_, retry_after] -> normalize_retry_after_ms(retry_after)
      _other -> nil
    end
  end

  defp retry_after_text_ms(_reason), do: nil

  defp normalize_retry_after_ms(value) when is_integer(value) and value > 0 do
    min(value, @max_rate_limit_retry_ms)
  end

  defp normalize_retry_after_ms(value) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} when parsed > 0 -> normalize_retry_after_ms(parsed)
      _other -> @default_rate_limit_retry_ms
    end
  end

  defp normalize_retry_after_ms(_value), do: @default_rate_limit_retry_ms

  defp add_jitter(retry_after_ms) do
    jitter = :rand.uniform(max(1, div(retry_after_ms, 5)))
    retry_after_ms + jitter
  end

  defp schedule_poll(interval_ms) do
    Process.send_after(self(), :poll, interval_ms)
  end
end
