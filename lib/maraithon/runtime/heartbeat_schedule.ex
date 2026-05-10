defmodule Maraithon.Runtime.HeartbeatSchedule do
  @moduledoc """
  Deterministic phase-aligned scheduling for recurring agent heartbeats.

  When several agents share the same wakeup interval (e.g. every 10 minutes
  for the Chief of Staff loop), naïve scheduling fires them all at the same
  wall-clock instant — a thundering herd that spikes DB and LLM load. This
  module spreads the work across the interval by giving each agent a stable
  phase offset derived from a hash of its id.

  Two callers:

    * `next_fire_at/3` — what's the next fire time that's at least `now + 1ms`
      and aligned to (agent's phase, interval)?
    * `phase_offset_ms/2` — the raw offset, in case you want to use it
      directly.

  Inspired by openclaw's `heartbeat-schedule.ts`.
  """

  @doc """
  Compute the deterministic phase offset (in ms) for `agent_id` on a given
  interval. Always in `[0, interval_ms)`.
  """
  def phase_offset_ms(agent_id, interval_ms)
      when is_binary(agent_id) and is_integer(interval_ms) and interval_ms > 0 do
    :erlang.phash2(agent_id, interval_ms)
  end

  def phase_offset_ms(_agent_id, _interval_ms), do: 0

  @doc """
  Return the next DateTime at which an agent on a given heartbeat interval
  should fire, aligned to its phase offset.

  `now` defaults to the current UTC time.
  """
  def next_fire_at(agent_id, interval_ms, now \\ DateTime.utc_now())

  def next_fire_at(agent_id, interval_ms, %DateTime{} = now)
      when is_binary(agent_id) and is_integer(interval_ms) and interval_ms > 0 do
    offset = phase_offset_ms(agent_id, interval_ms)
    now_unix_ms = DateTime.to_unix(now, :millisecond)

    next_ms =
      cond do
        rem(now_unix_ms - offset, interval_ms) == 0 ->
          now_unix_ms + interval_ms

        true ->
          # Round up to next slot boundary aligned to offset.
          base = div(now_unix_ms - offset, interval_ms) + 1
          base * interval_ms + offset
      end

    DateTime.from_unix!(next_ms, :millisecond)
  end

  def next_fire_at(_agent_id, _interval_ms, _now), do: DateTime.utc_now()

  @doc """
  Schedule a recurring heartbeat for `agent_id` via `Maraithon.Runtime.Scheduler`.

  This is a thin wrapper that computes the next phase-aligned fire time and
  calls `Scheduler.schedule_at/4`. Callers that don't want the durable
  scheduler can use `next_fire_at/3` directly.
  """
  def schedule_next_heartbeat(agent_id, job_type, interval_ms, payload \\ %{}, scheduler \\ nil) do
    fire_at = next_fire_at(agent_id, interval_ms)
    scheduler = scheduler || Maraithon.Runtime.Scheduler
    scheduler.schedule_at(agent_id, job_type, fire_at, payload)
  end
end
