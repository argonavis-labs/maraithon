defmodule Maraithon.HTTP.Admission do
  @moduledoc "Database-scoped request serialization and durable provider cooldowns."
  alias Maraithon.Repo

  # Runs inside the bounded HTTP worker, so its database lock and request have
  # the same lifetime. No provider work runs in an OTP coordination callback.
  # Reuse the existing cooldown table; request lanes cannot collide with jobs.
  def run(nil, _timeout, request), do: request.()

  def run({provider, key}, timeout, request)
      when provider in ["gmail"] and is_binary(key) and byte_size(key) in 1..200 do
    queue = "http_" <> provider

    Repo.transaction(
      fn ->
        [[acquired]] =
          Repo.query!(
            "SELECT pg_try_advisory_xact_lock(hashtextextended($1::text, 0))",
            ["#{queue}:#{key}"],
            log: false
          ).rows

        if acquired do
          cooldown =
            Repo.query!(
              """
              SELECT GREATEST(0, CEIL(EXTRACT(EPOCH FROM
                (blocked_until - timezone('UTC', clock_timestamp())))))::bigint
              FROM background_job_rate_limits WHERE queue = $1 AND rate_limit_key = $2
              """,
              [queue, key],
              log: false
            ).rows

          case cooldown do
            [[seconds]] when seconds > 0 ->
              {:error, {:rate_limited, seconds, :provider_cooldown}}

            _ ->
              result = request.()
              persist_cooldown(queue, key, result)
              result
          end
        else
          {:error, {:rate_limited, 1, :provider_busy}}
        end
      end,
      timeout: timeout + 5_000
    )
    |> case do
      {:ok, result} -> result
      {:error, _} -> {:error, {:http_error, "request_admission_unavailable"}}
    end
  end

  defp persist_cooldown(queue, key, {:error, {:rate_limited, seconds, _}})
       when is_integer(seconds) and seconds >= 0 do
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

  defp persist_cooldown(queue, key, {:error, {:rate_limited, _}}),
    do: persist_cooldown(queue, key, {:error, {:rate_limited, 30, :provider_limited}})

  defp persist_cooldown(_, _, _), do: :ok
end
