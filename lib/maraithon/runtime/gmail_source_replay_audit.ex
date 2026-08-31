defmodule Maraithon.Runtime.GmailSourceReplayAudit do
  @moduledoc false

  import Ecto.Query

  alias Maraithon.Accounts.ConnectedAccount
  alias Maraithon.ChiefOfStaff.SourceScope
  alias Maraithon.Connectors.Gmail
  alias Maraithon.Repo
  alias Maraithon.Runtime.BackgroundJobs
  alias Maraithon.Runtime.GmailSourceReplay
  alias Maraithon.Runtime.PeriodicJobs
  alias Maraithon.Runtime.SourceAccountAdmission
  alias Maraithon.Runtime.SourceCycle
  alias Maraithon.Runtime.SourceCycleItem

  @provider_manifest_limit 501
  @replay_item_limit 250
  @legacy_provider_ref_limit 100_000
  @run_timeout_ms 720_000
  @deadline_cleanup_reserve_ms 15_000
  @poll_interval_ms 2_000

  @discovery_job "runtime_partition:source_account_discovery"
  @discovery_reason_job "runtime_partition:source_account_discovery_reason"
  @discovery_finalize_job "runtime_partition:source_account_discovery_finalize"
  @closure_job "runtime_partition:source_account_closure_acquire"
  @closure_reason_job "runtime_partition:source_account_closure_reason"
  @closure_finalize_job "runtime_partition:source_account_closure_finalize"

  def run(user_id, lower, upper, expected_account_count)
      when is_binary(user_id) and is_integer(lower) and is_integer(upper) and
             is_integer(expected_account_count) and expected_account_count > 0 do
    deadline = System.monotonic_time(:millisecond) + @run_timeout_ms

    with {:ok, accounts} <- gmail_accounts(user_id, expected_account_count) do
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

  def run(_user_id, _lower, _upper, _expected_account_count),
    do: {:error, :invalid_gmail_source_replay_audit}

  defp run_reserved(accounts, lower, upper, deadline) do
    with {:ok, replays} <- build_replays(accounts, lower, upper),
         {:ok, before_manifests} <-
           bounded_provider_manifests(
             accounts,
             lower,
             upper,
             deadline,
             :gmail_source_replay_before_manifest_timeout
           ),
         :ok <- before_deadline(deadline, :gmail_source_replay_enqueue_timeout),
         {:ok, enqueue_results} <- enqueue_replays(replays, lower, upper, deadline),
         {:ok, local_verifications} <-
           await_replays(replays, enqueue_results, lower, upper, deadline),
         {:ok, after_manifests} <-
           bounded_provider_manifests(
             accounts,
             lower,
             upper,
             deadline,
             :gmail_source_replay_after_manifest_timeout
           ),
         {:ok, account_reports} <-
           verify_accounts(
             replays,
             before_manifests,
             after_manifests,
             local_verifications
           ) do
      {:ok,
       %{
         lower: lower,
         upper: upper,
         account_count: length(accounts),
         configured_provider_reference_ceiling_before: @legacy_provider_ref_limit,
         configured_provider_reference_ceiling_after: @replay_item_limit,
         configured_provider_ceiling_reduction_factor:
           div(@legacy_provider_ref_limit, @replay_item_limit),
         enqueue_outcomes: Enum.frequencies(Enum.map(enqueue_results, & &1.outcome)),
         accounts: account_reports
       }}
    end
  end

  def error_code({:database_error, code}) when is_atom(code),
    do: "database_error_" <> Atom.to_string(code)

  def error_code({:database_error, code}) when is_binary(code),
    do: "database_error_" <> code

  def error_code(reason) when is_atom(reason), do: Atom.to_string(reason)
  def error_code({code, _detail}) when is_atom(code), do: Atom.to_string(code)
  def error_code({reason, _context}), do: error_code(reason)
  def error_code(_reason), do: "gmail_source_replay_audit_failed"

  @doc false
  def closure_fanout_efficiency(0, 0) do
    {:ok,
     %{
       applicable: false,
       strictly_improved: false,
       reduction_percent: nil
     }}
  end

  def closure_fanout_efficiency(legacy_count, actual_count)
      when is_integer(legacy_count) and legacy_count > 0 and is_integer(actual_count) and
             actual_count >= 0 and actual_count < legacy_count do
    {:ok,
     %{
       applicable: true,
       strictly_improved: true,
       reduction_percent: reduction_percent(legacy_count, actual_count)
     }}
  end

  def closure_fanout_efficiency(_legacy_count, _actual_count),
    do: {:error, :gmail_source_replay_not_more_efficient}

  defp gmail_accounts(user_id, expected_account_count) do
    accounts =
      ConnectedAccount
      |> where(
        [account],
        account.user_id == ^user_id and account.status == "connected" and
          (account.provider == "google" or like(account.provider, "google:%"))
      )
      |> Repo.all()
      |> Enum.sort_by(& &1.id)

    scoped_provider_ids =
      user_id
      |> SourceScope.resolve()
      |> SourceScope.google_account_providers("gmail")
      |> MapSet.new()

    direct_provider_ids = accounts |> Enum.map(& &1.provider) |> MapSet.new()

    cond do
      length(accounts) != expected_account_count ->
        {:error, :gmail_account_denominator_mismatch}

      not MapSet.equal?(direct_provider_ids, scoped_provider_ids) ->
        {:error, :gmail_source_scope_account_mismatch}

      true ->
        {:ok, accounts}
    end
  end

  defp build_replays(accounts, lower, upper) do
    accounts
    |> Enum.reduce_while({:ok, []}, fn account, {:ok, replays} ->
      case GmailSourceReplay.build(account, lower, upper) do
        {:ok, replay} -> {:cont, {:ok, replays ++ [%{account: account, replay: replay}]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp provider_manifests(accounts, lower, upper) do
    accounts
    |> Enum.reduce_while({:ok, %{}}, fn account, {:ok, manifests} ->
      case provider_manifest(account, lower, upper) do
        {:ok, manifest} -> {:cont, {:ok, Map.put(manifests, account.id, manifest)}}
        {:error, reason} -> {:halt, {:error, {reason, account.id}}}
      end
    end)
  end

  defp bounded_provider_manifests(accounts, lower, upper, deadline, timeout_error) do
    timeout =
      deadline - System.monotonic_time(:millisecond) - @deadline_cleanup_reserve_ms

    if timeout > 0 do
      task =
        Task.Supervisor.async_nolink(Maraithon.Runtime.ToolCallSupervisor, fn ->
          provider_manifests(accounts, lower, upper)
        end)

      case Task.yield(task, timeout) do
        {:ok, result} ->
          result

        {:exit, _reason} ->
          {:error, :gmail_provider_manifest_task_failed}

        nil ->
          _ = Task.shutdown(task, :brutal_kill)
          {:error, timeout_error}
      end
    else
      {:error, timeout_error}
    end
  end

  defp provider_manifest(account, lower, upper) do
    query_lower = max(lower - 2, 0)
    query_upper = upper + 2

    case Gmail.fetch_messages(
           account.user_id,
           provider: account.provider,
           query: "after:#{query_lower} before:#{query_upper}",
           label_ids: [],
           paginate: true,
           max_results: @provider_manifest_limit,
           max_total_results: @provider_manifest_limit,
           message_format: :metadata,
           message_fetch_concurrency: 8,
           message_fetch_timeout_ms: 15_000,
           include_fetch_metadata: true
         ) do
      {:ok, messages, metadata} when is_list(messages) and is_map(metadata) ->
        exact_messages = Enum.filter(messages, &inside_window?(&1, lower, upper))

        cond do
          not Map.get(metadata, :complete?, false) ->
            {:error, :gmail_provider_manifest_incomplete}

          Map.get(metadata, :truncated?, false) ->
            {:error, :gmail_provider_manifest_truncated}

          length(exact_messages) > @replay_item_limit ->
            {:error, :gmail_replay_window_requires_subdivision}

          Enum.any?(exact_messages, &(not valid_message_id?(&1))) ->
            {:error, :gmail_provider_manifest_identity_missing}

          true ->
            by_digest =
              Map.new(exact_messages, fn message ->
                id = message_id(message)
                {identity_digest(account.provider, id), id}
              end)

            {:ok,
             %{
               ids: MapSet.new(Map.values(by_digest)),
               digests: MapSet.new(Map.keys(by_digest)),
               by_digest: by_digest,
               count: map_size(by_digest),
               inbox: Enum.count(exact_messages, &label?(&1, "INBOX")),
               sent: Enum.count(exact_messages, &label?(&1, "SENT")),
               replies: Enum.count(exact_messages, &reply?/1),
               fetch_pages: Map.get(metadata, :page_count, 0),
               detail_failures: Map.get(metadata, :detail_failure_count, 0)
             }}
        end

      {:error, reason} ->
        {:error, {:gmail_provider_manifest_fetch_failed, provider_error_code(reason)}}

      _invalid ->
        {:error, :gmail_provider_manifest_invalid}
    end
  end

  defp before_deadline(deadline, error) do
    if System.monotonic_time(:millisecond) < deadline, do: :ok, else: {:error, error}
  end

  defp enqueue_replays(replays, lower, upper, deadline) do
    do_enqueue_replays(replays, %{}, lower, upper, deadline)
  end

  defp do_enqueue_replays(replays, results, lower, upper, deadline) do
    {results, waiting, error} =
      Enum.reduce(replays, {results, [], nil}, fn %{account: account} = entry,
                                                  {results, waiting, error} ->
        cond do
          not is_nil(error) or Map.has_key?(results, account.id) ->
            {results, waiting, error}

          true ->
            case PeriodicJobs.enqueue_gmail_source_replay(account.id, lower, upper) do
              {:ok, result} ->
                outcome = Map.get(result, :outcome, Map.get(result, "outcome", "enqueued"))

                enqueue_result = %{
                  account_id: account.id,
                  outcome: outcome,
                  discovery_job_id:
                    Map.get(result, :discovery_job_id, Map.get(result, "discovery_job_id")),
                  closure_job_id:
                    Map.get(result, :closure_job_id, Map.get(result, "closure_job_id"))
                }

                {Map.put(results, account.id, enqueue_result), waiting, error}

              {:error, :source_account_cycle_active} ->
                {results, waiting ++ [entry], error}

              {:error, reason} ->
                {results, waiting, {reason, account.id}}
            end
        end
      end)

    cond do
      error ->
        {:error, error}

      waiting == [] ->
        {:ok, results |> Map.values() |> Enum.sort_by(& &1.account_id)}

      System.monotonic_time(:millisecond) >= deadline ->
        {:error, {:gmail_source_replay_enqueue_timeout, Enum.map(waiting, & &1.account.id)}}

      true ->
        Process.sleep(@poll_interval_ms)
        do_enqueue_replays(waiting, results, lower, upper, deadline)
    end
  end

  defp await_replays(replays, enqueue_results, lower, upper, deadline) do
    do_await_replays(replays, enqueue_results, lower, upper, deadline)
  end

  defp do_await_replays(replays, enqueue_results, lower, upper, deadline) do
    verifications =
      Map.new(replays, fn %{account: account} ->
        {account.id, GmailSourceReplay.verify(account.id, lower, upper)}
      end)

    cond do
      Enum.all?(verifications, fn {_account_id, result} -> match?({:ok, _}, result) end) ->
        {:ok, Map.new(verifications, fn {account_id, {:ok, result}} -> {account_id, result} end)}

      failed = failed_replay_jobs(replays, enqueue_results) ->
        {:error, {:gmail_source_replay_job_failed, failed}}

      System.monotonic_time(:millisecond) >= deadline ->
        errors =
          Map.new(verifications, fn
            {account_id, {:error, reason}} -> {account_id, error_code(reason)}
            {account_id, _other} -> {account_id, "verification_incomplete"}
          end)

        {:error, {:gmail_source_replay_completion_timeout, errors}}

      true ->
        Process.sleep(@poll_interval_ms)
        do_await_replays(replays, enqueue_results, lower, upper, deadline)
    end
  end

  defp failed_replay_jobs(replays, enqueue_results) do
    references = MapSet.new(Enum.map(replays, & &1.replay.reference))
    enqueue_results = Map.new(enqueue_results, &{&1.account_id, &1})

    failed =
      replays
      |> hd()
      |> Map.fetch!(:account)
      |> Map.fetch!(:user_id)
      |> BackgroundJobs.list_latest_source_account_runs_for_user(limit: 10_000)
      |> Enum.filter(fn job ->
        replay_reference(job.result) in references and job.status in ["failed", "cancelled"] and
          current_replay_graph_job?(job, Map.get(enqueue_results, job.account_id))
      end)
      |> Enum.map(&%{job_id: &1.id, job_type: &1.job_type, status: &1.status})

    if failed == [], do: nil, else: failed
  end

  defp current_replay_graph_job?(_job, nil), do: false

  defp current_replay_graph_job?(job, enqueue_result) do
    discovery_job_id = enqueue_result.discovery_job_id
    closure_job_id = enqueue_result.closure_job_id

    cond do
      job.id in [discovery_job_id, closure_job_id] ->
        true

      job.job_type in [@discovery_reason_job, @discovery_finalize_job] ->
        dedupe_key_contains_job_id?(job.dedupe_key, discovery_job_id)

      job.job_type in [@closure_reason_job, @closure_finalize_job] ->
        dedupe_key_contains_job_id?(job.dedupe_key, closure_job_id)

      true ->
        false
    end
  end

  defp dedupe_key_contains_job_id?(dedupe_key, job_id)
       when is_binary(dedupe_key) and is_binary(job_id),
       do: String.contains?(dedupe_key, job_id)

  defp dedupe_key_contains_job_id?(_dedupe_key, _job_id), do: false

  defp verify_accounts(replays, before_manifests, after_manifests, local_verifications) do
    with {:ok, reports} <-
           Enum.reduce_while(
             replays,
             {:ok, []},
             fn %{account: account, replay: replay}, {:ok, reports} ->
               before_manifest = Map.fetch!(before_manifests, account.id)
               after_manifest = Map.fetch!(after_manifests, account.id)
               verification = Map.fetch!(local_verifications, account.id)

               case verify_account(
                      account,
                      replay,
                      before_manifest,
                      after_manifest,
                      verification
                    ) do
                 {:ok, report} -> {:cont, {:ok, reports ++ [report]}}
                 {:error, reason} -> {:halt, {:error, {reason, account.id}}}
               end
             end
           ) do
      if Enum.any?(reports, & &1.closure_fanout_strictly_improved),
        do: {:ok, reports},
        else: {:error, :gmail_source_replay_not_more_efficient}
    end
  end

  defp verify_account(account, replay, before_manifest, after_manifest, verification) do
    discovery_cycle = Repo.get!(SourceCycle, verification.discovery_cycle_id)
    closure_cycle = Repo.get!(SourceCycle, verification.closure_cycle_id)
    discovery_digests = cycle_identity_digests(discovery_cycle.id)
    closure_digests = cycle_identity_digests(closure_cycle.id)

    with :ok <-
           equal_manifest(before_manifest.digests, after_manifest.digests, :provider_changed),
         :ok <-
           equal_manifest(after_manifest.digests, discovery_digests, :discovery_manifest_mismatch),
         :ok <-
           equal_manifest(after_manifest.digests, closure_digests, :closure_manifest_mismatch),
         {:ok, activity} <- replay_activity(account.user_id, replay, verification) do
      legacy_closure_jobs =
        ceil_div(after_manifest.count, 5) *
          ceil_div(verification.closure_counts.todo_snapshots, 10)

      actual_closure_jobs = closure_cycle.reason_job_count

      case closure_fanout_efficiency(legacy_closure_jobs, actual_closure_jobs) do
        {:ok, efficiency} ->
          {:ok,
           %{
             account_id: account.id,
             provider_family: "gmail",
             account_fingerprint: account_fingerprint(account.provider),
             source_replay_reference: replay.reference,
             provider_items: after_manifest.count,
             inbox_messages: after_manifest.inbox,
             sent_messages: after_manifest.sent,
             reply_messages: after_manifest.replies,
             provider_fetch_pages: after_manifest.fetch_pages,
             provider_detail_failures: after_manifest.detail_failures,
             provider_manifest_equal: true,
             discovery_decisions: verification.discovery_counts.source_decisions,
             completion_snapshots: verification.closure_counts.todo_snapshots,
             completion_receipts: verification.closure_counts.todo_closures,
             activity_expected: activity.expected,
             activity_visible: activity.visible,
             activity_job_types: activity.job_types,
             activity_failed_attempts: activity.failed_attempts,
             model_calls: activity.model_calls,
             legacy_closure_fanout_jobs: legacy_closure_jobs,
             actual_closure_fanout_jobs: actual_closure_jobs,
             closure_fanout_applicable: efficiency.applicable,
             closure_fanout_strictly_improved: efficiency.strictly_improved,
             closure_fanout_reduction_percent: efficiency.reduction_percent
           }}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp equal_manifest(expected, actual, error) do
    if MapSet.equal?(expected, actual), do: :ok, else: {:error, error}
  end

  defp cycle_identity_digests(cycle_id) do
    SourceCycleItem
    |> where([item], item.cycle_id == ^cycle_id)
    |> select([item], item.source_identity_digest)
    |> Repo.all()
    |> MapSet.new()
  end

  defp replay_activity(user_id, replay, verification) do
    discovery_cycle = Repo.get!(SourceCycle, verification.discovery_cycle_id)
    closure_cycle = Repo.get!(SourceCycle, verification.closure_cycle_id)

    expected_job_ids =
      (cycle_job_ids(discovery_cycle) ++ cycle_job_ids(closure_cycle))
      |> MapSet.new()

    jobs =
      BackgroundJobs.list_source_account_runs_by_ids(
        user_id,
        MapSet.to_list(expected_job_ids)
      )

    expected =
      verification.discovery_counts.expected_jobs + verification.closure_counts.expected_jobs

    expected_types =
      [@discovery_job, @closure_job]
      |> maybe_add_fanout_types(
        verification.discovery_counts.expected_jobs > 1,
        @discovery_reason_job,
        @discovery_finalize_job
      )
      |> maybe_add_fanout_types(
        verification.closure_counts.expected_jobs > 1,
        @closure_reason_job,
        @closure_finalize_job
      )
      |> MapSet.new()

    actual_types = jobs |> Enum.map(& &1.job_type) |> MapSet.new()
    actual_job_ids = jobs |> Enum.map(& &1.id) |> MapSet.new()

    cond do
      length(jobs) != expected ->
        {:error, :gmail_source_replay_activity_count_mismatch}

      not MapSet.equal?(expected_job_ids, actual_job_ids) ->
        {:error, :gmail_source_replay_activity_job_manifest_mismatch}

      Enum.any?(jobs, &(replay_reference(&1.result) != replay.reference)) ->
        {:error, :gmail_source_replay_activity_reference_mismatch}

      not MapSet.subset?(expected_types, actual_types) ->
        {:error, :gmail_source_replay_activity_stage_missing}

      Enum.any?(jobs, &(&1.status != "completed")) ->
        {:error, :gmail_source_replay_activity_not_terminal}

      true ->
        {:ok,
         %{
           expected: expected,
           visible: length(jobs),
           job_types: actual_types |> MapSet.to_list() |> Enum.sort(),
           failed_attempts: Enum.sum(Enum.map(jobs, &max(&1.attempts || 0, 0))),
           model_calls: Enum.sum(Enum.map(jobs, &result_count(&1.result, "model_calls")))
         }}
    end
  end

  defp maybe_add_fanout_types(types, true, reason_type, finalize_type),
    do: types ++ [reason_type, finalize_type]

  defp maybe_add_fanout_types(types, false, _reason_type, _finalize_type), do: types

  defp cycle_job_ids(cycle) do
    [cycle.acquisition_job_id] ++ cycle.reason_job_ids ++ List.wrap(cycle.finalizer_job_id)
  end

  defp replay_reference(result) when is_map(result) do
    Map.get(result, "source_replay_reference", Map.get(result, :source_replay_reference))
  end

  defp replay_reference(_result), do: nil

  defp result_count(result, key) when is_map(result) do
    case Map.get(result, key, Map.get(result, String.to_existing_atom(key))) do
      value when is_integer(value) and value >= 0 -> value
      _other -> 0
    end
  rescue
    ArgumentError -> 0
  end

  defp result_count(_result, _key), do: 0

  defp inside_window?(message, lower, upper) do
    case Map.get(message, :internal_date, Map.get(message, "internal_date")) do
      %DateTime{} = occurred_at ->
        occurred_at = DateTime.to_unix(occurred_at, :second)
        occurred_at >= lower and occurred_at < upper

      _invalid ->
        false
    end
  end

  defp valid_message_id?(message), do: is_binary(message_id(message))

  defp message_id(message) do
    Map.get(message, :message_id, Map.get(message, "message_id"))
  end

  defp identity_digest(provider, message_id) do
    :crypto.hash(:sha256, provider <> ":" <> message_id)
  end

  defp label?(message, label) do
    labels = Map.get(message, :labels, Map.get(message, "labels", []))
    is_list(labels) and label in labels
  end

  defp reply?(message) do
    present_header?(Map.get(message, :references, Map.get(message, "references"))) or
      present_header?(Map.get(message, :in_reply_to, Map.get(message, "in_reply_to")))
  end

  defp present_header?(value) when is_binary(value), do: String.trim(value) != ""
  defp present_header?(_value), do: false

  defp account_fingerprint(provider) do
    provider
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
    |> String.slice(0, 12)
  end

  defp ceil_div(0, _divisor), do: 0
  defp ceil_div(value, divisor), do: div(value + divisor - 1, divisor)

  defp reduction_percent(0, 0), do: 100.0

  defp reduction_percent(before_count, after_count) do
    Float.round((before_count - after_count) * 100 / before_count, 1)
  end

  defp provider_error_code(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp provider_error_code({code, _detail}) when is_atom(code), do: Atom.to_string(code)
  defp provider_error_code(_reason), do: "provider_error"

  defp database_error_code(%Postgrex.Error{postgres: %{code: code}}), do: to_string(code)
  defp database_error_code(%DBConnection.ConnectionError{}), do: "connection_error"
end
