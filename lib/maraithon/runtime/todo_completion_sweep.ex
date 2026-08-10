defmodule Maraithon.Runtime.TodoCompletionSweep do
  @moduledoc """
  Runs deterministic and model-assisted completion for durable user partitions.

  The recurring coordinator discovers tenants; the fair model/user lane owns
  execution, retries, and crash recovery. This module has no timer process.
  """

  alias Maraithon.Todos.{CompletionSweep, CrossSourceCompletion, UserBatch}

  require Logger

  def run_once(opts \\ []) do
    user_ids = UserBatch.open_todo_user_ids(opts)
    bounded_opts = Keyword.put(opts, :user_ids, user_ids)

    bounded_opts
    |> CompletionSweep.run_for_all_users()
    |> Map.put(:cross_source, run_cross_source_pass(bounded_opts))
  end

  @doc "Executes one tenant partition."
  def run_for_user(user_id, opts \\ [])

  def run_for_user(user_id, opts) when is_binary(user_id) do
    deterministic = CompletionSweep.run_for_user(user_id, opts)
    Map.put(deterministic, :cross_source, run_cross_source_user(user_id, opts))
  rescue
    error ->
      Logger.warning("Todo completion user partition crashed",
        user_fingerprint: Maraithon.Redaction.fingerprint(user_id),
        failure_code: Maraithon.Redaction.error_class(error)
      )

      {:error, Maraithon.Redaction.error_class(error)}
  catch
    kind, reason -> {:error, {kind, Maraithon.Redaction.error_class(reason)}}
  end

  def run_for_user(_user_id, _opts), do: {:error, :invalid_user}

  defp run_cross_source_user(user_id, opts) do
    cross_source_opts =
      Keyword.take(opts, [
        :now,
        :llm_complete,
        :live_sources,
        :source_bundle,
        :source_bundle_fetcher,
        :source_timeout_ms,
        :source_skill_config
      ])

    CrossSourceCompletion.run_for_user(user_id, cross_source_opts)
  rescue
    error ->
      Logger.warning("Cross-source completion user partition failed",
        user_fingerprint: Maraithon.Redaction.fingerprint(user_id),
        failure_code: Maraithon.Redaction.error_class(error)
      )

      {:error, Maraithon.Redaction.error_class(error)}
  end

  defp run_cross_source_pass(opts) do
    summary =
      opts
      |> Keyword.take([
        :user_ids,
        :now,
        :llm_complete,
        :live_sources,
        :source_bundle,
        :source_bundle_fetcher,
        :source_timeout_ms,
        :source_skill_config
      ])
      |> CrossSourceCompletion.run_for_all_users()

    if summary.completed > 0 or summary.errors > 0 do
      Logger.info("Cross-source completion cycle",
        users: summary.users,
        checked: summary.checked,
        completed: summary.completed,
        skipped: summary.skipped,
        errors: summary.errors
      )
    end

    summary
  rescue
    error ->
      Logger.warning("Cross-source completion cycle failed",
        failure_code: Maraithon.Redaction.error_class(error)
      )

      %{users: 0, checked: 0, completed: 0, skipped: 0, errors: 1}
  end
end
