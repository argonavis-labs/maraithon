defmodule Maraithon.Runtime.Coordination.StorageVerificationCache do
  @moduledoc """
  Bounded positive-result cache for exact-protocol storage verification.

  Storage verification re-proves recorded migrations, catalog fingerprints,
  roles, ACLs, and the manifest digest. On managed PostgreSQL that costs
  seconds per call, and the runtime asked for it on every poll and inside
  lock-holding coordination transactions, which queued the coordination
  Session's lease renewals behind it and starved every reader of node
  authority.

  A successful verification is reused for a bounded window
  (`:protocol_storage_verification_cache_ms`, default 5m; `0` disables the
  cache and restores per-call verification). Only successes are cached: every
  failure is re-verified on the next call, and protocol activation clears the
  cache so a mode transition is never served from a stale proof. Activation
  preconditions and activation itself always verify uncached.
  """

  alias Maraithon.Runtime.Config

  @default_ttl_ms :timer.minutes(5)
  @term_key {__MODULE__, :entries}

  @doc """
  Returns the cached value for `key` while it is fresh; otherwise runs
  `verify` and caches the result only when `success?` accepts it.
  """
  def fetch(key, verify, success?) when is_function(verify, 0) and is_function(success?, 1) do
    ttl_ms = ttl_ms()
    now = System.monotonic_time(:millisecond)

    if ttl_ms == 0 do
      verify.()
    else
      case lookup(key, now) do
        {:ok, value} -> value
        :miss -> refresh_once(key, verify, success?, ttl_ms)
      end
    end
  end

  @doc "Drops every cached verification. Called around protocol activation."
  def invalidate, do: :persistent_term.put(@term_key, %{})

  @doc false
  def ttl_ms do
    case Config.get(:protocol_storage_verification_cache_ms, @default_ttl_ms) do
      ms when is_integer(ms) and ms >= 0 -> ms
      _invalid -> @default_ttl_ms
    end
  end

  defp lookup(key, now) do
    case Map.get(:persistent_term.get(@term_key, %{}), key) do
      {value, expires_at} when expires_at > now -> {:ok, value}
      _missing_or_expired -> :miss
    end
  end

  # A cache expiry is observed by every hot runtime poll at nearly the same
  # instant. Serialize the miss per node and recheck inside the lock so exactly
  # one caller performs the managed-PostgreSQL catalog proof. Each BEAM node
  # has its own persistent-term cache, so the lock is deliberately node-local.
  defp refresh_once(key, verify, success?, ttl_ms) do
    lock_id = {{__MODULE__, key}, self()}

    case :global.trans(
           lock_id,
           fn ->
             now = System.monotonic_time(:millisecond)

             case lookup(key, now) do
               {:ok, value} -> value
               :miss -> verify_and_store(key, verify, success?, ttl_ms, now)
             end
           end,
           [node()]
         ) do
      :aborted ->
        # Failing open would bypass the proof. Re-verifying directly preserves
        # the previous safe behavior if the local lock service is unavailable.
        verify_and_store(
          key,
          verify,
          success?,
          ttl_ms,
          System.monotonic_time(:millisecond)
        )

      value ->
        value
    end
  end

  defp verify_and_store(key, verify, success?, ttl_ms, now) do
    value = verify.()
    if success?.(value), do: store(key, value, now + ttl_ms)
    value
  end

  defp store(key, value, expires_at) do
    entries = :persistent_term.get(@term_key, %{})
    :persistent_term.put(@term_key, Map.put(entries, key, {value, expires_at}))
  end
end
