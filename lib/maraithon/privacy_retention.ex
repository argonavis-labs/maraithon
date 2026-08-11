defmodule Maraithon.PrivacyRetention do
  @moduledoc """
  Bounded, PostgreSQL-clock retention for durable payload copies.

  Each built-in handler selects only row IDs and authority metadata, locks a
  finite batch with `FOR UPDATE SKIP LOCKED`, and clears ciphertext/plaintext
  columns with one metadata-only SQL update. Ecto schemas are deliberately not
  loaded, so corrupt ciphertext cannot stop expiry. Eligibility predicates are
  fail-closed: active, requested, outcome-ambiguous, and unacknowledged work is
  never selected.

  The extension registry is a fixed compile-time allowlist. Migration 140002's
  conversation adapter is optional until its schema migration is recorded; it
  becomes activation-required at that point and a missing or malformed adapter
  fails the cycle closed.
  """

  alias Maraithon.Effects.ProtocolCutover
  alias Maraithon.Repo
  alias Maraithon.Runtime.DatabaseClock

  require Logger

  @default_batch_size 100
  @max_batch_size 500
  @default_per_tenant 5
  @max_per_tenant 50

  @window_specs %{
    effects_days: %{default: 30, min: 7, max: 365},
    directives_days: %{default: 30, min: 7, max: 365},
    events_days: %{default: 90, min: 30, max: 365},
    run_steps_days: %{default: 30, min: 7, max: 365},
    agent_runs_days: %{default: 30, min: 7, max: 365},
    assistant_runs_days: %{default: 30, min: 7, max: 365},
    assistant_steps_days: %{default: 30, min: 7, max: 365},
    prepared_actions_days: %{default: 30, min: 7, max: 365},
    operator_events_days: %{default: 90, min: 30, max: 365},
    background_jobs_days: %{default: 30, min: 7, max: 365},
    scheduled_jobs_days: %{default: 30, min: 7, max: 365},
    ingress_receipts_days: %{default: 90, min: 30, max: 365},
    work_results_days: %{default: 30, min: 7, max: 365},
    conversation_days: %{default: 90, min: 30, max: 365},
    snapshot_quarantine_days: %{default: 30, min: 1, max: 30},
    erasure_receipts_days: %{default: 365, min: 30, max: 730}
  }

  @builtin_handlers [
    %{name: :effects, window: :effects_days},
    %{name: :directives, window: :directives_days},
    %{name: :events, window: :events_days},
    %{name: :run_steps, window: :run_steps_days},
    %{name: :agent_runs, window: :agent_runs_days},
    %{name: :assistant_runs, window: :assistant_runs_days},
    %{name: :assistant_steps, window: :assistant_steps_days},
    %{name: :prepared_actions, window: :prepared_actions_days},
    %{name: :operator_events, window: :operator_events_days},
    %{name: :background_jobs, window: :background_jobs_days},
    %{name: :scheduled_jobs, window: :scheduled_jobs_days},
    %{name: :ingress_receipts, window: :ingress_receipts_days},
    %{name: :work_results, window: :work_results_days},
    %{name: :snapshot_quarantines, window: :snapshot_quarantine_days},
    %{name: :erasure_receipts, window: :erasure_receipts_days}
  ]

  @extension_handlers [
    %{
      name: :telegram_conversations,
      window: :conversation_days,
      migration: 20_260_810_140_002,
      module: Maraithon.TelegramConversations.Privacy,
      purge: :purge_retention_batch,
      backlog: :retention_backlog
    }
  ]

  # Exhaustive compile-time registry for every encrypted durable source added
  # by migrations 140001/140002/140005. Current memory copies are erasure-only;
  # every terminal/history source names its bounded retention handler.
  @encrypted_sources [
    %{table: "effects", tenant: :agent, retention_handler: :effects, marker: :payload_purged_at},
    %{
      table: "agent_directives",
      tenant: :user,
      retention_handler: :directives,
      marker: :payload_purged_at
    },
    %{table: "events", tenant: :agent, retention_handler: :events, marker: :payload_purged_at},
    %{
      table: "agent_run_steps",
      tenant: :agent,
      retention_handler: :run_steps,
      marker: :payload_purged_at
    },
    %{table: "snapshots", tenant: :agent, retention_handler: nil, marker: nil},
    %{
      table: "telegram_conversation_turns",
      tenant: :conversation,
      retention_handler: :telegram_conversations,
      marker: :content_scrubbed_at
    },
    %{
      table: "telegram_conversations",
      tenant: :user,
      retention_handler: :telegram_conversations,
      marker: :content_scrubbed_at
    },
    %{
      table: "telegram_assistant_runs",
      tenant: :user,
      retention_handler: :assistant_runs,
      marker: :payload_purged_at
    },
    %{
      table: "telegram_assistant_steps",
      tenant: :assistant_run,
      retention_handler: :assistant_steps,
      marker: :payload_purged_at
    },
    %{
      table: "telegram_prepared_actions",
      tenant: :user,
      retention_handler: :prepared_actions,
      marker: :payload_purged_at
    },
    %{
      table: "agent_runs",
      tenant: :user,
      retention_handler: :agent_runs,
      marker: :private_payload_purged_at
    },
    %{
      table: "operator_events",
      tenant: :user,
      retention_handler: :operator_events,
      marker: :payload_purged_at
    },
    %{
      table: "user_memory_profiles",
      tenant: :user,
      retention_handler: nil,
      marker: :content_erased_at
    },
    %{
      table: "operator_memory_summaries",
      tenant: :user,
      retention_handler: nil,
      marker: :content_erased_at
    },
    %{
      table: "background_jobs",
      tenant: :user,
      retention_handler: :background_jobs,
      marker: :payload_purged_at
    },
    %{
      table: "scheduled_jobs",
      tenant: :agent,
      retention_handler: :scheduled_jobs,
      marker: :payload_purged_at
    },
    %{
      table: "runtime_ingress_receipts",
      tenant: :user,
      retention_handler: :ingress_receipts,
      marker: :payload_purged_at
    },
    %{
      table: "agent_work_results",
      tenant: :user,
      retention_handler: :work_results,
      marker: :result_purged_at
    }
  ]

  @expected_encrypted_source_tables ~w(
    effects agent_directives events agent_run_steps snapshots
    telegram_conversation_turns telegram_conversations telegram_assistant_runs
    telegram_assistant_steps telegram_prepared_actions agent_runs operator_events
    user_memory_profiles operator_memory_summaries background_jobs scheduled_jobs
    runtime_ingress_receipts agent_work_results
  )

  unless Enum.sort(Enum.map(@encrypted_sources, & &1.table)) ==
           Enum.sort(@expected_encrypted_source_tables) and
           length(Enum.uniq_by(@encrypted_sources, & &1.table)) ==
             length(@expected_encrypted_source_tables) do
    raise "privacy encrypted-source registry is incomplete or duplicated"
  end

  @allowed_config_keys Map.keys(@window_specs) ++
                         [:batch_size, :per_tenant, :alert_grace_hours, :critical_grace_hours]

  @doc "Returns the fixed retention handler registry without executing adapters."
  def registry, do: @builtin_handlers ++ @extension_handlers

  @doc "Returns exhaustive, content-free metadata for all encrypted durable sources."
  def encrypted_source_registry, do: @encrypted_sources

  @doc "Validates every retention window and worker bound; invalid config never falls back."
  def policy do
    config = Application.get_env(:maraithon, __MODULE__, [])

    with true <- Keyword.keyword?(config),
         [] <- Keyword.keys(config) -- @allowed_config_keys,
         {:ok, windows} <- validate_windows(config),
         {:ok, batch_size} <-
           bounded_integer(config, :batch_size, @default_batch_size, 1, @max_batch_size),
         {:ok, per_tenant} <-
           bounded_integer(config, :per_tenant, @default_per_tenant, 1, @max_per_tenant),
         {:ok, warning_hours} <- bounded_integer(config, :alert_grace_hours, 24, 1, 168),
         {:ok, critical_hours} <- bounded_integer(config, :critical_grace_hours, 168, 24, 720),
         true <- critical_hours >= warning_hours do
      {:ok,
       Map.merge(windows, %{
         batch_size: batch_size,
         per_tenant: per_tenant,
         alert_grace_hours: warning_hours,
         critical_grace_hours: critical_hours
       })}
    else
      false -> {:error, :invalid_privacy_retention_config}
      [_ | _] -> {:error, :unknown_privacy_retention_config}
      {:error, _reason} = error -> error
    end
  end

  @doc "Content-free preflight for policy, extension activation, and legacy quarantine cleanup."
  def preflight do
    with {:ok, policy} <- policy(),
         {:ok, now} <- database_now(),
         {:ok, extension_states} <- extension_states(),
         {:ok, digest_count} <- legacy_snapshot_digest_count(),
         {:ok, orphan_count} <- snapshot_quarantine_orphan_count() do
      {:ok,
       %{
         policy: policy,
         database_now: now,
         handlers: Enum.map(registry(), & &1.name),
         extensions: extension_states,
         legacy_snapshot_payload_digests: digest_count,
         snapshot_quarantine_orphans: orphan_count,
         activation_ready:
           digest_count == 0 and orphan_count == 0 and
             Enum.all?(extension_states, & &1.activation_ready)
       }}
    end
  end

  @doc "Runs one bounded batch for every active fixed handler."
  def run_cycle(opts \\ [])

  def run_cycle(opts) when is_list(opts) do
    with {:ok, policy} <- policy(),
         {:ok, now} <- database_now(),
         {:ok, batch_size} <-
           option_integer(opts, :batch_size, policy.batch_size, 1, @max_batch_size),
         {:ok, per_tenant} <-
           option_integer(opts, :per_tenant, policy.per_tenant, 1, @max_per_tenant) do
      Enum.reduce_while(registry(), {:ok, []}, fn handler, {:ok, results} ->
        case run_handler(handler.name,
               now: now,
               batch_size: batch_size,
               per_tenant: per_tenant,
               policy: policy
             ) do
          {:ok, %{skipped: true} = result} -> {:cont, {:ok, [result | results]}}
          {:ok, result} -> {:cont, {:ok, [result | results]}}
          {:error, reason} -> {:halt, {:error, {handler.name, reason}}}
        end
      end)
      |> case do
        {:ok, results} -> {:ok, %{database_now: now, handlers: Enum.reverse(results)}}
        {:error, _reason} = error -> error
      end
    end
  end

  def run_cycle(_opts), do: {:error, :invalid_privacy_retention_options}

  @doc "Runs one named handler with a cutoff no newer than its configured policy cutoff."
  def run_handler(name, opts \\ [])

  def run_handler(name, opts) when is_atom(name) and is_list(opts) do
    with {:ok, handler} <- fetch_handler(name),
         {:ok, policy} <- Keyword.get(opts, :policy) |> policy_option(),
         {:ok, now} <- Keyword.get(opts, :now) |> now_option(),
         {:ok, limit} <- option_integer(opts, :batch_size, policy.batch_size, 1, @max_batch_size),
         {:ok, per_tenant} <-
           option_integer(opts, :per_tenant, policy.per_tenant, 1, @max_per_tenant),
         {:ok, cutoff} <- retention_cutoff(handler, policy, now, opts) do
      case run_serialized_handler(handler, cutoff, now, policy, limit, per_tenant) do
        {:ok, _result} = success ->
          success

        {:error, reason} = error ->
          _ = record_unstarted_failure(name, reason)
          error
      end
    else
      {:error, reason} = error ->
        _ = record_unstarted_failure(name, reason)
        error
    end
  rescue
    error ->
      reason = {:retention_handler_failed, safe_error_code(error)}
      _ = record_unstarted_failure(name, reason)
      {:error, reason}
  catch
    :exit, reason ->
      failure = {:retention_handler_failed, safe_error_code(reason)}
      _ = record_unstarted_failure(name, failure)
      {:error, failure}
  end

  def run_handler(_name, _opts), do: {:error, :invalid_privacy_retention_options}

  # One transaction-scoped advisory authority serializes manual and scheduled
  # workers for a handler. Successful payload tombstones, cyclic cursor
  # advancement, backlog observation, and status update therefore commit as a
  # unit. Any error rolls the entire unit back; the failure counter is then
  # incremented under the same advisory authority in a fresh transaction.
  defp run_serialized_handler(handler, cutoff, now, policy, limit, per_tenant) do
    case Repo.transaction(fn ->
           acquire_handler_authority!(handler.name)
           {:ok, cursor} = status_cursor(handler.name)

           # This protocol authority is acquired before any source candidate
           # lock. The surrounding transaction retains it through the payload
           # tombstones and durable status/cursor commit.
           ProtocolCutover.require_exact_write!()

           result =
             case Map.get(handler, :module) do
               nil -> run_builtin(handler.name, cutoff, now, cursor, limit, per_tenant)
               _module -> run_extension(handler, cutoff, now, cursor, limit, per_tenant)
             end

           case result do
             {:ok, _result} -> finish_handler(handler, cutoff, now, policy, result)
             {:error, reason} -> Repo.rollback(reason)
           end
         end) do
      {:ok, result} -> result
      {:error, reason} -> {:error, reason}
    end
  end

  defp acquire_handler_authority!(name) do
    lock_name = "maraithon.privacy_retention:" <> Atom.to_string(name)

    Repo.query!(
      "SELECT pg_advisory_xact_lock(hashtextextended($1::text, 0))",
      [lock_name],
      log: false
    )

    :ok
  end

  @doc "Clears legacy snapshot digests and orphan reports in a bounded, locked batch."
  def cleanup_legacy_snapshot_reports(opts \\ []) when is_list(opts) do
    limit = Keyword.get(opts, :batch_size, @default_batch_size)

    if is_integer(limit) and limit in 1..@max_batch_size do
      Repo.transaction(fn ->
        cleared_digests = clear_legacy_snapshot_digests(limit)
        deleted_orphans = delete_snapshot_quarantine_orphans(limit)
        deleted_attestation_orphans = delete_effect_attestation_orphans(limit)

        %{
          cleared_digests: cleared_digests,
          deleted_orphans: deleted_orphans,
          deleted_attestation_orphans: deleted_attestation_orphans
        }
      end)
    else
      {:error, :invalid_privacy_retention_options}
    end
  end

  @doc "Validates legacy cascade constraints only after content-free cleanup proves zero backlog."
  def finalize_constraints do
    with {:ok, 0} <- legacy_snapshot_digest_count(),
         {:ok, 0} <- snapshot_quarantine_orphan_count(),
         {:ok, 0} <- effect_attestation_orphan_count() do
      Repo.transaction(fn ->
        validate_constraint_if_present(
          "snapshot_quarantines",
          "snapshot_quarantines_agent_id_fkey"
        )

        validate_constraint_if_present(
          "effect_termination_attestations",
          "effect_termination_attestations_effect_id_fkey"
        )

        :ok
      end)
    else
      {:ok, _positive} -> {:error, :privacy_constraint_cleanup_required}
      {:error, _reason} = error -> error
    end
  end

  defp run_builtin(name, cutoff, now, cursor, limit, per_tenant) do
    with {:ok, %{purged: purged, tenant_cursor: next_cursor}} <-
           execute_purge(name, cutoff, now, cursor, limit, per_tenant),
         {:ok, backlog} <- builtin_backlog(name, cutoff, now) do
      {:ok,
       %{
         handler: name,
         purged: purged,
         tenant_cursor: next_cursor,
         backlog_count: backlog.count,
         oldest_age_seconds: backlog.oldest_age_seconds,
         intentional_exception_count: backlog.intentional_exception_count
       }}
    end
  end

  defp execute_purge(name, cutoff, now, cursor, limit, per_tenant) do
    with {:ok, sql} <- purge_sql(name),
         {:ok, cutoff_naive} <- naive_utc(cutoff),
         {:ok, now_naive} <- naive_utc(now),
         {:ok, result} <-
           Repo.query(sql, [cutoff_naive, limit, per_tenant, cursor, now_naive],
             log: false,
             timeout: 30_000
           ) do
      case result.rows do
        [[count, next_cursor]]
        when is_integer(count) and (is_nil(next_cursor) or is_binary(next_cursor)) ->
          {:ok, %{purged: count, tenant_cursor: next_cursor}}

        _invalid ->
          {:error, :invalid_privacy_retention_result}
      end
    end
  end

  defp builtin_backlog(:directives, cutoff, now) do
    with {:ok, purgeable} <- query_builtin_backlog(:directives, cutoff, now),
         {:ok, cutoff_naive} <- naive_utc(cutoff),
         {:ok, now_naive} <- naive_utc(now),
         {:ok, result} <-
           Repo.query(
             """
             SELECT count(*)::bigint,
                    COALESCE(EXTRACT(EPOCH FROM ($2::timestamp -
                      min(terminal_acknowledged_at)))::bigint, 0)
             FROM agent_directives
             WHERE payload_purged_at IS NULL
               AND status = 'cancelled'
               AND terminal_acknowledged_at IS NOT NULL
               AND terminal_acknowledged_at <= $1::timestamp
               AND ambiguity_code IS NULL
               AND active_run_id IS NULL
             """,
             [cutoff_naive, now_naive],
             log: false
           ) do
      case result.rows do
        [[exceptions, oldest_exception]]
        when is_integer(exceptions) and is_integer(oldest_exception) ->
          {:ok,
           %{
             count: purgeable.count + exceptions,
             oldest_age_seconds: max(purgeable.oldest_age_seconds, oldest_exception),
             intentional_exception_count: exceptions
           }}

        _invalid ->
          {:error, :invalid_privacy_retention_backlog}
      end
    end
  end

  defp builtin_backlog(name, cutoff, now), do: query_builtin_backlog(name, cutoff, now)

  defp query_builtin_backlog(name, cutoff, now) do
    with {:ok, sql} <- backlog_sql(name),
         {:ok, cutoff_naive} <- naive_utc(cutoff),
         {:ok, now_naive} <- naive_utc(now),
         {:ok, result} <- Repo.query(sql, [cutoff_naive, now_naive], log: false) do
      case result.rows do
        [[count, oldest]] when is_integer(count) and is_integer(oldest) ->
          {:ok, %{count: count, oldest_age_seconds: oldest, intentional_exception_count: 0}}

        _invalid ->
          {:error, :invalid_privacy_retention_backlog}
      end
    end
  end

  defp run_extension(handler, cutoff, now, cursor, limit, per_tenant) do
    with {:ok, active?} <- migration_recorded?(handler.migration) do
      if active? do
        module = handler.module

        if adapter_available?(handler) do
          adapter_opts = [
            limit: limit,
            per_tenant: per_tenant,
            now: now,
            families: [:turns, :conversations]
          ]

          with :ok <- mark_extension_retention(handler.name, cutoff),
               {:ok, purge} <-
                 apply(module, handler.purge, [cutoff, cursor, adapter_opts]),
               {:ok, backlog} <-
                 apply(module, handler.backlog, [cutoff, cursor, adapter_opts]),
               {:ok, result} <- validate_extension_result(handler.name, purge, backlog, cursor) do
            {:ok, result}
          end
        else
          {:error, :required_privacy_retention_adapter_unavailable}
        end
      else
        {:ok,
         %{
           handler: handler.name,
           skipped: true,
           reason: :migration_not_recorded,
           purged: 0,
           backlog_count: 0,
           oldest_age_seconds: 0,
           intentional_exception_count: 0,
           tenant_cursor: cursor
         }}
      end
    end
  end

  defp mark_extension_retention(:telegram_conversations, cutoff) do
    with {:ok, cutoff} <- naive_utc(cutoff),
         {:ok, _result} <-
           Repo.query(
             """
             SELECT set_config(
                      'maraithon.privacy_retention_table',
                      'telegram_conversations', true
                    ),
                    set_config(
                      'maraithon.privacy_retention_cutoff',
                      ($1::timestamp)::text, true
                    )
             """,
             [cutoff],
             log: false
           ) do
      :ok
    end
  end

  defp mark_extension_retention(_handler, _cutoff),
    do: {:error, :unknown_privacy_retention_handler}

  defp validate_extension_result(name, purge, backlog, old_cursor)
       when is_map(purge) and is_map(backlog) do
    purged = Map.get(purge, :purged)
    cursor = Map.get(purge, :tenant_cursor, old_cursor)
    count = Map.get(backlog, :count)
    oldest = Map.get(backlog, :oldest_age_seconds)

    if is_integer(purged) and purged >= 0 and is_integer(count) and count >= 0 and
         is_integer(oldest) and oldest >= 0 and (is_nil(cursor) or is_binary(cursor)) do
      {:ok,
       %{
         handler: name,
         purged: purged,
         backlog_count: count,
         oldest_age_seconds: oldest,
         intentional_exception_count: 0,
         tenant_cursor: cursor
       }}
    else
      {:error, :invalid_privacy_retention_adapter_result}
    end
  end

  defp validate_extension_result(_name, _purge, _backlog, _cursor),
    do: {:error, :invalid_privacy_retention_adapter_result}

  defp finish_handler(handler, cutoff, started_at, policy, {:ok, result}) do
    finished_at = DatabaseClock.now!()
    alert = alert_state(result, handler, cutoff, policy, 0)

    :ok =
      upsert_status(handler.name, %{
        tenant_cursor: result.tenant_cursor,
        backlog_count: result.backlog_count,
        oldest_age_seconds: result.oldest_age_seconds,
        consecutive_failures: 0,
        alert_state: alert,
        last_error_code: nil,
        last_started_at: started_at,
        last_finished_at: finished_at,
        last_succeeded_at: finished_at
      })

    emit_metrics(handler.name, result, 0, alert)
    maybe_alert(handler.name, result.backlog_count, result.oldest_age_seconds, 0, alert)
    {:ok, Map.put(result, :alert_state, alert)}
  end

  defp finish_handler(handler, _cutoff, started_at, _policy, {:error, reason}) do
    finished_at = DatabaseClock.now!()
    failures = status_failures(handler.name) + 1
    code = safe_error_code(reason)
    alert = if failures >= 3, do: "critical", else: "warning"

    :ok =
      upsert_status(handler.name, %{
        consecutive_failures: failures,
        alert_state: alert,
        last_error_code: code,
        last_started_at: started_at,
        last_finished_at: finished_at
      })

    emit_metrics(
      handler.name,
      %{purged: 0, backlog_count: 0, oldest_age_seconds: 0},
      failures,
      alert
    )

    maybe_alert(handler.name, 0, 0, failures, alert)
    {:error, reason}
  end

  defp alert_state(
         %{backlog_count: backlog, oldest_age_seconds: oldest},
         handler,
         _cutoff,
         policy,
         failures
       ) do
    window_seconds = Map.fetch!(policy, handler.window) * 86_400
    warning = window_seconds + policy.alert_grace_hours * 3_600
    critical = window_seconds + policy.critical_grace_hours * 3_600

    cond do
      failures >= 3 or (backlog > 0 and oldest >= critical) -> "critical"
      failures > 0 or (backlog > 0 and oldest >= warning) -> "warning"
      true -> "ok"
    end
  end

  defp emit_metrics(handler, result, failures, alert) do
    :telemetry.execute(
      [:maraithon, :privacy, :retention, :handler],
      %{
        purged: result.purged,
        backlog_count: result.backlog_count,
        oldest_age_seconds: result.oldest_age_seconds,
        intentional_exception_count: Map.get(result, :intentional_exception_count, 0),
        consecutive_failures: failures
      },
      %{handler: handler, alert_state: alert}
    )
  end

  defp maybe_alert(_handler, _backlog, _oldest, _failures, "ok"), do: :ok

  defp maybe_alert(handler, backlog, oldest, failures, level) do
    log = if level == "critical", do: &Logger.error/2, else: &Logger.warning/2

    log.("Privacy retention handler requires attention",
      privacy_handler: handler,
      privacy_alert_state: level,
      privacy_backlog_count: backlog,
      privacy_oldest_age_seconds: oldest,
      privacy_consecutive_failures: failures
    )
  end

  defp purge_sql(:effects) do
    {:ok,
     fair_update_sql(
       """
       SELECT effect.id,
              COALESCE(effect.owner_user_id, agent.user_id, '') AS tenant_key,
              effect.result_acknowledged_at AS eligible_at
       FROM effects AS effect
       LEFT JOIN agents AS agent ON agent.id = effect.agent_id
       WHERE effect.payload_purged_at IS NULL
         AND effect.status IN ('completed', 'failed', 'cancelled')
         AND effect.result_acknowledged_at IS NOT NULL
         AND effect.result_acknowledged_at <= $1
         AND jsonb_typeof(effect.result_envelope) = 'object'
         AND effect.result_envelope ->> 'version' = '1'
         AND effect.result_envelope ->> 'status' IN ('ok', 'error')
         AND (effect.status <> 'cancelled'
              OR effect.runtime_owner_generation IS NULL
              OR effect.cancellation_state = 'settled')
       """,
       "effects",
       "effect",
       """
       params_ciphertext = NULL,
       result_ciphertext = NULL,
       params = '{"redacted": true}'::jsonb,
       result = NULL,
       payload_binding_version = NULL,
       payload_binding_key_tag = NULL,
       payload_binding_mac = NULL,
       payload_purged_at = $5,
       updated_at = $5
       """,
       retention_marker(
         "effects",
         "maraithon.effect_payload_retention",
         "PURGE_ACKNOWLEDGED_PAYLOAD"
       )
     )}
  end

  defp purge_sql(:directives) do
    {:ok,
     fair_update_sql(
       """
       SELECT directive.id, directive.user_id AS tenant_key,
              directive.terminal_acknowledged_at AS eligible_at
       FROM agent_directives AS directive
       WHERE directive.payload_purged_at IS NULL
         AND directive.status IN ('completed', 'dead_letter')
         AND directive.terminal_acknowledged_at IS NOT NULL
         AND directive.terminal_acknowledged_at <= $1
         AND directive.ambiguity_code IS NULL
         AND directive.active_run_id IS NULL
       """,
       "agent_directives",
       "directive",
       """
       payload_ciphertext = NULL,
       payload = '{"redacted": true}'::jsonb,
       payload_binding_version = NULL,
       payload_binding_key_tag = NULL,
       payload_binding_mac = NULL,
       payload_purged_at = $5,
       updated_at = $5
       """,
       retention_marker(
         "agent_directives",
         "maraithon.directive_payload_retention",
         "PURGE_ACKNOWLEDGED_PAYLOAD"
       )
     )}
  end

  defp purge_sql(:events) do
    {:ok,
     fair_update_sql(
       """
       SELECT event.id, COALESCE(agent.user_id, '') AS tenant_key,
              event.inserted_at AS eligible_at
       FROM events AS event
       JOIN agents AS agent ON agent.id = event.agent_id
       WHERE event.payload_purged_at IS NULL
         AND event.inserted_at <= $1
         AND event.spend_total_cost IS NOT NULL
         AND event.spend_input_tokens IS NOT NULL
         AND event.spend_output_tokens IS NOT NULL
         AND event.spend_llm_calls IS NOT NULL
       """,
       "events",
       "event",
       """
       payload_ciphertext = NULL,
       payload = '{}'::jsonb,
       payload_binding_version = NULL,
       payload_binding_key_tag = NULL,
       payload_binding_mac = NULL,
       payload_purged_at = $5
       """,
       retention_marker("events")
     )}
  end

  defp purge_sql(:run_steps) do
    {:ok,
     fair_update_sql(
       """
       SELECT step.id, COALESCE(run.user_id, agent.user_id, '') AS tenant_key,
              step.completed_at AS eligible_at
       FROM agent_run_steps AS step
       JOIN agent_runs AS run
         ON run.id = step.agent_run_id AND run.agent_id = step.agent_id
       JOIN agents AS agent ON agent.id = step.agent_id
       WHERE step.payload_purged_at IS NULL
         AND step.status IN ('completed', 'failed')
         AND step.completed_at IS NOT NULL AND step.completed_at <= $1
         AND run.status IN ('completed', 'failed', 'cancelled')
         AND run.completed_at IS NOT NULL AND run.completed_at <= $1
         AND agent.active_run_id IS DISTINCT FROM run.id
       """,
       "agent_run_steps",
       "step",
       """
       request_payload_ciphertext = NULL,
       response_payload_ciphertext = NULL,
       request_payload = '{}'::jsonb,
       response_payload = '{}'::jsonb,
       payload_binding_version = NULL,
       payload_binding_key_tag = NULL,
       payload_binding_mac = NULL,
       payload_purged_at = $5,
       updated_at = $5
       """,
       retention_marker("agent_run_steps")
     )}
  end

  defp purge_sql(:agent_runs) do
    {:ok,
     fair_update_sql(
       """
       SELECT run.id, COALESCE(run.user_id, agent.user_id, '') AS tenant_key,
              run.completed_at AS eligible_at
       FROM agent_runs AS run
       JOIN agents AS agent ON agent.id = run.agent_id
       WHERE run.private_payload_purged_at IS NULL
         AND run.status IN ('completed', 'failed', 'cancelled')
         AND run.completed_at IS NOT NULL AND run.completed_at <= $1
         AND agent.active_run_id IS DISTINCT FROM run.id
       """,
       "agent_runs",
       "run",
       """
       trigger_ciphertext = NULL,
       metadata_ciphertext = NULL,
       trigger = '{}'::jsonb,
       metadata = '{}'::jsonb,
       budget_snapshot = '{}'::jsonb,
       payload_binding_version = NULL,
       payload_binding_key_tag = NULL,
       payload_binding_mac = NULL,
       private_payload_purged_at = $5,
       updated_at = $5
       """,
       retention_marker("agent_runs")
     )}
  end

  defp purge_sql(:assistant_runs) do
    {:ok,
     fair_update_sql(
       """
       SELECT run.id, run.user_id AS tenant_key, run.finished_at AS eligible_at
       FROM telegram_assistant_runs AS run
       WHERE run.payload_purged_at IS NULL
         AND run.status IN ('completed', 'failed', 'cancelled', 'degraded')
         AND run.finished_at IS NOT NULL AND run.finished_at <= $1
         AND NOT EXISTS (
           SELECT 1 FROM telegram_assistant_steps AS step
           WHERE step.run_id = run.id
             AND (step.finished_at IS NULL OR step.status = 'running')
         )
         AND NOT EXISTS (
           SELECT 1 FROM telegram_prepared_actions AS action
           WHERE action.run_id = run.id
             AND action.status NOT IN ('executed', 'rejected', 'expired', 'failed')
         )
       """,
       "telegram_assistant_runs",
       "run",
       """
       prompt_snapshot_ciphertext = NULL,
       result_summary_ciphertext = NULL,
       prompt_snapshot = '{}'::jsonb,
       result_summary = '{}'::jsonb,
       payload_binding_version = NULL,
       payload_binding_key_tag = NULL,
       payload_binding_mac = NULL,
       error = NULL,
       payload_purged_at = $5,
       updated_at = $5
       """,
       retention_marker("telegram_assistant_runs")
     )}
  end

  defp purge_sql(:assistant_steps) do
    {:ok,
     fair_update_sql(
       """
       SELECT step.id, run.user_id AS tenant_key, step.finished_at AS eligible_at
       FROM telegram_assistant_steps AS step
       JOIN telegram_assistant_runs AS run ON run.id = step.run_id
       WHERE step.payload_purged_at IS NULL
         AND step.status IN ('completed', 'failed', 'skipped')
         AND step.finished_at IS NOT NULL AND step.finished_at <= $1
         AND run.status IN ('completed', 'failed', 'cancelled', 'degraded')
         AND run.finished_at IS NOT NULL AND run.finished_at <= $1
       """,
       "telegram_assistant_steps",
       "step",
       """
       request_payload_ciphertext = NULL,
       response_payload_ciphertext = NULL,
       request_payload = '{}'::jsonb,
       response_payload = '{}'::jsonb,
       payload_binding_version = NULL,
       payload_binding_key_tag = NULL,
       payload_binding_mac = NULL,
       error = NULL,
       payload_purged_at = $5,
       updated_at = $5
       """,
       retention_marker("telegram_assistant_steps")
     )}
  end

  defp purge_sql(:prepared_actions) do
    {:ok,
     fair_update_sql(
       """
       SELECT action.id, action.user_id AS tenant_key, action.updated_at AS eligible_at
       FROM telegram_prepared_actions AS action
       WHERE action.payload_purged_at IS NULL
         AND action.status IN ('executed', 'rejected', 'expired', 'failed')
         AND action.updated_at <= $1
       """,
       "telegram_prepared_actions",
       "action",
       """
       payload_ciphertext = NULL,
       preview_text_ciphertext = NULL,
       payload = '{}'::jsonb,
       preview_text = NULL,
       payload_todo_id = NULL,
       payload_surviving_person_id = NULL,
       payload_merged_person_id = NULL,
       payload_binding_version = NULL,
       payload_binding_key_tag = NULL,
       payload_binding_mac = NULL,
       error = NULL,
       payload_purged_at = $5,
       updated_at = $5
       """,
       retention_marker("telegram_prepared_actions")
     )}
  end

  defp purge_sql(:operator_events) do
    {:ok,
     fair_update_sql(
       """
       SELECT event.id, event.user_id AS tenant_key, event.occurred_at AS eligible_at
       FROM operator_events AS event
       WHERE event.payload_purged_at IS NULL AND event.occurred_at <= $1
       """,
       "operator_events",
       "event",
       """
       payload_ciphertext = NULL,
       metadata_ciphertext = NULL,
       payload = '{}'::jsonb,
       metadata = '{}'::jsonb,
       payload_binding_version = NULL,
       payload_binding_key_tag = NULL,
       payload_binding_mac = NULL,
       payload_purged_at = $5,
       updated_at = $5
       """,
       retention_marker("operator_events")
     )}
  end

  defp purge_sql(:background_jobs) do
    {:ok,
     fair_update_sql(
       """
       SELECT job.id, COALESCE(job.user_id, '') AS tenant_key,
              COALESCE(job.completed_at, job.failed_at, job.cancelled_at) AS eligible_at
       FROM background_jobs AS job
       WHERE job.payload_purged_at IS NULL
         AND job.status IN ('completed', 'failed', 'cancelled')
         AND job.claim_token IS NULL AND job.claimed_at IS NULL
         AND COALESCE(job.completed_at, job.failed_at, job.cancelled_at) IS NOT NULL
         AND COALESCE(job.completed_at, job.failed_at, job.cancelled_at) <= $1
       """,
       "background_jobs",
       "job",
       """
       payload_ciphertext = NULL,
       result_ciphertext = NULL,
       payload = '{}'::jsonb,
       result = '{}'::jsonb,
       payload_binding_version = NULL,
       payload_binding_key_tag = NULL,
       payload_binding_mac = NULL,
       last_error = NULL,
       payload_purged_at = $5,
       updated_at = $5
       """,
       retention_marker("background_jobs")
     )}
  end

  defp purge_sql(:scheduled_jobs) do
    {:ok,
     fair_update_sql(
       """
       SELECT job.id, COALESCE(agent.user_id, '') AS tenant_key,
              COALESCE(job.delivered_at, job.inserted_at) AS eligible_at
       FROM scheduled_jobs AS job
       JOIN agents AS agent ON agent.id = job.agent_id
       WHERE job.payload_purged_at IS NULL
         AND ((job.status = 'delivered' AND job.delivered_at IS NOT NULL)
              OR (job.status = 'cancelled' AND job.dispatched_at IS NULL))
         AND job.claimed_by IS NULL AND job.claimed_at IS NULL
         AND COALESCE(job.delivered_at, job.inserted_at) <= $1
       """,
       "scheduled_jobs",
       "job",
       """
       payload_ciphertext = NULL,
       payload = '{}'::jsonb,
       payload_binding_version = NULL,
       payload_binding_key_tag = NULL,
       payload_binding_mac = NULL,
       payload_purged_at = $5
       """,
       retention_marker("scheduled_jobs")
     )}
  end

  defp purge_sql(:ingress_receipts) do
    {:ok,
     fair_update_sql(
       """
       SELECT receipt.id, receipt.user_id AS tenant_key, receipt.received_at AS eligible_at
       FROM runtime_ingress_receipts AS receipt
       WHERE receipt.payload_purged_at IS NULL
         AND receipt.received_at IS NOT NULL AND receipt.received_at <= $1
       """,
       "runtime_ingress_receipts",
       "receipt",
       """
       payload_ciphertext = NULL,
       payload = '{}'::jsonb,
       payload_binding_version = NULL,
       payload_binding_key_tag = NULL,
       payload_binding_mac = NULL,
       payload_purged_at = $5
       """,
       retention_marker("runtime_ingress_receipts")
     )}
  end

  defp purge_sql(:work_results) do
    {:ok,
     fair_update_sql(
       """
       SELECT result.id, result.user_id AS tenant_key, result.committed_at AS eligible_at
       FROM agent_work_results AS result
       JOIN agent_directives AS directive ON directive.id = result.agent_directive_id
       WHERE result.result_purged_at IS NULL
         AND result.status = 'committed'
         AND result.committed_at IS NOT NULL AND result.committed_at <= $1
         AND result.result_digest_version = 1
         AND result.result_digest IS NOT NULL
         AND octet_length(result.result_digest) = 32
         AND result.result_digest_key_tag IS NOT NULL
         AND directive.status IN ('completed', 'dead_letter')
         AND directive.terminal_acknowledged_at IS NOT NULL
         AND directive.terminal_acknowledged_at <= $1
         AND directive.ambiguity_code IS NULL
         AND directive.active_run_id IS NULL
       """,
       "agent_work_results",
       "result",
       """
       result_ciphertext = NULL,
       result = '{}'::jsonb,
       payload_binding_version = NULL,
       payload_binding_key_tag = NULL,
       payload_binding_mac = NULL,
       result_content_digest = result_digest,
       result_content_digest_version = 0,
       result_digest = NULL,
       result_digest_version = NULL,
       result_digest_key_tag = NULL,
       result_purged_at = $5,
       updated_at = $5
       """,
       retention_marker("agent_work_results")
     )}
  end

  defp purge_sql(:snapshot_quarantines) do
    {:ok,
     fair_delete_sql(
       """
       SELECT report.id, COALESCE(agent.user_id, '') AS tenant_key,
              report.quarantined_at AS eligible_at
       FROM snapshot_quarantines AS report
       JOIN agents AS agent ON agent.id = report.agent_id
       WHERE report.status = 'quarantined'
         AND report.quarantined_at IS NOT NULL
         AND report.quarantined_at <= $1
       """,
       "snapshot_quarantines",
       "report"
     )}
  end

  defp purge_sql(:erasure_receipts) do
    {:ok,
     fair_delete_sql(
       """
       SELECT request.id, request.id::text AS tenant_key,
              request.expires_at AS eligible_at
       FROM privacy_erasure_requests AS request
       WHERE request.state = 'completed'
         AND request.expires_at IS NOT NULL
         AND request.expires_at <= $1
       """,
       "privacy_erasure_requests",
       "request"
     )}
  end

  defp purge_sql(_name), do: {:error, :unknown_privacy_retention_handler}

  defp backlog_sql(name) do
    with {:ok, source} <- backlog_source(name) do
      {:ok,
       """
       WITH eligible AS MATERIALIZED (#{source})
       SELECT count(*)::bigint,
              COALESCE(EXTRACT(EPOCH FROM ($2 - min(eligible_at)))::bigint, 0)
       FROM eligible
       """}
    end
  end

  defp backlog_source(:effects), do: purge_source(:effects)
  defp backlog_source(:directives), do: purge_source(:directives)
  defp backlog_source(:events), do: purge_source(:events)
  defp backlog_source(:run_steps), do: purge_source(:run_steps)
  defp backlog_source(:agent_runs), do: purge_source(:agent_runs)
  defp backlog_source(:assistant_runs), do: purge_source(:assistant_runs)
  defp backlog_source(:assistant_steps), do: purge_source(:assistant_steps)
  defp backlog_source(:prepared_actions), do: purge_source(:prepared_actions)
  defp backlog_source(:operator_events), do: purge_source(:operator_events)
  defp backlog_source(:background_jobs), do: purge_source(:background_jobs)
  defp backlog_source(:scheduled_jobs), do: purge_source(:scheduled_jobs)
  defp backlog_source(:ingress_receipts), do: purge_source(:ingress_receipts)
  defp backlog_source(:work_results), do: purge_source(:work_results)
  defp backlog_source(:snapshot_quarantines), do: purge_source(:snapshot_quarantines)
  defp backlog_source(:erasure_receipts), do: purge_source(:erasure_receipts)
  defp backlog_source(_name), do: {:error, :unknown_privacy_retention_handler}

  # Extract the stable eligible-source query from a generated mutation. Keeping
  # one predicate definition prevents metrics from reporting rows a worker
  # could never actually clear.
  defp purge_source(name) do
    with {:ok, sql} <- purge_sql(name),
         [_, source_and_rest] <- String.split(sql, "ranked AS MATERIALIZED (", parts: 2),
         [source, _rest] <- String.split(source_and_rest, "\n), eligible AS", parts: 2) do
      {:ok, source}
    else
      _invalid -> {:error, :invalid_privacy_retention_sql}
    end
  end

  defp retention_marker(table, key \\ nil, value \\ nil) do
    common =
      "set_config('maraithon.privacy_retention_table', '#{table}', true) AS privacy_table, " <>
        "set_config('maraithon.privacy_retention_cutoff', ($1::timestamp)::text, true) AS privacy_cutoff"

    case {key, value} do
      {nil, nil} -> "SELECT #{common}"
      {key, value} -> "SELECT #{common}, set_config('#{key}', '#{value}', true) AS privacy_action"
    end
  end

  defp fair_update_sql(source, table, alias_name, set_sql, prelude) do
    prelude_sql =
      if prelude, do: "WITH retention_marker AS MATERIALIZED (#{prelude}),", else: "WITH"

    marker_reference = if prelude, do: "CROSS JOIN retention_marker", else: ""

    """
    #{prelude_sql} ranked AS MATERIALIZED (
    #{source}
    ), eligible AS MATERIALIZED (
      SELECT ranked.*,
             row_number() OVER (
               PARTITION BY tenant_key ORDER BY eligible_at, id
             ) AS tenant_rank
      FROM ranked
    ), locked AS MATERIALIZED (
      SELECT #{alias_name}.id, eligible.tenant_key, eligible.tenant_rank,
             eligible.eligible_at,
             CASE
               WHEN $4::text IS NULL OR eligible.tenant_key > $4::text THEN 0
               ELSE 1
             END AS cursor_partition
      FROM #{table} AS #{alias_name}
      JOIN eligible ON eligible.id = #{alias_name}.id
      #{marker_reference}
      WHERE eligible.tenant_rank <= $3
      ORDER BY cursor_partition, eligible.tenant_key,
               eligible.tenant_rank, eligible.eligible_at, eligible.id
      LIMIT $2
      FOR UPDATE OF #{alias_name} SKIP LOCKED
    ), ordered AS MATERIALIZED (
      SELECT locked.*,
             row_number() OVER (
               ORDER BY cursor_partition, tenant_key,
                        tenant_rank, eligible_at, id
             ) AS selection_order
      FROM locked
    ), mutated AS (
      UPDATE #{table} AS #{alias_name}
      SET #{set_sql}
      FROM ordered
      WHERE #{alias_name}.id = ordered.id
      RETURNING #{alias_name}.id
    )
    SELECT count(mutated.id)::bigint,
           COALESCE((
             SELECT ordered.tenant_key
             FROM ordered
             JOIN mutated ON mutated.id = ordered.id
             ORDER BY ordered.selection_order DESC
             LIMIT 1
           ), $4::text)
    FROM mutated
    """
  end

  defp fair_delete_sql(source, table, alias_name) do
    """
    WITH ranked AS MATERIALIZED (
    #{source}
    ), eligible AS MATERIALIZED (
      SELECT ranked.*,
             row_number() OVER (
               PARTITION BY tenant_key ORDER BY eligible_at, id
             ) AS tenant_rank
      FROM ranked
    ), locked AS MATERIALIZED (
      SELECT #{alias_name}.id, eligible.tenant_key, eligible.tenant_rank,
             eligible.eligible_at,
             CASE
               WHEN $4::text IS NULL OR eligible.tenant_key > $4::text THEN 0
               ELSE 1
             END AS cursor_partition
      FROM #{table} AS #{alias_name}
      JOIN eligible ON eligible.id = #{alias_name}.id
      WHERE eligible.tenant_rank <= $3
        AND $5::timestamp IS NOT NULL
      ORDER BY cursor_partition, eligible.tenant_key,
               eligible.tenant_rank, eligible.eligible_at, eligible.id
      LIMIT $2
      FOR UPDATE OF #{alias_name} SKIP LOCKED
    ), ordered AS MATERIALIZED (
      SELECT locked.*,
             row_number() OVER (
               ORDER BY cursor_partition, tenant_key,
                        tenant_rank, eligible_at, id
             ) AS selection_order
      FROM locked
    ), mutated AS (
      DELETE FROM #{table} AS #{alias_name}
      USING ordered
      WHERE #{alias_name}.id = ordered.id
      RETURNING #{alias_name}.id
    )
    SELECT count(mutated.id)::bigint,
           COALESCE((
             SELECT ordered.tenant_key
             FROM ordered
             JOIN mutated ON mutated.id = ordered.id
             ORDER BY ordered.selection_order DESC
             LIMIT 1
           ), $4::text)
    FROM mutated
    """
  end

  defp validate_windows(config) do
    Enum.reduce_while(@window_specs, {:ok, %{}}, fn {key, spec}, {:ok, windows} ->
      value = Keyword.get(config, key, spec.default)

      if is_integer(value) and value in spec.min..spec.max do
        {:cont, {:ok, Map.put(windows, key, value)}}
      else
        {:halt, {:error, {:invalid_privacy_retention_window, key, spec.min, spec.max}}}
      end
    end)
  end

  defp bounded_integer(config, key, default, min, max) do
    value = Keyword.get(config, key, default)

    if is_integer(value) and value in min..max,
      do: {:ok, value},
      else: {:error, :invalid_privacy_retention_config}
  end

  defp option_integer(opts, key, default, min, max) do
    if Keyword.keyword?(opts) do
      value = Keyword.get(opts, key, default)

      if is_integer(value) and value in min..max,
        do: {:ok, value},
        else: {:error, :invalid_privacy_retention_options}
    else
      {:error, :invalid_privacy_retention_options}
    end
  end

  defp retention_cutoff(handler, policy, now, opts) do
    configured = DateTime.add(now, -Map.fetch!(policy, handler.window) * 86_400, :second)

    case Keyword.get(opts, :cutoff) do
      nil -> {:ok, configured}
      %DateTime{} = cutoff -> validate_supplied_cutoff(cutoff, configured, now)
      _invalid -> {:error, :invalid_privacy_retention_cutoff}
    end
  end

  defp validate_supplied_cutoff(%DateTime{utc_offset: 0, std_offset: 0} = cutoff, configured, now) do
    cond do
      DateTime.compare(cutoff, now) == :gt ->
        {:error, :future_privacy_retention_cutoff}

      DateTime.compare(cutoff, configured) == :gt ->
        {:error, :aggressive_privacy_retention_cutoff}

      true ->
        {:ok, cutoff}
    end
  end

  defp validate_supplied_cutoff(_cutoff, _configured, _now),
    do: {:error, :invalid_privacy_retention_cutoff}

  defp fetch_handler(name) do
    case Enum.find(registry(), &(&1.name == name)) do
      nil -> {:error, :unknown_privacy_retention_handler}
      handler -> {:ok, handler}
    end
  end

  defp policy_option(nil), do: policy()

  defp policy_option(supplied) when is_map(supplied) do
    case policy() do
      {:ok, ^supplied} -> {:ok, supplied}
      {:ok, _configured} -> {:error, :invalid_privacy_retention_config}
      {:error, _reason} = error -> error
    end
  end

  defp policy_option(_invalid), do: {:error, :invalid_privacy_retention_config}

  defp now_option(nil), do: database_now()

  defp now_option(%DateTime{utc_offset: 0, std_offset: 0} = supplied) do
    with {:ok, database_now} <- database_now() do
      if DateTime.compare(supplied, database_now) == :gt,
        do: {:error, :future_privacy_retention_cutoff},
        else: {:ok, supplied}
    end
  end

  defp now_option(_invalid), do: {:error, :invalid_privacy_retention_cutoff}

  defp database_now do
    {:ok, DatabaseClock.now!()}
  rescue
    _error -> {:error, :privacy_database_clock_unavailable}
  catch
    :exit, _reason -> {:error, :privacy_database_clock_unavailable}
  end

  defp naive_utc(%DateTime{utc_offset: 0, std_offset: 0} = value),
    do: {:ok, DateTime.to_naive(value)}

  defp naive_utc(_value), do: {:error, :invalid_privacy_retention_cutoff}

  defp status_cursor(name) do
    case Repo.query(
           "SELECT tenant_cursor FROM privacy_retention_statuses WHERE handler = $1",
           [Atom.to_string(name)],
           log: false
         ) do
      {:ok, %{rows: [[cursor]]}} -> {:ok, cursor}
      {:ok, %{rows: []}} -> {:ok, nil}
      {:error, _reason} -> {:error, :privacy_retention_status_unavailable}
    end
  end

  defp status_failures(name) do
    case Repo.query(
           "SELECT consecutive_failures FROM privacy_retention_statuses WHERE handler = $1",
           [Atom.to_string(name)],
           log: false
         ) do
      {:ok, %{rows: [[value]]}} when is_integer(value) -> value
      _missing_or_failed -> 0
    end
  end

  defp upsert_status(name, attrs) do
    now = DatabaseClock.now!() |> DateTime.to_naive()

    values = [
      Atom.to_string(name),
      Map.get(attrs, :tenant_cursor),
      Map.get(attrs, :backlog_count, 0),
      Map.get(attrs, :oldest_age_seconds, 0),
      Map.get(attrs, :consecutive_failures, 0),
      Map.get(attrs, :alert_state, "ok"),
      Map.get(attrs, :last_error_code),
      naive(Map.get(attrs, :last_started_at)),
      naive(Map.get(attrs, :last_finished_at)),
      naive(Map.get(attrs, :last_succeeded_at)),
      now
    ]

    sql = """
    INSERT INTO privacy_retention_statuses
      (handler, tenant_cursor, backlog_count, oldest_age_seconds,
       consecutive_failures, alert_state, last_error_code, last_started_at,
       last_finished_at, last_succeeded_at, inserted_at, updated_at)
    VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $11)
    ON CONFLICT (handler) DO UPDATE SET
      tenant_cursor = COALESCE(EXCLUDED.tenant_cursor, privacy_retention_statuses.tenant_cursor),
      backlog_count = EXCLUDED.backlog_count,
      oldest_age_seconds = EXCLUDED.oldest_age_seconds,
      consecutive_failures = EXCLUDED.consecutive_failures,
      alert_state = EXCLUDED.alert_state,
      last_error_code = EXCLUDED.last_error_code,
      last_started_at = EXCLUDED.last_started_at,
      last_finished_at = EXCLUDED.last_finished_at,
      last_succeeded_at = COALESCE(EXCLUDED.last_succeeded_at, privacy_retention_statuses.last_succeeded_at),
      updated_at = EXCLUDED.updated_at
    """

    case Repo.query(sql, values, log: false) do
      {:ok, _result} -> :ok
      {:error, _reason} -> {:error, :privacy_retention_status_unavailable}
    end
  end

  defp record_unstarted_failure(name, reason) when is_atom(name) do
    if Enum.any?(registry(), &(&1.name == name)) do
      _ =
        Repo.transaction(fn ->
          acquire_handler_authority!(name)
          now = DatabaseClock.now!()
          failures = status_failures(name) + 1

          case upsert_status(name, %{
                 consecutive_failures: failures,
                 alert_state: if(failures >= 3, do: "critical", else: "warning"),
                 last_error_code: safe_error_code(reason),
                 last_started_at: now,
                 last_finished_at: now
               }) do
            :ok -> :ok
            {:error, failure} -> Repo.rollback(failure)
          end
        end)

      :ok
    else
      :ok
    end
  rescue
    _error -> :ok
  end

  defp record_unstarted_failure(_name, _reason), do: :ok

  defp naive(nil), do: nil
  defp naive(%DateTime{} = value), do: DateTime.to_naive(value)

  defp safe_error_code(reason) do
    reason
    |> Maraithon.Redaction.error_class()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9_]+/, "_")
    |> String.trim("_")
    |> case do
      "" -> "unknown"
      value -> String.slice(value, 0, 128)
    end
  end

  defp adapter_available?(handler) do
    case Code.ensure_loaded(handler.module) do
      {:module, module} ->
        function_exported?(module, handler.purge, 3) and
          function_exported?(module, handler.backlog, 3)

      {:error, _reason} ->
        false
    end
  end

  defp extension_states do
    Enum.reduce_while(@extension_handlers, {:ok, []}, fn handler, {:ok, states} ->
      case migration_recorded?(handler.migration) do
        {:ok, recorded?} ->
          available? = adapter_available?(handler)

          state = %{
            handler: handler.name,
            migration_recorded: recorded?,
            adapter_available: available?,
            activation_ready: not recorded? or available?
          }

          if recorded? and not available?,
            do: {:halt, {:error, :required_privacy_retention_adapter_unavailable}},
            else: {:cont, {:ok, [state | states]}}

        {:error, _reason} = error ->
          {:halt, error}
      end
    end)
    |> case do
      {:ok, states} -> {:ok, Enum.reverse(states)}
      error -> error
    end
  end

  defp migration_recorded?(version) do
    case Repo.query(
           "SELECT EXISTS (SELECT 1 FROM schema_migrations WHERE version = $1)",
           [version],
           log: false
         ) do
      {:ok, %{rows: [[recorded?]]}} when is_boolean(recorded?) -> {:ok, recorded?}
      {:error, _reason} -> {:error, :privacy_migration_state_unavailable}
    end
  end

  defp legacy_snapshot_digest_count do
    case column_exists?("snapshot_quarantines", "payload_digest") do
      {:ok, true} ->
        scalar_count(
          "SELECT count(*)::bigint FROM snapshot_quarantines WHERE payload_digest IS NOT NULL"
        )

      {:ok, false} ->
        {:ok, 0}

      {:error, _reason} = error ->
        error
    end
  end

  defp snapshot_quarantine_orphan_count do
    scalar_count("""
    SELECT count(*)::bigint
    FROM snapshot_quarantines AS report
    WHERE NOT EXISTS (SELECT 1 FROM agents AS agent WHERE agent.id = report.agent_id)
    """)
  end

  defp effect_attestation_orphan_count do
    scalar_count("""
    SELECT count(*)::bigint
    FROM effect_termination_attestations AS attestation
    WHERE NOT EXISTS (SELECT 1 FROM effects AS effect WHERE effect.id = attestation.effect_id)
    """)
  end

  defp scalar_count(sql) do
    case Repo.query(sql, [], log: false) do
      {:ok, %{rows: [[count]]}} when is_integer(count) -> {:ok, count}
      {:error, _reason} -> {:error, :privacy_preflight_unavailable}
    end
  end

  defp column_exists?(table, column) do
    case Repo.query(
           """
           SELECT EXISTS (
             SELECT 1 FROM information_schema.columns
             WHERE table_schema = 'public' AND table_name = $1 AND column_name = $2
           )
           """,
           [table, column],
           log: false
         ) do
      {:ok, %{rows: [[exists?]]}} when is_boolean(exists?) -> {:ok, exists?}
      {:error, _reason} -> {:error, :privacy_catalog_unavailable}
      _invalid -> {:error, :privacy_catalog_unavailable}
    end
  end

  defp clear_legacy_snapshot_digests(limit) do
    case column_exists?("snapshot_quarantines", "payload_digest") do
      {:ok, true} ->
        result =
          Repo.query!(
            """
            WITH candidates AS (
              SELECT id FROM snapshot_quarantines
              WHERE payload_digest IS NOT NULL
              ORDER BY inserted_at, id
              LIMIT $1 FOR UPDATE SKIP LOCKED
            )
            UPDATE snapshot_quarantines AS report
            SET payload_digest = NULL
            FROM candidates WHERE report.id = candidates.id
            """,
            [limit],
            log: false
          )

        result.num_rows

      {:ok, false} ->
        0

      {:error, reason} ->
        Repo.rollback(reason)
    end
  end

  defp delete_snapshot_quarantine_orphans(limit) do
    result =
      Repo.query!(
        """
        WITH candidates AS (
          SELECT report.id
          FROM snapshot_quarantines AS report
          WHERE NOT EXISTS (SELECT 1 FROM agents AS agent WHERE agent.id = report.agent_id)
          ORDER BY report.inserted_at, report.id
          LIMIT $1 FOR UPDATE OF report SKIP LOCKED
        )
        DELETE FROM snapshot_quarantines AS report
        USING candidates WHERE report.id = candidates.id
        """,
        [limit],
        log: false
      )

    result.num_rows
  end

  defp delete_effect_attestation_orphans(limit) do
    Repo.query!(
      "SELECT set_config('maraithon.effect_attestation_cleanup', 'ORPHAN_CLEANUP_V1', true)",
      [],
      log: false
    )

    result =
      Repo.query!(
        """
        WITH candidates AS (
          SELECT attestation.id
          FROM effect_termination_attestations AS attestation
          WHERE NOT EXISTS (
            SELECT 1 FROM effects AS effect WHERE effect.id = attestation.effect_id
          )
          ORDER BY attestation.inserted_at, attestation.id
          LIMIT $1 FOR UPDATE OF attestation SKIP LOCKED
        )
        DELETE FROM effect_termination_attestations AS attestation
        USING candidates WHERE attestation.id = candidates.id
        """,
        [limit],
        log: false
      )

    result.num_rows
  end

  defp validate_constraint_if_present(table, constraint) do
    # Both identifiers come exclusively from the fixed calls in
    # finalize_constraints/0; no configuration or user input reaches SQL.
    Repo.query!(
      """
      DO $privacy$
      BEGIN
        IF EXISTS (
          SELECT 1 FROM pg_constraint
          WHERE conrelid = 'public.#{table}'::regclass
            AND conname = '#{constraint}' AND NOT convalidated
        ) THEN
          ALTER TABLE public.#{table} VALIDATE CONSTRAINT #{constraint};
        END IF;
      END
      $privacy$
      """,
      [],
      log: false
    )
  end
end
