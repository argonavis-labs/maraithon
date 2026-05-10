defmodule Maraithon.ContextCache do
  @moduledoc """
  ETS-backed cache for per-user "today digests" and other short-lived context
  slices that the Telegram assistant can read instantly instead of recomputing.

  Designed for the hot path: writers (Chief of Staff skills) put summaries on
  their own cadence, and readers (Context.build) fetch synchronously without
  hitting the database.
  """

  use GenServer

  @table :maraithon_context_cache
  @default_digest_ttl_ms 30 * 60 * 1_000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Store a today digest for `user_id`. `ttl_ms` defaults to 30 minutes.
  """
  def put_digest(user_id, digest, ttl_ms \\ @default_digest_ttl_ms)
      when is_binary(user_id) and is_map(digest) and is_integer(ttl_ms) and ttl_ms > 0 do
    ensure_table()
    expires_at = System.monotonic_time(:millisecond) + ttl_ms

    digest_with_meta =
      digest
      |> Map.put_new(:generated_at, DateTime.utc_now())
      |> Map.put(:expires_at_monotonic_ms, expires_at)

    :ets.insert(@table, {{:digest, user_id}, digest_with_meta, expires_at})
    :ok
  end

  @doc """
  Fetch the cached digest for `user_id`. Returns nil if missing or expired.
  """
  def get_digest(user_id) when is_binary(user_id) do
    case ensure_table() do
      :ok ->
        now = System.monotonic_time(:millisecond)

        case :ets.lookup(@table, {:digest, user_id}) do
          [{_key, digest, expires_at}] when expires_at > now ->
            Map.delete(digest, :expires_at_monotonic_ms)

          [{_key, _digest, _expired}] ->
            :ets.delete(@table, {:digest, user_id})
            nil

          [] ->
            nil
        end

      :error ->
        nil
    end
  end

  def get_digest(_user_id), do: nil

  @doc """
  Forget the digest for a user. Useful in tests and after explicit refreshes.
  """
  def forget_digest(user_id) when is_binary(user_id) do
    case ensure_table() do
      :ok ->
        :ets.delete(@table, {:digest, user_id})
        :ok

      :error ->
        :ok
    end
  end

  @doc false
  def reset do
    try do
      :ets.delete_all_objects(@table)
      :ok
    rescue
      ArgumentError -> :ok
    end
  end

  @impl true
  def init(_opts) do
    create_table()
    {:ok, %{}}
  end

  defp create_table do
    case :ets.whereis(@table) do
      :undefined ->
        :ets.new(@table, [
          :named_table,
          :public,
          :set,
          read_concurrency: true,
          write_concurrency: true
        ])

      _existing ->
        @table
    end
  end

  defp ensure_table do
    case :ets.whereis(@table) do
      :undefined ->
        # Server hasn't started yet (e.g. unit tests bypassing the supervisor).
        case start_link([]) do
          {:ok, _pid} -> :ok
          {:error, {:already_started, _pid}} -> :ok
          _other -> :error
        end

      _existing ->
        :ok
    end
  end
end
