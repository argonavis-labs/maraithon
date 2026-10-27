defmodule Maraithon.HTTP.Admission do
  @moduledoc "Database-scoped request serialization and durable provider cooldowns."
  alias Maraithon.Repo

  @doc "A closed local rejection proves that this request never entered the provider."
  def local_deferral({:rate_limited, seconds, kind} = reason)
      when is_integer(seconds) and seconds > 0 and kind in [:provider_busy, :provider_cooldown],
      do: reason

  def local_deferral({:provider_error, provider, reason, _copy})
      when provider in [:gmail, :slack],
      do: local_deferral(reason)

  def local_deferral(_), do: nil

  # How long a request may wait for a busy lane before it is rejected. Polls
  # sleep without a database connection, so waiting costs the pool nothing;
  # only the admitted request holds a connection, for its own duration.
  @lane_poll_interval_ms 100
  @max_lane_wait_ms 5_000

  # Runs inside the bounded HTTP worker, so its database lock and request have
  # the same lifetime. No provider work runs in an OTP coordination callback.
  # Reuse the existing cooldown table; request lanes cannot collide with jobs.
  def run(nil, _timeout, request), do: request.()

  def run({"gmail", key}, timeout, request), do: run([{"gmail", key, 0}], timeout, request)

  def run(lanes, timeout, request) when is_list(lanes) and length(lanes) in 1..2 do
    lanes = Enum.sort(lanes)

    true =
      Enum.all?(lanes, fn {provider, key, minimum} ->
        provider in ~w(gmail slack slack_channel) and is_binary(key) and byte_size(key) in 1..200 and
          minimum in 0..1
      end)

    queues = Enum.map(lanes, fn {provider, _, _} -> "http_" <> provider end)
    keys = Enum.map(lanes, &elem(&1, 1))
    deadline = System.monotonic_time(:millisecond) + lane_wait_ms(timeout)

    admit(lanes, queues, keys, timeout, request, deadline)
  end

  # A busy lane is a request in flight for the same provider scope, typically
  # a sibling job or skill reading the same workspace or mailbox at the same
  # moment. Wait for it to finish rather than reject on sight: an instant
  # rejection surfaced as `rate_limited` and lost the whole source for that
  # cycle (every Slack acquisition cycle that overlapped the reconciliation
  # plan, and Gmail deltas during a mailbox drain). Only a lane still busy at
  # the deadline is reported as `:provider_busy`, a closed local rejection
  # proving the request never entered the provider.
  defp admit(lanes, queues, keys, timeout, request, deadline) do
    case attempt(lanes, queues, keys, timeout, request) do
      :lane_busy ->
        remaining = deadline - System.monotonic_time(:millisecond)

        if remaining > 0 do
          Process.sleep(min(@lane_poll_interval_ms + :rand.uniform(50), remaining))
          admit(lanes, queues, keys, timeout, request, deadline)
        else
          {:error, {:rate_limited, 1, :provider_busy}}
        end

      result ->
        result
    end
  end

  defp attempt(lanes, queues, keys, timeout, request) do
    Repo.transaction(
      fn ->
        Enum.each(Enum.zip(queues, keys), fn {queue, key} ->
          [[acquired]] =
            Repo.query!(
              "SELECT pg_try_advisory_xact_lock(hashtextextended($1::text, 0))",
              ["#{queue}:#{key}"],
              log: false
            ).rows

          unless acquired, do: Repo.rollback(:lane_busy)
        end)

        [[seconds]] =
          Repo.query!(
            """
            SELECT COALESCE(MAX(GREATEST(0, CEIL(EXTRACT(EPOCH FROM
              (blocked_until - timezone('UTC', clock_timestamp())))))), 0)::bigint
            FROM background_job_rate_limits
            WHERE (queue, rate_limit_key) IN (SELECT * FROM unnest($1::text[], $2::text[]))
            """,
            [queues, keys],
            log: false
          ).rows

        if seconds > 0 do
          {:error, {:rate_limited, seconds, :provider_cooldown}}
        else
          result = request.()

          Enum.each(lanes, fn {provider, key, minimum} ->
            seconds = max(minimum, retry_seconds(result))
            if seconds > 0, do: persist_cooldown("http_" <> provider, key, seconds)
          end)

          result
        end
      end,
      timeout: timeout + 5_000
    )
    |> case do
      {:ok, result} -> result
      {:error, :lane_busy} -> :lane_busy
      {:error, _} -> {:error, {:http_error, "request_admission_unavailable"}}
    end
  end

  defp lane_wait_ms(timeout) when is_integer(timeout) and timeout > 0,
    do: min(@max_lane_wait_ms, div(timeout, 2))

  defp lane_wait_ms(_timeout), do: 0

  defp retry_seconds({:error, {:rate_limited, seconds, _}})
       when is_integer(seconds) and seconds >= 0,
       do: seconds

  defp retry_seconds({:error, {:rate_limited, _}}), do: 30
  defp retry_seconds(_), do: 0

  defp persist_cooldown(queue, key, seconds) do
    Repo.query!(
      """
      INSERT INTO background_job_rate_limits
        (queue, rate_limit_key, blocked_until, inserted_at, updated_at)
      VALUES ($1, $2, timezone('UTC', clock_timestamp()) + ($3::bigint * interval '1 second'),
        timezone('UTC', clock_timestamp()), timezone('UTC', clock_timestamp()))
      ON CONFLICT (queue, rate_limit_key) DO UPDATE
      SET blocked_until = GREATEST(background_job_rate_limits.blocked_until, EXCLUDED.blocked_until),
          updated_at = EXCLUDED.updated_at
      """,
      [queue, key, min(seconds, 2_147_483_647)],
      log: false
    )
  end
end
