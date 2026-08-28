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
  (`:protocol_storage_verification_cache_ms`, default 15s; `0` disables the
  cache and restores per-call verification). Only successes are cached: every
  failure is re-verified on the next call, and protocol activation clears the
  cache so a mode transition is never served from a stale proof. Activation
  preconditions and activation itself always verify uncached.
  """

  alias Maraithon.Runtime.Config

  @default_ttl_ms 15_000
  @term_key {__MODULE__, :entries}

  @doc """
  Returns the cached value for `key` while it is fresh; otherwise runs
  `verify` and caches the result only when `success?` accepts it.
  """
  def fetch(key, verify, success?) when is_function(verify, 0) and is_function(success?, 1) do
    ttl_ms = ttl_ms()
    now = System.monotonic_time(:millisecond)

    case ttl_ms > 0 and lookup(key, now) do
      {:ok, value} ->
        value

      _miss_or_disabled ->
        value = verify.()
        if ttl_ms > 0 and success?.(value), do: store(key, value, now + ttl_ms)
        value
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

  defp store(key, value, expires_at) do
    entries = :persistent_term.get(@term_key, %{})
    :persistent_term.put(@term_key, Map.put(entries, key, {value, expires_at}))
  end
end
