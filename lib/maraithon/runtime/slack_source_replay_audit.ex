defmodule Maraithon.Runtime.SlackSourceReplayAudit do
  @moduledoc false

  import Ecto.Query

  alias Maraithon.Accounts.ConnectedAccount
  alias Maraithon.ChiefOfStaff.{Acquisition, SourceBundle, SourceScope}
  alias Maraithon.Repo
  alias Maraithon.Runtime.BackgroundJobs
  alias Maraithon.Runtime.PeriodicJobs
  alias Maraithon.Runtime.SlackSourceReplay
  alias Maraithon.Runtime.SourceAccountAdmission
  alias Maraithon.Runtime.SourceAccountDiscovery
  alias Maraithon.Runtime.SourceCycle
  alias Maraithon.Runtime.SourceCycleItem
  alias Maraithon.Runtime.SourceCycleProofs

  @run_timeout_ms 720_000
  @deadline_cleanup_reserve_ms 15_000
  @poll_interval_ms 2_000

  @discovery_job "runtime_partition:source_account_discovery"
  @discovery_reason_job "runtime_partition:source_account_discovery_reason"
  @discovery_finalize_job "runtime_partition:source_account_discovery_finalize"
  @closure_job "runtime_partition:source_account_closure_acquire"
  @closure_reason_job "runtime_partition:source_account_closure_reason"
  @closure_finalize_job "runtime_partition:source_account_closure_finalize"

  @doc "Proves an exact Slack source and completion replay for every connected workspace."
  def run(user_id, lower, upper)
      when is_binary(user_id) and is_integer(lower) and is_integer(upper) do
    deadline = System.monotonic_time(:millisecond) + @run_timeout_ms

    with {:ok, accounts} <- slack_accounts(user_id) do
      SourceAccountAdmission.with_reservations(
        Enum.map(accounts, & &1.id),
        deadline,
        fn -> run_reserved(accounts, lower, upper, deadline) end
      )
    end
  rescue
    error in [Postgrex.Error, DBConnection.ConnectionError] ->
      {:error, {:database_error, database_error_code(error)}}

    error ->
      {:error, {:audit_exception, error.__struct__}}
  catch
    kind, _reason -> {:error, {:audit_exit, kind}}
  end

  def run(_user_id, _lower, _upper), do: {:error, :invalid_slack_source_replay_audit}

  def error_code({:database_error, code}) when is_atom(code),
    do: "database_error_" <> Atom.to_string(code)

  def error_code({:database_error, code}) when is_binary(code), do: "database_error_" <> code
  def error_code(reason) when is_atom(reason), do: Atom.to_string(reason)
  def error_code({code, _detail}) when is_atom(code), do: Atom.to_string(code)
  def error_code({reason, _context}), do: error_code(reason)
  def error_code(_reason), do: "slack_source_replay_audit_failed"

  defp run_reserved(accounts, lower, upper, deadline) do
    with {:ok, replays} <- build_replays(accounts, lower, upper),
         {:ok, before_manifests} <- provider_manifests(replays, deadline),
         :ok <- before_deadline(deadline, :slack_source_replay_enqueue_timeout),
         {:ok, enqueue_results} <- enqueue_replays(replays, lower, upper, deadline),
         {:ok, verifications} <- await_replays(replays, lower, upper, deadline),
         {:ok, after_manifests} <- provider_manifests(replays, deadline),
         {:ok, reports} <-
           verify_accounts(replays, before_manifests, after_manifests, verifications) do
      {:ok,
       %{
         lower: lower,
         upper: upper,
         account_count: length(accounts),
         enqueue_outcomes: Enum.frequencies(Enum.map(enqueue_results, & &1.outcome)),
         accounts: reports
       }}
    end
  end

  defp slack_accounts(user_id) do
    accounts =
      ConnectedAccount
      |> where(
        [account],
        account.user_id == ^user_id and account.status == "connected" and
          like(account.provider, "slack:%")
      )
      |> Repo.all()
      |> Enum.filter(&slack_workspace_account?/1)
      |> Enum.sort_by(& &1.id)

    connected_teams = accounts |> Enum.map(&slack_team_id/1) |> MapSet.new()

    scoped_teams =
      user_id |> SourceScope.resolve() |> SourceScope.slack_team_ids() |> MapSet.new()

    cond do
      accounts == [] ->
        {:error, :slack_account_denominator_empty}

      not MapSet.equal?(connected_teams, scoped_teams) ->
        {:error, :slack_source_scope_account_mismatch}

      true ->
        {:ok, accounts}
    end
  end

  defp slack_workspace_account?(%ConnectedAccount{provider: "slack:" <> team_id}) do
    team_id != "" and not String.contains?(team_id, ":user:")
  end

  defp slack_workspace_account?(_account), do: false

  defp slack_team_id(%ConnectedAccount{provider: "slack:" <> team_id}), do: team_id

  defp build_replays(accounts, lower, upper) do
    Enum.reduce_while(accounts, {:ok, []}, fn account, {:ok, entries} ->
      case SlackSourceReplay.build(account, lower, upper) do
        {:ok, replay} -> {:cont, {:ok, entries ++ [%{account: account, replay: replay}]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp provider_manifests(replays, deadline) do
    timeout = deadline - System.monotonic_time(:millisecond) - @deadline_cleanup_reserve_ms

    if timeout <= 0 do
      {:error, :slack_provider_manifest_timeout}
    else
      task =
        Task.Supervisor.async_nolink(Maraithon.Runtime.ToolCallSupervisor, fn ->
          Enum.reduce_while(replays, {:ok, %{}}, fn entry, {:ok, manifests} ->
            case provider_manifest(entry.account, entry.replay) do
              {:ok, manifest} -> {:cont, {:ok, Map.put(manifests, entry.account.id, manifest)}}
              {:error, reason} -> {:halt, {:error, {reason, entry.account.id}}}
            end
          end)
        end)

      case Task.yield(task, timeout) do
        {:ok, result} ->
          result

        {:exit, _reason} ->
          {:error, :slack_provider_manifest_task_failed}

        nil ->
          _ = Task.shutdown(task, :brutal_kill)
          {:error, :slack_provider_manifest_timeout}
      end
    end
  end

  defp provider_manifest(account, replay) do
    source_scope = SourceScope.for_account(account)

    context = %{
      user_id: account.user_id,
      timestamp: DateTime.from_unix!(replay.upper),
      trigger: %{type: :wakeup, job_type: "slack_source_replay_audit"},
      event: nil,
      recent_events: [],
      source_scope: source_scope,
      source_watermark_role: "discovery",
      source_watermark_kind_override: replay.discovery_kind,
      source_replay_window: %{lower: replay.lower, upper: replay.upper},
      defer_watermark_advance: true,
      exhaustive_account_delta: true,
      account_delta_source: "slack"
    }

    {bundle, telemetry, _watermarks} =
      Acquisition.build(
        account.user_id,
        ["followthrough"],
        %{"followthrough" => %{"source_scope" => source_scope, "lookback_hours" => 48}},
        context
      )

    if Acquisition.source_complete?(telemetry, "slack") do
      messages = SourceBundle.slack_messages(bundle)

      channels =
        SourceBundle.slack_workspaces(bundle) |> Enum.flat_map(&Map.get(&1, "channels", []))

      refs = SourceAccountDiscovery.source_item_refs(bundle)

      {:ok,
       %{
         ref_digests: refs |> Enum.map(&SourceCycleProofs.reference_digest/1) |> MapSet.new(),
         item_count: length(refs),
         public_channels: Enum.count(channels, &(conversation_kind(&1) == "public_channel")),
         private_channels: Enum.count(channels, &(conversation_kind(&1) == "private_channel")),
         direct_messages: Enum.count(channels, &(conversation_kind(&1) == "dm")),
         group_direct_messages: Enum.count(channels, &(conversation_kind(&1) == "group_dm")),
         thread_replies: Enum.count(messages, &thread_reply?/1)
       }}
    else
      {:error, :slack_provider_manifest_incomplete}
    end
  rescue
    error -> {:error, {:slack_provider_manifest_exception, error.__struct__}}
  catch
    kind, _reason -> {:error, {:slack_provider_manifest_exit, kind}}
  end

  defp conversation_kind(%{"is_im" => true}), do: "dm"
  defp conversation_kind(%{"is_mpim" => true}), do: "group_dm"
  defp conversation_kind(%{"is_private" => true}), do: "private_channel"
  defp conversation_kind(_channel), do: "public_channel"

  defp thread_reply?(message) when is_map(message) do
    is_binary(message["thread_ts"]) and message["thread_ts"] != message["ts"]
  end

  defp thread_reply?(_message), do: false

  defp enqueue_replays(replays, lower, upper, deadline) do
    {results, waiting, error} =
      Enum.reduce(replays, {[], [], nil}, fn entry, {results, waiting, error} ->
        if error do
          {results, waiting, error}
        else
          case PeriodicJobs.enqueue_slack_source_replay(entry.account.id, lower, upper) do
            {:ok, result} ->
              outcome = Map.get(result, :outcome, Map.get(result, "outcome", "enqueued"))
              {[%{account_id: entry.account.id, outcome: outcome} | results], waiting, nil}

            {:error, :source_account_cycle_active} ->
              {results, [entry | waiting], nil}

            {:error, reason} ->
              {results, waiting, {reason, entry.account.id}}
          end
        end
      end)

    cond do
      error ->
        {:error, error}

      waiting == [] ->
        {:ok, Enum.reverse(results)}

      System.monotonic_time(:millisecond) >= deadline ->
        {:error, {:slack_source_replay_enqueue_timeout, Enum.map(waiting, & &1.account.id)}}

      true ->
        Process.sleep(@poll_interval_ms)

        with {:ok, resumed} <- enqueue_replays(Enum.reverse(waiting), lower, upper, deadline) do
          {:ok, results ++ resumed}
        end
    end
  end

  defp await_replays(replays, lower, upper, deadline) do
    verifications =
      Map.new(replays, fn %{account: account} ->
        {account.id, SlackSourceReplay.verify(account.id, lower, upper)}
      end)

    cond do
      Enum.all?(verifications, fn {_id, result} -> match?({:ok, _}, result) end) ->
        {:ok, Map.new(verifications, fn {id, {:ok, result}} -> {id, result} end)}

      System.monotonic_time(:millisecond) >= deadline ->
        {:error,
         {:slack_source_replay_completion_timeout,
          Map.new(verifications, fn {id, result} -> {id, verification_error(result)} end)}}

      true ->
        Process.sleep(@poll_interval_ms)
        await_replays(replays, lower, upper, deadline)
    end
  end

  defp verification_error({:error, reason}), do: error_code(reason)
  defp verification_error(_result), do: "verification_incomplete"

  defp verify_accounts(replays, before_manifests, after_manifests, verifications) do
    Enum.reduce_while(replays, {:ok, []}, fn %{account: account, replay: replay},
                                             {:ok, reports} ->
      verification = Map.fetch!(verifications, account.id)
      before_manifest = Map.fetch!(before_manifests, account.id)
      after_manifest = Map.fetch!(after_manifests, account.id)

      case verify_account(account, replay, before_manifest, after_manifest, verification) do
        {:ok, report} -> {:cont, {:ok, reports ++ [report]}}
        {:error, reason} -> {:halt, {:error, {reason, account.id}}}
      end
    end)
  end

  defp verify_account(account, replay, before_manifest, after_manifest, verification) do
    discovery_cycle = Repo.get!(SourceCycle, verification.discovery_cycle_id)
    closure_cycle = Repo.get!(SourceCycle, verification.closure_cycle_id)
    discovery_refs = cycle_ref_digests(discovery_cycle.id)
    closure_refs = cycle_ref_digests(closure_cycle.id)

    with :ok <-
           equal_manifest(
             before_manifest.ref_digests,
             after_manifest.ref_digests,
             :provider_changed
           ),
         :ok <-
           equal_manifest(
             after_manifest.ref_digests,
             discovery_refs,
             :discovery_manifest_mismatch
           ),
         :ok <-
           equal_manifest(after_manifest.ref_digests, closure_refs, :closure_manifest_mismatch),
         {:ok, activity} <-
           replay_activity(account.user_id, replay, discovery_cycle, closure_cycle) do
      {:ok,
       %{
         account_id: account.id,
         provider_family: "slack",
         account_fingerprint: account_fingerprint(account.provider),
         source_replay_reference: replay.reference,
         provider_items: after_manifest.item_count,
         public_channels: after_manifest.public_channels,
         private_channels: after_manifest.private_channels,
         direct_messages: after_manifest.direct_messages,
         group_direct_messages: after_manifest.group_direct_messages,
         thread_replies: after_manifest.thread_replies,
         provider_manifest_equal: true,
         discovery_decisions: verification.discovery_counts.source_decisions,
         completion_snapshots: verification.closure_counts.todo_snapshots,
         completion_receipts: verification.closure_counts.todo_closures,
         activity_expected: activity.expected,
         activity_visible: activity.visible,
         activity_job_types: activity.job_types,
         activity_failed_attempts: activity.failed_attempts,
         model_calls: activity.model_calls
       }}
    end
  end

  defp equal_manifest(expected, actual, error) do
    if MapSet.equal?(expected, actual), do: :ok, else: {:error, error}
  end

  defp cycle_ref_digests(cycle_id) do
    SourceCycleItem
    |> where([item], item.cycle_id == ^cycle_id)
    |> select([item], item.source_ref_digest)
    |> Repo.all()
    |> MapSet.new()
  end

  defp replay_activity(user_id, replay, discovery_cycle, closure_cycle) do
    expected_ids =
      (cycle_job_ids(discovery_cycle) ++ cycle_job_ids(closure_cycle)) |> MapSet.new()

    jobs = BackgroundJobs.list_source_account_runs_by_ids(user_id, MapSet.to_list(expected_ids))
    actual_ids = jobs |> Enum.map(& &1.id) |> MapSet.new()
    expected_types = expected_activity_types(discovery_cycle, closure_cycle)
    actual_types = jobs |> Enum.map(& &1.job_type) |> MapSet.new()

    cond do
      not MapSet.equal?(expected_ids, actual_ids) ->
        {:error, :slack_source_replay_activity_manifest_mismatch}

      not MapSet.subset?(expected_types, actual_types) ->
        {:error, :slack_source_replay_activity_stage_missing}

      Enum.any?(jobs, &(replay_reference(&1.result) != replay.reference)) ->
        {:error, :slack_source_replay_activity_reference_mismatch}

      Enum.any?(jobs, &(&1.status != "completed")) ->
        {:error, :slack_source_replay_activity_not_terminal}

      true ->
        {:ok,
         %{
           expected: MapSet.size(expected_ids),
           visible: length(jobs),
           job_types: actual_types |> MapSet.to_list() |> Enum.sort(),
           failed_attempts: Enum.sum(Enum.map(jobs, &max(&1.attempts || 0, 0))),
           model_calls: Enum.sum(Enum.map(jobs, &result_count(&1.result, "model_calls")))
         }}
    end
  end

  defp expected_activity_types(discovery_cycle, closure_cycle) do
    [@discovery_job, @closure_job]
    |> maybe_add_fanout_types(
      discovery_cycle.reason_job_ids != [],
      @discovery_reason_job,
      @discovery_finalize_job
    )
    |> maybe_add_fanout_types(
      closure_cycle.reason_job_ids != [],
      @closure_reason_job,
      @closure_finalize_job
    )
    |> MapSet.new()
  end

  defp maybe_add_fanout_types(types, true, reason_type, finalize_type),
    do: types ++ [reason_type, finalize_type]

  defp maybe_add_fanout_types(types, false, _reason_type, _finalize_type), do: types

  defp cycle_job_ids(cycle),
    do: [cycle.acquisition_job_id] ++ cycle.reason_job_ids ++ List.wrap(cycle.finalizer_job_id)

  defp replay_reference(result) when is_map(result),
    do: Map.get(result, "source_replay_reference", Map.get(result, :source_replay_reference))

  defp replay_reference(_result), do: nil

  defp result_count(result, key) when is_map(result) do
    case Map.get(result, key) do
      value when is_integer(value) and value >= 0 -> value
      _other -> 0
    end
  end

  defp result_count(_result, _key), do: 0

  defp before_deadline(deadline, error) do
    if System.monotonic_time(:millisecond) < deadline, do: :ok, else: {:error, error}
  end

  defp account_fingerprint(provider) do
    provider
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
    |> String.slice(0, 12)
  end

  defp database_error_code(%Postgrex.Error{postgres: %{code: code}}), do: to_string(code)
  defp database_error_code(%DBConnection.ConnectionError{}), do: "connection_error"
end
