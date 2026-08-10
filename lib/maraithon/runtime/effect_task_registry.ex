defmodule Maraithon.Runtime.EffectTaskRegistry do
  @moduledoc false

  @restart_wait_ms 5_000
  @retry_interval_ms 10

  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :supervisor,
      shutdown: :infinity,
      restart: :permanent
    }
  end

  def start_link(_opts) do
    deadline = System.monotonic_time(:millisecond) + @restart_wait_ms
    start_registry(deadline)
  end

  defp start_registry(deadline) do
    case Registry.start_link(keys: :unique, name: __MODULE__) do
      {:ok, pid} ->
        {:ok, pid}

      {:error,
       {:shutdown, {:failed_to_start_child, _partition_name, {:already_started, stale_pid}}}} =
          error
      when is_pid(stale_pid) ->
        retry_after_stale_partition(error, stale_pid, deadline)

      {:error, {:already_started, stale_pid}} = error when is_pid(stale_pid) ->
        retry_after_stale_partition(error, stale_pid, deadline)

      other ->
        other
    end
  end

  defp retry_after_stale_partition(error, stale_pid, deadline) do
    if System.monotonic_time(:millisecond) < deadline do
      ref = Process.monitor(stale_pid)

      receive do
        {:DOWN, ^ref, :process, ^stale_pid, _reason} -> :ok
      after
        @retry_interval_ms -> Process.demonitor(ref, [:flush])
      end

      # A dead Registry partition can remain registered for a scheduler turn
      # after its parent exit reaches our supervisor. Retry inside this one
      # child start so restart intensity is not exhausted by that teardown race.
      start_registry(deadline)
    else
      error
    end
  end
end
