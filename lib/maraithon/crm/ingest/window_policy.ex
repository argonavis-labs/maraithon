defmodule Maraithon.Crm.Ingest.WindowPolicy do
  @moduledoc """
  Pure decision functions for whether a `Crm.Ingest.Window` is ready to flush.

  All inputs come from the caller; no DB, no time side-effects. The policy is
  intentionally simple so the runtime can call it cheaply on every observation.

  Defaults match the "premium, less often" cost ceiling from the spec:

  * windows of up to ~50 observations, or
  * up to ~15 minutes of buffered activity, or
  * driver-forced flushes (pull sweeps, backfill pages)

  …subject to a per-(user, source) hourly flush cap.
  """

  @max_observations 50
  @max_age_minutes 15
  @max_flushes_per_hour 6

  @type window_input :: %{required(:observation_count) => non_neg_integer(),
                           required(:opened_at) => DateTime.t()}

  def max_observations, do: @max_observations
  def max_age_minutes, do: @max_age_minutes
  def max_flushes_per_hour, do: @max_flushes_per_hour

  @doc """
  Should this window flush now?

    * `flush_count_last_hour` — number of flushes already enqueued for this
      `(user_id, source)` in the trailing hour.
    * `driver_force?` — `true` when called by the periodic pull sweep or a
      backfill page that wants to close out whatever has accumulated.
  """
  @spec ready?(window_input(), DateTime.t(), non_neg_integer(), boolean()) :: boolean()
  def ready?(window, now, flush_count_last_hour, driver_force?)

  def ready?(_window, _now, flush_count, _force)
      when is_integer(flush_count) and flush_count >= @max_flushes_per_hour,
      do: false

  def ready?(%{observation_count: count}, _now, _flush_count, true) when count > 0, do: true
  def ready?(_window, _now, _flush_count, true), do: false

  def ready?(%{observation_count: count}, _now, _flush_count, _force)
      when is_integer(count) and count >= @max_observations,
      do: true

  def ready?(%{observation_count: count, opened_at: %DateTime{} = opened_at}, %DateTime{} = now,
        _flush_count, _force)
      when is_integer(count) and count > 0 do
    DateTime.diff(now, opened_at, :second) >= @max_age_minutes * 60
  end

  def ready?(_window, _now, _flush_count, _force), do: false
end
