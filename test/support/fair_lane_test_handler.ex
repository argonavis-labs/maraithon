defmodule Maraithon.TestSupport.FairLaneTestHandler do
  @moduledoc false

  alias Maraithon.Runtime.BackgroundJob

  def execute(%BackgroundJob{} = job) do
    observer = Process.whereis(:fair_lane_test_observer)
    if is_pid(observer), do: send(observer, {:fair_lane_started, self(), job})

    case Map.get(job.payload || %{}, "mode", "ok") do
      "block" ->
        receive do
          {:release_fair_lane_job, id} when id == job.id ->
            {:ok, %{partition: job.partition_key}}
        end

      "retry" ->
        {:error, {:retry_after, 60, :provider_rate_limited}}

      "past_reschedule" ->
        {:ok, %{partition: job.partition_key},
         {:reschedule_at, DateTime.add(DateTime.utc_now(), -60, :second)}}

      _other ->
        {:ok, %{partition: job.partition_key}}
    end
  end
end
