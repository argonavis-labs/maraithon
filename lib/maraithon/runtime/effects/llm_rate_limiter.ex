defmodule Maraithon.Runtime.Effects.LLMRateLimiter do
  @moduledoc """
  Process-local gate for outbound LLM calls.

  Provider rate limits are usually account or provider scoped, so letting every
  pending effect retry independently turns one 429 into a retry storm. This
  gate keeps LLM concurrency bounded and shares provider retry-after cooldowns
  across effect workers in this node.
  """

  use GenServer

  alias Maraithon.Runtime.Config, as: RuntimeConfig

  require Logger

  @default_max_concurrency 1
  @default_busy_retry_ms 1_000
  @default_rate_limit_ms 60_000
  @max_cooldown_ms 300_000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Reserve one LLM execution slot.

  Returns `{:error, {:rate_limited, retry_after_ms}}` while a provider cooldown
  is active, or `{:error, {:llm_busy, retry_after_ms}}` when local concurrency is
  already full.
  """
  def checkout do
    call(:checkout, :ok)
  end

  @doc """
  Release one LLM execution slot for the calling process.
  """
  def checkin do
    cast({:checkin, self()})
  end

  @doc """
  Share a provider retry-after with future callers.
  """
  def record_rate_limit(retry_after_ms) do
    call({:record_rate_limit, retry_after_ms}, :ok)
  end

  def reset do
    call(:reset, :ok)
  end

  def status do
    call(:status, %{in_flight: 0, max_concurrency: @default_max_concurrency, blocked_for_ms: 0})
  end

  @impl true
  def init(opts) do
    max_concurrency =
      Keyword.get(opts, :max_concurrency) ||
        RuntimeConfig.positive_integer(:llm_max_concurrency, @default_max_concurrency)

    busy_retry_ms =
      Keyword.get(opts, :busy_retry_ms) ||
        RuntimeConfig.positive_integer(:llm_busy_retry_ms, @default_busy_retry_ms)

    {:ok,
     %{
       blocked_until_ms: nil,
       busy_retry_ms: busy_retry_ms,
       holders: %{},
       in_flight: 0,
       max_concurrency: max_concurrency
     }}
  end

  @impl true
  def handle_call(:checkout, {pid, _tag}, state) do
    now_ms = now_ms()

    cond do
      blocked_for_ms(state, now_ms) > 0 ->
        {:reply, {:error, {:rate_limited, blocked_for_ms(state, now_ms)}}, state}

      state.in_flight >= state.max_concurrency ->
        {:reply, {:error, {:llm_busy, state.busy_retry_ms}}, state}

      true ->
        {:reply, :ok, add_holder(state, pid)}
    end
  end

  def handle_call(:reset, _from, state) do
    Enum.each(state.holders, fn {_pid, {ref, _count}} -> Process.demonitor(ref, [:flush]) end)

    {:reply, :ok, %{state | blocked_until_ms: nil, holders: %{}, in_flight: 0}}
  end

  def handle_call(:status, _from, state) do
    status = %{
      blocked_for_ms: blocked_for_ms(state, now_ms()),
      in_flight: state.in_flight,
      max_concurrency: state.max_concurrency
    }

    {:reply, status, state}
  end

  def handle_call({:record_rate_limit, retry_after_ms}, _from, state) do
    retry_after_ms = normalize_retry_after_ms(retry_after_ms)
    blocked_until_ms = now_ms() + retry_after_ms

    next_blocked_until_ms =
      case state.blocked_until_ms do
        nil -> blocked_until_ms
        existing -> max(existing, blocked_until_ms)
      end

    Logger.warning("LLM provider cooldown active", retry_after_ms: retry_after_ms)

    {:reply, :ok, %{state | blocked_until_ms: next_blocked_until_ms}}
  end

  @impl true
  def handle_cast({:checkin, pid}, state) do
    {:noreply, remove_holder(state, pid)}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, pid, _reason}, state) do
    case Map.get(state.holders, pid) do
      {^ref, count} ->
        {:noreply,
         %{
           state
           | holders: Map.delete(state.holders, pid),
             in_flight: max(0, state.in_flight - count)
         }}

      _other ->
        {:noreply, state}
    end
  end

  defp add_holder(state, pid) do
    holders =
      case Map.get(state.holders, pid) do
        nil ->
          Map.put(state.holders, pid, {Process.monitor(pid), 1})

        {ref, count} ->
          Map.put(state.holders, pid, {ref, count + 1})
      end

    %{state | holders: holders, in_flight: state.in_flight + 1}
  end

  defp remove_holder(state, pid) do
    case Map.get(state.holders, pid) do
      nil ->
        state

      {ref, 1} ->
        Process.demonitor(ref, [:flush])
        %{state | holders: Map.delete(state.holders, pid), in_flight: max(0, state.in_flight - 1)}

      {ref, count} ->
        %{
          state
          | holders: Map.put(state.holders, pid, {ref, count - 1}),
            in_flight: max(0, state.in_flight - 1)
        }
    end
  end

  defp blocked_for_ms(%{blocked_until_ms: nil}, _now_ms), do: 0

  defp blocked_for_ms(%{blocked_until_ms: blocked_until_ms}, now_ms) do
    max(0, blocked_until_ms - now_ms)
  end

  defp normalize_retry_after_ms(value) when is_integer(value) and value > 0 do
    min(value, @max_cooldown_ms)
  end

  defp normalize_retry_after_ms(value) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} when parsed > 0 -> normalize_retry_after_ms(parsed)
      _other -> @default_rate_limit_ms
    end
  end

  defp normalize_retry_after_ms(_value), do: @default_rate_limit_ms

  defp now_ms, do: System.monotonic_time(:millisecond)

  defp call(message, fallback) do
    case Process.whereis(__MODULE__) do
      nil ->
        fallback

      _pid ->
        GenServer.call(__MODULE__, message)
    end
  catch
    :exit, _reason -> fallback
  end

  defp cast(message) do
    case Process.whereis(__MODULE__) do
      nil -> :ok
      _pid -> GenServer.cast(__MODULE__, message)
    end
  end
end
