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
  @max_entries 32

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
  def invalidate do
    publish(fn ->
      :persistent_term.put(@term_key, %{generation: make_ref(), entries: %{}})
    end)
  end

  @doc false
  def ttl_ms do
    case Config.get(:protocol_storage_verification_cache_ms, @default_ttl_ms) do
      ms when is_integer(ms) and ms >= 0 -> ms
      _invalid -> @default_ttl_ms
    end
  end

  defp lookup(key, now) do
    case Map.get(state().entries, key) do
      {value, expires_at} when expires_at > now -> {:ok, value}
      _missing_or_expired -> :miss
    end
  end

  # A cache expiry is observed by every hot runtime poll at nearly the same
  # instant. Serialize the miss per node and recheck inside the lock so exactly
  # one caller performs the managed-PostgreSQL catalog proof. Each BEAM node
  # has its own persistent-term cache, so the lock is deliberately node-local.
  defp refresh_once(key, verify, success?, ttl_ms) do
    lock_id = {{__MODULE__, {:refresh, key}}, self()}

    case :global.trans(
           lock_id,
           fn ->
             now = System.monotonic_time(:millisecond)

             case lookup(key, now) do
               {:ok, value} -> value
               :miss -> verify_and_store(key, verify, success?, ttl_ms)
             end
           end,
           [node()]
         ) do
      :aborted ->
        raise "storage verification cache refresh unavailable"

      value ->
        value
    end
  end

  defp verify_and_store(key, verify, success?, ttl_ms, retries \\ 2) do
    generation = state().generation
    value = verify.()

    result =
      publish(fn ->
        current = state()

        if current.generation == generation do
          if success?.(value) do
            now = System.monotonic_time(:millisecond)

            entries =
              current.entries
              |> Enum.filter(fn {_key, {_value, expiry}} -> expiry > now end)
              |> Enum.sort_by(fn {_key, {_value, expiry}} -> expiry end, :desc)
              |> Enum.take(@max_entries - 1)
              |> Map.new()
              |> Map.put(key, {value, now + ttl_ms})

            :persistent_term.put(@term_key, %{current | entries: entries})
          end

          {:verified, value}
        else
          :invalidated
        end
      end)

    case result do
      {:verified, value} ->
        value

      :invalidated when retries > 0 ->
        verify_and_store(key, verify, success?, ttl_ms, retries - 1)

      :invalidated ->
        raise "storage verification repeatedly invalidated during verification"
    end
  end

  # Verification never holds this short publication lock. Different proof
  # keys cannot overwrite each other's entries, and a proof that overlaps an
  # activation must verify again in the new generation before it can return.
  defp publish(fun) do
    case :global.trans({{__MODULE__, :publication}, self()}, fun, [node()]) do
      :aborted -> raise "storage verification cache publication unavailable"
      value -> value
    end
  end

  defp state do
    case :persistent_term.get(@term_key, nil) do
      %{generation: _, entries: _} = state -> state
      _old_or_missing -> %{generation: :initial, entries: %{}}
    end
  end
end
