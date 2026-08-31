defmodule Maraithon.Runtime.SourceAccountAdmission do
  @moduledoc false

  alias Maraithon.Repo

  @lock_namespace "maraithon.source-account-admission:"
  @reservation_retry_ms 100
  @default_reservation_timeout_ms 30_000
  # A session-level advisory lock lives on the checked-out connection. Keep it
  # alive long enough for the caller to observe its own deadline, release all
  # reservations, and return a domain error instead of having DBConnection
  # tear the session down at exactly the same instant.
  @checkout_cleanup_grace_ms 15_000

  @doc false
  def with_reservations(account_ids, fun)
      when is_list(account_ids) and is_function(fun, 0) do
    deadline =
      System.monotonic_time(:millisecond) + @default_reservation_timeout_ms

    with_reservations(account_ids, deadline, fun)
  end

  def with_reservations(_account_ids, _fun),
    do: {:error, :invalid_source_account_reservations}

  @doc false
  def with_reservations(account_ids, deadline, fun)
      when is_list(account_ids) and is_integer(deadline) and is_function(fun, 0) do
    account_ids = account_ids |> Enum.uniq() |> Enum.sort()

    if account_ids != [] and Enum.all?(account_ids, &(is_integer(&1) and &1 > 0)) do
      checkout_timeout =
        max(deadline - System.monotonic_time(:millisecond), 1) + @checkout_cleanup_grace_ms

      Repo.checkout(
        fn ->
          reserve_until(account_ids, deadline, fun)
        end,
        timeout: checkout_timeout
      )
    else
      {:error, :invalid_source_account_reservations}
    end
  end

  def with_reservations(_account_ids, _deadline, _fun),
    do: {:error, :invalid_source_account_reservations}

  @doc false
  def try_transaction_lock(account_id) when is_integer(account_id) and account_id > 0 do
    case Repo.query!(
           "SELECT pg_try_advisory_xact_lock(hashtextextended($1::text, 0))",
           [lock_key(account_id)],
           log: false
         ).rows do
      [[true]] -> :ok
      _reserved -> {:error, :source_account_reserved}
    end
  end

  def try_transaction_lock(_account_id), do: {:error, :invalid_source_account_reservation}

  defp reserve_until(account_ids, deadline, fun) do
    case with_acquired(account_ids, fun) do
      {:busy, _account_id} ->
        if System.monotonic_time(:millisecond) < deadline do
          Process.sleep(@reservation_retry_ms)
          reserve_until(account_ids, deadline, fun)
        else
          {:error, :source_account_replay_reservation_timeout}
        end

      result ->
        result
    end
  end

  defp with_acquired([], fun), do: fun.()

  defp with_acquired([account_id | rest], fun) do
    case Repo.query!(
           "SELECT pg_try_advisory_lock(hashtextextended($1::text, 0))",
           [lock_key(account_id)],
           log: false
         ).rows do
      [[true]] ->
        try do
          with_acquired(rest, fun)
        after
          release_one!(account_id)
        end

      _reserved ->
        {:busy, account_id}
    end
  end

  defp release_one!(account_id) do
    case Repo.query!(
           "SELECT pg_advisory_unlock(hashtextextended($1::text, 0))",
           [lock_key(account_id)],
           log: false
         ).rows do
      [[true]] -> :ok
      _not_owned -> raise "source account admission reservation was not owned"
    end
  end

  defp lock_key(account_id), do: @lock_namespace <> Integer.to_string(account_id)
end
