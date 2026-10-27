defmodule Maraithon.Runtime.StalenessTriageSweep do
  @moduledoc """
  Runs one staleness-triage tenant partition in the fair model/user lane.

  The durable recurring coordinator rotates discovery across open-todo users;
  this module has no scheduler process or local timer authority.
  """

  alias Maraithon.Todos.StalenessTriage
  alias Maraithon.Todos.UserBatch

  require Logger

  @doc """
  Runs one full sweep synchronously (directly callable in tests, no timer).
  """
  def run_once(opts \\ []) do
    user_ids = UserBatch.open_todo_user_ids(opts)

    empty = %{users: length(user_ids), proposed: 0, skipped: 0, errors: 0}

    user_ids
    |> Enum.reduce(empty, fn user_id, acc ->
      case run_for_user(user_id, opts) do
        {:ok, %{sent: true}} -> %{acc | proposed: acc.proposed + 1}
        {:ok, _held} -> %{acc | skipped: acc.skipped + 1}
        {:skip, _reason} -> %{acc | skipped: acc.skipped + 1}
        {:error, _reason} -> %{acc | errors: acc.errors + 1}
      end
    end)
  end

  # One user's failure/crash must never block the sweep for the others, and
  # must never be silently swallowed (SPEC 05 silent-failure rule).
  def run_for_user(user_id, opts \\ [])

  def run_for_user(user_id, opts) when is_binary(user_id) do
    triage_opts = Keyword.take(opts, [:now, :llm_complete, :llm_timeout_ms, :push_deliver])

    case StalenessTriage.run_for_user(user_id, triage_opts) do
      {:error, reason} = error ->
        Logger.info("Staleness triage failed for user",
          user_fingerprint: Maraithon.Redaction.fingerprint(user_id),
          failure_code: Maraithon.Redaction.error_class(reason)
        )

        error

      other ->
        other
    end
  rescue
    error ->
      failure_code = Maraithon.Redaction.error_class(error)

      Logger.info("Staleness triage crashed for user",
        user_fingerprint: Maraithon.Redaction.fingerprint(user_id),
        failure_code: failure_code
      )

      {:error, failure_code}
  end

  def run_for_user(_user_id, _opts), do: {:error, :invalid_user}
end
