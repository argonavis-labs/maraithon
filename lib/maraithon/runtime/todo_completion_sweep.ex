defmodule Maraithon.Runtime.TodoCompletionSweep do
  @moduledoc """
  Runs deterministic and model-assisted completion for durable user partitions.

  The recurring coordinator discovers tenants; the fair model/user lane owns
  execution, retries, and crash recovery. This module has no timer process.
  """

  alias Maraithon.Accounts.ConnectedAccount
  alias Maraithon.ChiefOfStaff.{Acquisition, SourceScope}
  alias Maraithon.Connectors.SourceCursors
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

  @doc "Executes one exact connected-account closure partition."
  def run_for_account(account, opts \\ [])

  def run_for_account(%ConnectedAccount{status: "connected"} = account, opts) do
    source_scope = account_source_scope(account)

    with {:ok, source_bundle, proposed_watermarks} <-
           acquire_account_delta(account, source_scope, opts) do
      account_opts =
        opts
        |> Keyword.put(:source_account_id, account.id)
        |> Keyword.put(:source_scope, source_scope)
        |> maybe_put_source_bundle(source_bundle)

      result = run_for_user(account.user_id, account_opts)

      with :ok <- maybe_advance_closure_watermarks(result, proposed_watermarks) do
        result
      end
    end
  end

  def run_for_account(%ConnectedAccount{}, _opts), do: {:skip, :account_not_connected}
  def run_for_account(_account, _opts), do: {:error, :invalid_account}

  defp acquire_account_delta(account, source_scope, opts) when is_list(opts) do
    cond do
      Keyword.has_key?(opts, :source_bundle) ->
        {:ok, Keyword.get(opts, :source_bundle), []}

      Keyword.get(opts, :live_sources, true) == false ->
        {:ok, nil, []}

      true ->
        do_acquire_account_delta(account, source_scope, opts)
    end
  end

  defp do_acquire_account_delta(account, source_scope, opts) do
    now = Keyword.get(opts, :now) || DateTime.utc_now()

    context = %{
      user_id: account.user_id,
      timestamp: now,
      trigger: %{type: :pubsub_event, job_type: "source_account_closure"},
      event: %{topic: account_event_topic(account), payload: %{}},
      recent_events: [],
      source_scope: source_scope,
      source_watermark_role: "closure",
      defer_watermark_advance: true
    }

    {bundle, _telemetry, proposed_watermarks} =
      Acquisition.build(
        account.user_id,
        ["followthrough"],
        %{"followthrough" => %{"lookback_hours" => 48}},
        context
      )

    {:ok, bundle, proposed_watermarks}
  rescue
    error -> {:error, Maraithon.Redaction.error_class(error)}
  catch
    kind, reason -> {:error, {kind, Maraithon.Redaction.error_class(reason)}}
  end

  defp maybe_put_source_bundle(opts, source_bundle) when is_map(source_bundle) do
    Keyword.put(opts, :source_bundle, source_bundle)
  end

  defp maybe_put_source_bundle(opts, _source_bundle), do: opts

  defp maybe_advance_closure_watermarks(result, proposed_watermarks) do
    if closure_result_settled?(result) do
      Enum.reduce_while(proposed_watermarks, :ok, fn proposal, :ok ->
        case SourceCursors.put(proposal.account, proposal.kind, %{"value" => proposal.value}) do
          {:ok, _cursor} -> {:cont, :ok}
          {:error, reason} -> {:halt, {:error, {:closure_cursor_advance_failed, reason}}}
        end
      end)
    else
      :ok
    end
  end

  defp closure_result_settled?(%{errors: 0, cross_source: {:error, _reason}}), do: false
  defp closure_result_settled?(%{errors: 0, cross_source: {:skip, :no_open_todos}}), do: false
  defp closure_result_settled?(%{errors: 0}), do: true
  defp closure_result_settled?(_result), do: false

  defp account_source_scope(%ConnectedAccount{provider: provider} = account) do
    service = if provider == "google" or String.starts_with?(provider, "google:"), do: "gmail"
    SourceScope.for_account(account, service)
  end

  defp account_event_topic(%ConnectedAccount{provider: "slack:" <> rest}) do
    team_id = rest |> String.split(":", parts: 2) |> List.first()
    "slack:#{team_id}"
  end

  defp account_event_topic(%ConnectedAccount{id: id}), do: "email:account-#{id}"

  defp run_cross_source_user(user_id, opts) do
    cross_source_opts =
      Keyword.take(opts, [
        :now,
        :llm_complete,
        :live_sources,
        :source_bundle,
        :source_bundle_fetcher,
        :source_timeout_ms,
        :source_skill_config,
        :source_account_id,
        :source_account_unassigned?,
        :source_scope
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
