defmodule Maraithon.TelegramConversations.Privacy do
  @moduledoc """
  Bounded rollout and retention operations for conversation payloads.

  The schema migration is expansion-only. `backfill/1` is the explicit,
  rerunnable operator step that encrypts legacy plaintext in small locked
  batches and tombstones the old columns. `scrub_expired/1` removes only
  sensitive content, never conversation/turn identities or promoted dedupe and
  work-link facts.
  """

  import Ecto.Query

  alias Maraithon.Agents.{Agent, AgentRun}
  alias Maraithon.DurablePayload
  alias Maraithon.Effects.ProtocolCutover
  alias Maraithon.OperatorEvents.OperatorEvent
  alias Maraithon.OperatorMemory.Summary, as: OperatorMemorySummary
  alias Maraithon.Repo

  alias Maraithon.Runtime.{
    AgentWorkResult,
    BackgroundJob,
    IngressReceipt,
    ScheduledJob
  }

  alias Maraithon.TelegramAssistant.{PreparedAction, Run, Step}
  alias Maraithon.TelegramConversations.{Conversation, Turn}
  alias Maraithon.Todos.Todo
  alias Maraithon.UserMemory.Profile, as: UserMemoryProfile

  @default_retention_days 90
  @default_batch_size 100
  @default_max_batches 20
  @max_batch_size 500
  @max_batches 1_000
  @active_run_statuses ~w(queued running waiting_confirmation)
  @terminal_action_statuses ~w(executed rejected expired failed)
  @terminal_todo_statuses ~w(done dismissed)
  @families [
    :turns,
    :conversations,
    :assistant_runs,
    :assistant_steps,
    :prepared_actions,
    :agent_runs,
    :operator_events,
    :user_memory_profiles,
    :operator_memory_summaries,
    :background_jobs,
    :scheduled_jobs,
    :ingress_receipts,
    :agent_work_results
  ]

  def retention_days do
    :maraithon
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:retention_days, @default_retention_days)
    |> positive_integer(@default_retention_days)
  end

  @doc "Returns fixed authenticated-payload metadata for global verifier registration."
  def payload_specs do
    [
      Turn,
      Conversation,
      Run,
      Step,
      PreparedAction,
      AgentRun,
      OperatorEvent,
      UserMemoryProfile,
      OperatorMemorySummary,
      BackgroundJob,
      ScheduledJob,
      IngressReceipt,
      AgentWorkResult
    ]
    |> Enum.map(& &1.payload_binding_spec())
  end

  @doc "Content-free eligible, deferred, and raw-size-blocked counts for every family."
  def preflight do
    families =
      Map.new(@families, fn family ->
        base = backlog_query(family)
        deferred = deferred_query(base, family)
        blocked = base |> blocked_query(family) |> exclude_query(deferred)

        eligible =
          base
          |> exclude_query(deferred)
          |> exclude_query(blocked)
          |> Repo.aggregate(:count, :id)

        {family,
         %{
           eligible: eligible,
           deferred: Repo.aggregate(deferred, :count, :id),
           blocked: Repo.aggregate(blocked, :count, :id)
         }}
      end)

    families
    |> Map.put(:legacy_turns, backlog_total(families.turns))
    |> Map.put(:legacy_conversations, backlog_total(families.conversations))
  end

  @doc "Runs bounded stopped-fleet Repo/Vault contraction batches."
  def backfill(opts \\ [])

  def backfill(opts) when is_list(opts) do
    with {:ok, config} <- backfill_config(opts) do
      initial = %{
        batches: 0,
        migrated: Map.new(@families, &{&1, 0}),
        blocked: Map.new(@families, &{&1, []}),
        excluded: Map.new(@families, &{&1, []})
      }

      run_backfill_batches(initial, config)
    end
  end

  def backfill(_opts), do: {:error, :invalid_options}

  @doc false
  def backfill_batch(opts \\ [])

  def backfill_batch(opts) when is_list(opts) do
    with {:ok, config} <- backfill_config(opts) do
      Repo.transaction(
        fn ->
          # Protocol marker is always the first database lock in the mutation.
          :ok = DurablePayload.require_legacy_mutation!()
          :ok = assert_stopped_fleet!()

          {migrated, blocked, remaining} =
            Enum.reduce(@families, {%{}, %{}, config.batch_size}, fn
              _family, acc = {_migrated, _blocked, 0} ->
                acc

              family, {migrated, blocked, remaining} ->
                excluded = Map.get(config.excluded, family, [])
                base = backlog_query(family)

                raw_blocked_ids =
                  base
                  |> blocked_query(family)
                  |> exclude_query(deferred_query(base, family))
                  |> exclude_ids(excluded)
                  |> lock_backfill_ids(remaining)

                remaining = remaining - length(raw_blocked_ids)

                candidate_ids =
                  if remaining == 0 do
                    []
                  else
                    family
                    |> candidate_query(excluded ++ raw_blocked_ids)
                    |> lock_backfill_ids(remaining)
                  end

                {migrated_count, failures} = migrate_rows(family, candidate_ids)

                raw_failures =
                  Enum.map(raw_blocked_ids, &%{id: &1, failure: :payload_too_large})

                {
                  Map.put(migrated, family, migrated_count),
                  Map.put(blocked, family, raw_failures ++ failures),
                  remaining - length(candidate_ids)
                }
            end)

          migrated = fill_family_defaults(migrated, 0)
          blocked = fill_family_defaults(blocked, [])

          %{
            migrated: migrated,
            blocked: blocked,
            migrated_turns: migrated.turns,
            migrated_conversations: migrated.conversations,
            blocked_turns: blocked.turns,
            blocked_conversations: blocked.conversations,
            processed: config.batch_size - remaining
          }
        end,
        timeout: 60_000
      )
    end
  end

  def backfill_batch(_opts), do: {:error, :invalid_options}

  defp run_backfill_batches(%{batches: batches} = state, %{max_batches: max_batches})
       when batches >= max_batches do
    {:ok, finalize_backfill(state)}
  end

  defp run_backfill_batches(state, config) do
    case backfill_batch(
           batch_size: config.batch_size,
           max_batches: 1,
           confirmation: config.confirmation,
           excluded: state.excluded
         ) do
      {:ok, batch} ->
        next = merge_backfill_batch(state, batch)

        if batch.processed == 0,
          do: {:ok, finalize_backfill(next)},
          else: run_backfill_batches(next, config)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp finalize_backfill(state) do
    %{
      batches: state.batches,
      migrated: state.migrated,
      blocked: state.blocked,
      migrated_turns: state.migrated.turns,
      migrated_conversations: state.migrated.conversations,
      blocked_turns: state.blocked.turns,
      blocked_conversations: state.blocked.conversations,
      remaining: preflight()
    }
  end

  defp merge_backfill_batch(state, batch) do
    blocked =
      Map.new(@families, fn family ->
        {family, Map.fetch!(state.blocked, family) ++ Map.fetch!(batch.blocked, family)}
      end)

    %{
      state
      | batches: state.batches + 1,
        migrated:
          Map.new(@families, fn family ->
            {family, Map.fetch!(state.migrated, family) + Map.fetch!(batch.migrated, family)}
          end),
        blocked: blocked,
        excluded:
          Map.new(@families, fn family ->
            ids = Enum.map(Map.fetch!(blocked, family), & &1.id)
            {family, Enum.uniq(ids)}
          end)
    }
  end

  defp backfill_config(opts) do
    batch_size = batch_size(opts)
    max_batches = opts |> Keyword.get(:max_batches, @default_max_batches) |> bounded_max_batches()
    confirmation = Keyword.get(opts, :confirmation)
    excluded = Keyword.get(opts, :excluded, %{})

    if Keyword.keyword?(opts) and confirmation == ProtocolCutover.activation_confirmation() and
         is_map(excluded) do
      {:ok,
       %{
         batch_size: batch_size,
         max_batches: max_batches,
         confirmation: confirmation,
         excluded: excluded
       }}
    else
      {:error, :stopped_fleet_confirmation_required}
    end
  end

  defp assert_stopped_fleet! do
    case Repo.query!("SELECT COUNT(*) FROM public.agent_runtime_leases", [], log: false).rows do
      [[0]] -> :ok
      [[count]] -> Repo.rollback({:runtime_workers_require_drain, count})
    end
  end

  @doc "Content-free user erasure readiness by durable payload family."
  def erasure_backlog(user_id) when is_binary(user_id) and user_id != "" do
    eligible =
      erasure_families()
      |> Map.new(fn family ->
        {family, family |> erasure_query(user_id) |> Repo.aggregate(:count, :id)}
      end)

    deferred =
      Map.new(@families, &{&1, 0})
      |> Map.merge(%{
        turns:
          Turn
          |> join(:inner, [row], conversation in Conversation,
            on: conversation.id == row.conversation_id
          )
          |> where(
            [row, conversation],
            conversation.user_id == ^user_id and conversation.status != "closed" and
              is_nil(row.content_scrubbed_at)
          )
          |> Repo.aggregate(:count, :id),
        conversations:
          Conversation
          |> where(
            [row],
            row.user_id == ^user_id and row.status != "closed" and
              is_nil(row.content_scrubbed_at)
          )
          |> Repo.aggregate(:count, :id),
        assistant_runs:
          Run
          |> where([row], row.user_id == ^user_id and row.status in ^@active_run_statuses)
          |> where([row], is_nil(row.payload_purged_at))
          |> Repo.aggregate(:count, :id),
        assistant_steps:
          Step
          |> join(:inner, [step], run in Run, on: run.id == step.run_id)
          |> where([step, run], run.user_id == ^user_id and run.status in ^@active_run_statuses)
          |> where([step, _run], is_nil(step.payload_purged_at))
          |> Repo.aggregate(:count, :id),
        prepared_actions:
          PreparedAction
          |> where(
            [row],
            row.user_id == ^user_id and row.status not in ^@terminal_action_statuses
          )
          |> where([row], is_nil(row.payload_purged_at))
          |> Repo.aggregate(:count, :id),
        agent_runs:
          AgentRun
          |> where([row], row.user_id == ^user_id and row.status == "running")
          |> where([row], is_nil(row.private_payload_purged_at))
          |> Repo.aggregate(:count, :id),
        background_jobs:
          BackgroundJob
          |> where([row], row.user_id == ^user_id and row.status in ["pending", "running"])
          |> where([row], is_nil(row.payload_purged_at))
          |> Repo.aggregate(:count, :id),
        scheduled_jobs:
          ScheduledJob
          |> join(:inner, [row], agent in Agent, on: agent.id == row.agent_id)
          |> where(
            [row, agent],
            agent.user_id == ^user_id and row.status in ["pending", "dispatched"] and
              is_nil(row.payload_purged_at)
          )
          |> Repo.aggregate(:count, :id),
        agent_work_results:
          AgentWorkResult
          |> where([row], row.user_id == ^user_id and is_nil(row.result_purged_at))
          |> Repo.aggregate(:count, :id)
      })

    %{eligible: eligible, deferred: deferred, blocked: %{}}
  end

  def erasure_backlog(_user_id), do: %{error: :invalid_user_id}

  @doc "Erases one bounded stopped-fleet batch without deleting authority rows."
  def erase_user_batch(user_id, opts \\ [])

  def erase_user_batch(user_id, opts)
      when is_binary(user_id) and user_id != "" and is_list(opts) do
    limit = batch_size(opts)
    confirmation = Keyword.get(opts, :confirmation)
    now = Keyword.get(opts, :now, DateTime.utc_now())

    if confirmation == ProtocolCutover.activation_confirmation() and match?(%DateTime{}, now) do
      Repo.transaction(
        fn ->
          :ok = DurablePayload.require_current_mutation!()
          :ok = assert_stopped_fleet!()

          {erased, remaining} =
            Enum.reduce(erasure_families(), {%{}, limit}, fn
              _family, acc = {_erased, 0} ->
                acc

              family, {erased, remaining} ->
                ids = lock_erasure_ids(family, user_id, remaining)
                count = purge_family_ids(family, ids, now)
                {Map.put(erased, family, count), remaining - length(ids)}
            end)

          %{
            erased: fill_family_defaults(erased, 0),
            processed: limit - remaining,
            deferred: erasure_backlog(user_id).deferred,
            retained_authority_rows: true
          }
        end,
        timeout: 60_000
      )
    else
      {:error, :stopped_fleet_confirmation_required}
    end
  end

  def erase_user_batch(_user_id, _opts), do: {:error, :invalid_user_id}

  defp erasure_families do
    [
      :turns,
      :conversations,
      :assistant_runs,
      :assistant_steps,
      :prepared_actions,
      :agent_runs,
      :operator_events,
      :user_memory_profiles,
      :operator_memory_summaries,
      :background_jobs,
      :scheduled_jobs,
      :ingress_receipts
    ]
  end

  defp erasure_query(:turns, user_id) do
    Turn
    |> join(:inner, [row], conversation in Conversation,
      on: conversation.id == row.conversation_id
    )
    |> where(
      [row, conversation],
      conversation.user_id == ^user_id and conversation.status == "closed" and
        is_nil(row.content_scrubbed_at)
    )
  end

  defp erasure_query(:conversations, user_id) do
    Conversation
    |> where(
      [row],
      row.user_id == ^user_id and row.status == "closed" and is_nil(row.content_scrubbed_at)
    )
  end

  defp erasure_query(:assistant_runs, user_id) do
    Run
    |> where([row], row.user_id == ^user_id)
    |> where([row], row.status in ["completed", "failed", "cancelled", "degraded"])
    |> where([row], is_nil(row.payload_purged_at))
  end

  defp erasure_query(:assistant_steps, user_id) do
    Step
    |> join(:inner, [step], run in Run, on: run.id == step.run_id)
    |> where([step, run], run.user_id == ^user_id and run.status not in ^@active_run_statuses)
    |> where([step, _run], is_nil(step.payload_purged_at))
  end

  defp erasure_query(:prepared_actions, user_id) do
    PreparedAction
    |> where([row], row.user_id == ^user_id and row.status in ^@terminal_action_statuses)
    |> where([row], is_nil(row.payload_purged_at))
  end

  defp erasure_query(:agent_runs, user_id) do
    AgentRun
    |> where([row], row.user_id == ^user_id and row.status != "running")
    |> where([row], is_nil(row.private_payload_purged_at))
  end

  defp erasure_query(:operator_events, user_id) do
    OperatorEvent
    |> where([row], row.user_id == ^user_id and is_nil(row.payload_purged_at))
  end

  defp erasure_query(:user_memory_profiles, user_id) do
    UserMemoryProfile
    |> where([row], row.user_id == ^user_id and is_nil(row.content_erased_at))
  end

  defp erasure_query(:operator_memory_summaries, user_id) do
    OperatorMemorySummary
    |> where([row], row.user_id == ^user_id and is_nil(row.content_erased_at))
  end

  defp erasure_query(:background_jobs, user_id) do
    BackgroundJob
    |> where(
      [row],
      row.user_id == ^user_id and row.status in ["completed", "failed", "cancelled"]
    )
    |> where([row], is_nil(row.payload_purged_at))
  end

  defp erasure_query(:scheduled_jobs, user_id) do
    ScheduledJob
    |> join(:inner, [row], agent in Agent, on: agent.id == row.agent_id)
    |> where([row, agent], agent.user_id == ^user_id)
    |> where([row, _agent], row.status in ["delivered", "cancelled", "failed"])
    |> where([row, _agent], is_nil(row.payload_purged_at))
  end

  defp erasure_query(:ingress_receipts, user_id) do
    IngressReceipt
    |> where([row], row.user_id == ^user_id and is_nil(row.payload_purged_at))
  end

  defp lock_erasure_ids(family, user_id, limit) do
    family
    |> erasure_query(user_id)
    |> order_by([row], asc: row.id)
    |> select([row], row.id)
    |> limit(^limit)
    |> lock("FOR UPDATE SKIP LOCKED")
    |> Repo.all()
  end

  @doc "Content-free retention counts for the central tenant-fair registry."
  def retention_backlog(cutoff, tenant_cursor, opts \\ [])

  def retention_backlog(%DateTime{} = cutoff, tenant_cursor, opts) when is_list(opts) do
    eligible =
      retention_families()
      |> Map.new(fn family ->
        {family, family |> retention_query(cutoff, tenant_cursor) |> Repo.aggregate(:count, :id)}
      end)

    deferred_work_results =
      AgentWorkResult
      |> where([row], row.status == "committed" and row.committed_at < ^cutoff)
      |> where([row], is_nil(row.result_purged_at))
      |> Repo.aggregate(:count, :id)

    %{
      eligible: eligible,
      deferred:
        Map.new(@families, &{&1, 0})
        |> Map.put(:agent_work_results, deferred_work_results),
      blocked: Map.new(@families, &{&1, 0}),
      tenant_cursor: tenant_cursor
    }
  end

  def retention_backlog(_cutoff, tenant_cursor, _opts),
    do: %{error: :invalid_cutoff, tenant_cursor: tenant_cursor}

  @doc "Purges one bounded terminal/closed/expired retention batch with SKIP LOCKED."
  def purge_retention_batch(cutoff, tenant_cursor, opts \\ [])

  def purge_retention_batch(%DateTime{} = cutoff, tenant_cursor, opts) when is_list(opts) do
    limit = batch_size(opts)
    now = Keyword.get(opts, :now, DateTime.utc_now())

    if match?(%DateTime{}, now) do
      Repo.transaction(
        fn ->
          :ok = DurablePayload.require_current_mutation!()

          {purged, remaining} =
            Enum.reduce(retention_families(), {%{}, limit}, fn
              _family, acc = {_purged, 0} ->
                acc

              family, {purged, remaining} ->
                ids = lock_retention_ids(family, cutoff, tenant_cursor, remaining)
                count = purge_family_ids(family, ids, now)
                {Map.put(purged, family, count), remaining - length(ids)}
            end)

          %{
            purged: fill_family_defaults(purged, 0),
            processed: limit - remaining,
            tenant_cursor: tenant_cursor,
            retained_ids: true
          }
        end,
        timeout: 60_000
      )
    else
      {:error, :invalid_now}
    end
  end

  def purge_retention_batch(_cutoff, _tenant_cursor, _opts), do: {:error, :invalid_cutoff}

  defp retention_families do
    [
      :turns,
      :conversations,
      :assistant_runs,
      :assistant_steps,
      :prepared_actions,
      :agent_runs,
      :operator_events,
      :user_memory_profiles,
      :operator_memory_summaries,
      :background_jobs,
      :scheduled_jobs,
      :ingress_receipts
    ]
  end

  defp retention_query(:turns, cutoff, _cursor) do
    eligible_ids =
      cutoff
      |> eligible_conversations()
      |> select([conversation: conversation], conversation.id)

    Turn
    |> where([row], row.conversation_id in subquery(eligible_ids))
    |> where([row], row.inserted_at < ^cutoff and is_nil(row.content_scrubbed_at))
  end

  defp retention_query(:conversations, cutoff, _cursor), do: eligible_conversations(cutoff)

  defp retention_query(:assistant_runs, cutoff, cursor) do
    pending_action =
      from action in PreparedAction,
        where:
          action.run_id == parent_as(:retention_run).id and
            action.status not in ^@terminal_action_statuses,
        select: 1

    from(row in Run, as: :retention_run)
    |> where([row], row.status in ["completed", "failed", "cancelled", "degraded"])
    |> where([row], row.finished_at < ^cutoff and is_nil(row.payload_purged_at))
    |> where([row], not exists(subquery(pending_action)))
    |> maybe_tenant_cursor(:user_id, cursor)
  end

  defp retention_query(:assistant_steps, cutoff, _cursor) do
    Step
    |> where([row], row.status in ["completed", "failed", "skipped"])
    |> where([row], row.finished_at < ^cutoff and is_nil(row.payload_purged_at))
  end

  defp retention_query(:prepared_actions, cutoff, cursor) do
    PreparedAction
    |> where([row], row.status in ^@terminal_action_statuses)
    |> where(
      [row],
      fragment("COALESCE(?, ?) < ?", row.executed_at, row.updated_at, ^cutoff) and
        is_nil(row.payload_purged_at)
    )
    |> maybe_tenant_cursor(:user_id, cursor)
  end

  defp retention_query(:agent_runs, cutoff, cursor) do
    AgentRun
    |> where([row], row.status in ["completed", "failed", "cancelled"])
    |> where([row], row.completed_at < ^cutoff and is_nil(row.private_payload_purged_at))
    |> maybe_tenant_cursor(:user_id, cursor)
  end

  defp retention_query(:operator_events, cutoff, cursor) do
    OperatorEvent
    |> where([row], row.occurred_at < ^cutoff and is_nil(row.payload_purged_at))
    |> maybe_tenant_cursor(:user_id, cursor)
  end

  defp retention_query(:user_memory_profiles, cutoff, cursor) do
    UserMemoryProfile
    |> where(
      [row],
      fragment("COALESCE(?, ?) < ?", row.source_window_end, row.updated_at, ^cutoff) and
        is_nil(row.content_erased_at)
    )
    |> maybe_tenant_cursor(:user_id, cursor)
  end

  defp retention_query(:operator_memory_summaries, cutoff, cursor) do
    OperatorMemorySummary
    |> where(
      [row],
      fragment("COALESCE(?, ?) < ?", row.source_window_end, row.updated_at, ^cutoff) and
        is_nil(row.content_erased_at)
    )
    |> maybe_tenant_cursor(:user_id, cursor)
  end

  defp retention_query(:background_jobs, cutoff, cursor) do
    BackgroundJob
    |> where([row], row.status in ["completed", "failed", "cancelled"])
    |> where(
      [row],
      fragment(
        "COALESCE(?, ?, ?, ?) < ?",
        row.completed_at,
        row.failed_at,
        row.cancelled_at,
        row.updated_at,
        ^cutoff
      ) and
        is_nil(row.payload_purged_at)
    )
    |> maybe_tenant_cursor(:user_id, cursor)
  end

  defp retention_query(:scheduled_jobs, cutoff, _cursor) do
    ScheduledJob
    |> where([row], row.status in ["delivered", "cancelled", "failed"])
    |> where(
      [row],
      fragment("COALESCE(?, ?) < ?", row.delivered_at, row.updated_at, ^cutoff) and
        is_nil(row.payload_purged_at)
    )
  end

  defp retention_query(:ingress_receipts, cutoff, cursor) do
    IngressReceipt
    |> where([row], row.received_at < ^cutoff and is_nil(row.payload_purged_at))
    |> maybe_tenant_cursor(:user_id, cursor)
  end

  defp maybe_tenant_cursor(query, field, cursor) when is_binary(cursor) and cursor != "" do
    where(query, [row], field(row, ^field) >= ^cursor)
  end

  defp maybe_tenant_cursor(query, _field, _cursor), do: query

  defp lock_retention_ids(:conversations, cutoff, cursor, limit) do
    :conversations
    |> retention_query(cutoff, cursor)
    |> order_by([conversation: row], asc_nulls_first: row.last_turn_at, asc: row.id)
    |> select([conversation: row], row.id)
    |> limit(^limit)
    |> lock("FOR UPDATE SKIP LOCKED")
    |> Repo.all()
  end

  defp lock_retention_ids(family, cutoff, cursor, limit) do
    family
    |> retention_query(cutoff, cursor)
    |> order_by([row], asc: row.id)
    |> select([row], row.id)
    |> limit(^limit)
    |> lock("FOR UPDATE SKIP LOCKED")
    |> Repo.all()
  end

  defp purge_family_ids(_family, [], _now), do: 0

  defp purge_family_ids(:turns, ids, now) do
    update_purged(
      Turn,
      ids,
      text: nil,
      structured_data: nil,
      legacy_text: Turn.legacy_text_tombstone(),
      legacy_structured_data: %{},
      payload_binding_version: nil,
      payload_binding_key_tag: nil,
      payload_binding_mac: nil,
      content_scrubbed_at: now
    )
  end

  defp purge_family_ids(:conversations, ids, now) do
    {count, _} =
      from(row in Conversation,
        where: row.id in ^ids,
        update: [
          set: [
            summary: nil,
            legacy_summary: nil,
            historical_summary: nil,
            metadata: fragment("? - 'historical_summary'", row.metadata),
            payload_binding_version: nil,
            payload_binding_key_tag: nil,
            payload_binding_mac: nil,
            content_scrubbed_at: ^now
          ]
        ]
      )
      |> Repo.update_all([])

    count
  end

  defp purge_family_ids(:assistant_runs, ids, now) do
    update_purged(Run, ids,
      prompt_snapshot: nil,
      result_summary: nil,
      legacy_prompt_snapshot: %{},
      legacy_result_summary: %{},
      delivery_checkpoint_source_message_id: nil,
      payload_binding_version: nil,
      payload_binding_key_tag: nil,
      payload_binding_mac: nil,
      payload_purged_at: now
    )
  end

  defp purge_family_ids(:assistant_steps, ids, now) do
    update_purged(Step, ids,
      request_payload: nil,
      response_payload: nil,
      legacy_request_payload: %{},
      legacy_response_payload: %{},
      payload_binding_version: nil,
      payload_binding_key_tag: nil,
      payload_binding_mac: nil,
      payload_purged_at: now
    )
  end

  defp purge_family_ids(:prepared_actions, ids, now) do
    update_purged(PreparedAction, ids,
      payload: nil,
      preview_text: nil,
      legacy_payload: %{},
      legacy_preview_text: nil,
      payload_todo_id: nil,
      payload_surviving_person_id: nil,
      payload_merged_person_id: nil,
      payload_binding_version: nil,
      payload_binding_key_tag: nil,
      payload_binding_mac: nil,
      payload_purged_at: now
    )
  end

  defp purge_family_ids(:agent_runs, ids, now) do
    update_purged(AgentRun, ids,
      trigger: nil,
      metadata: nil,
      legacy_trigger: %{},
      legacy_metadata: %{},
      legacy_budget_snapshot: %{},
      payload_binding_version: nil,
      payload_binding_key_tag: nil,
      payload_binding_mac: nil,
      private_payload_purged_at: now
    )
  end

  defp purge_family_ids(:operator_events, ids, now) do
    update_purged(OperatorEvent, ids,
      payload: nil,
      metadata: nil,
      legacy_payload: %{},
      legacy_metadata: %{},
      payload_binding_version: nil,
      payload_binding_key_tag: nil,
      payload_binding_mac: nil,
      payload_purged_at: now
    )
  end

  defp purge_family_ids(:user_memory_profiles, ids, now) do
    update_purged(UserMemoryProfile, ids,
      summary: nil,
      profile: nil,
      legacy_summary: UserMemoryProfile.legacy_tombstone(),
      legacy_profile: %{},
      payload_binding_version: nil,
      payload_binding_key_tag: nil,
      payload_binding_mac: nil,
      content_erased_at: now
    )
  end

  defp purge_family_ids(:operator_memory_summaries, ids, now) do
    update_purged(OperatorMemorySummary, ids,
      content: nil,
      legacy_content: OperatorMemorySummary.legacy_tombstone(),
      payload_binding_version: nil,
      payload_binding_key_tag: nil,
      payload_binding_mac: nil,
      content_erased_at: now
    )
  end

  defp purge_family_ids(:background_jobs, ids, now) do
    update_purged(BackgroundJob, ids,
      payload: nil,
      result: nil,
      legacy_payload: %{},
      legacy_result: %{},
      payload_binding_version: nil,
      payload_binding_key_tag: nil,
      payload_binding_mac: nil,
      payload_purged_at: now
    )
  end

  defp purge_family_ids(:scheduled_jobs, ids, now) do
    update_purged(ScheduledJob, ids,
      payload: nil,
      legacy_payload: %{},
      payload_scope_key: nil,
      payload_scope_value: nil,
      payload_dedupe_key: nil,
      payload_empty: nil,
      payload_binding_version: nil,
      payload_binding_key_tag: nil,
      payload_binding_mac: nil,
      payload_purged_at: now
    )
  end

  defp purge_family_ids(:ingress_receipts, ids, now) do
    update_purged(IngressReceipt, ids,
      payload: nil,
      legacy_payload: %{},
      payload_binding_version: nil,
      payload_binding_key_tag: nil,
      payload_binding_mac: nil,
      payload_purged_at: now
    )
  end

  defp update_purged(schema, ids, updates) do
    {count, _} =
      schema
      |> where([row], row.id in ^ids)
      |> Repo.update_all(set: updates)

    count
  end

  @doc """
  Scrubs one bounded retention batch.

  Only closed conversations older than the retention window qualify. A
  conversation is excluded while it has an active assistant run, a pending or
  outcome-unknown prepared action, or a linked open/snoozed todo. Rows are not
  deleted: message IDs, client IDs, source IDs, promoted run/action/todo facts,
  and OperatorEvent dedupe keys remain intact.
  """
  def scrub_expired(opts \\ [])

  def scrub_expired(opts) when is_list(opts), do: do_scrub_expired(opts)

  def scrub_expired(_opts), do: {:error, :invalid_options}

  defp do_scrub_expired(opts) do
    limit = batch_size(opts)

    days =
      opts |> Keyword.get(:retention_days, retention_days()) |> positive_integer(retention_days())

    now = Keyword.get(opts, :now, DateTime.utc_now())

    if match?(%DateTime{}, now) do
      cutoff = DateTime.add(now, -days * 86_400, :second)

      Repo.transaction(
        fn ->
          :ok = DurablePayload.require_current_mutation!()

          conversations =
            cutoff
            |> eligible_conversations()
            |> order_by([conversation: conversation],
              asc_nulls_first: conversation.last_turn_at,
              asc: conversation.id
            )
            |> limit(^limit)
            |> lock("FOR UPDATE SKIP LOCKED")
            |> Repo.all()

          conversation_ids = Enum.map(conversations, & &1.id)
          turn_ids = lock_unscrubbed_turn_ids(conversation_ids, cutoff, limit)
          scrubbed_turns = scrub_turn_ids(turn_ids, now)
          scrubbed_conversations = scrub_conversation_summaries(conversations, now)

          %{
            scrubbed_turns: scrubbed_turns,
            scrubbed_conversations: scrubbed_conversations,
            retained_ids: true
          }
        end,
        timeout: 60_000
      )
    else
      {:error, :invalid_now}
    end
  end

  defp backlog_total(counts), do: counts.eligible + counts.deferred + counts.blocked

  defp fill_family_defaults(values, default),
    do: Map.new(@families, &{&1, Map.get(values, &1, default)})

  defp exclude_query(query, excluded_query) do
    excluded_ids = from(row in excluded_query, select: row.id)
    where(query, [row], row.id not in subquery(excluded_ids))
  end

  defp exclude_ids(query, []), do: query
  defp exclude_ids(query, ids) when is_list(ids), do: where(query, [row], row.id not in ^ids)
  defp exclude_ids(query, _invalid), do: query

  defp lock_backfill_ids(query, limit) do
    query
    |> order_by([row], asc: row.id)
    |> limit(^limit)
    |> select([row], row.id)
    |> lock("FOR UPDATE SKIP LOCKED")
    |> Repo.all()
  end

  defp candidate_query(family, excluded_ids) do
    base = backlog_query(family)

    base
    |> exclude_query(deferred_query(base, family))
    |> exclude_query(blocked_query(base, family))
    |> exclude_ids(excluded_ids)
  end

  defp backlog_query(:turns) do
    Turn
    |> where([row], is_nil(row.content_scrubbed_at))
    |> where(
      [row],
      fragment(
        "? IS DISTINCT FROM 1 OR ? IS NULL OR ? IS NULL OR ? IS DISTINCT FROM ? OR ? IS DISTINCT FROM '{}'::jsonb OR ? IS DISTINCT FROM 1 OR ? IS NULL OR octet_length(?) IS DISTINCT FROM 32",
        row.payload_encryption_version,
        row.text,
        row.structured_data,
        row.legacy_text,
        ^Turn.legacy_text_tombstone(),
        row.legacy_structured_data,
        row.payload_binding_version,
        row.payload_binding_key_tag,
        row.payload_binding_mac
      )
    )
  end

  defp backlog_query(:conversations) do
    Conversation
    |> where([row], is_nil(row.content_scrubbed_at))
    |> where(
      [row],
      fragment(
        "? IS DISTINCT FROM 1 OR ? IS NOT NULL OR jsonb_exists(?, 'historical_summary') OR ? IS DISTINCT FROM 1 OR ? IS NULL OR octet_length(?) IS DISTINCT FROM 32",
        row.payload_encryption_version,
        row.legacy_summary,
        row.metadata,
        row.payload_binding_version,
        row.payload_binding_key_tag,
        row.payload_binding_mac
      )
    )
  end

  defp backlog_query(:assistant_runs) do
    Run
    |> where([row], is_nil(row.payload_purged_at))
    |> where(
      [row],
      fragment(
        "? IS DISTINCT FROM 1 OR ? IS NULL OR ? IS NULL OR ? IS DISTINCT FROM '{}'::jsonb OR ? IS DISTINCT FROM '{}'::jsonb OR ? IS DISTINCT FROM 1 OR ? IS NULL OR octet_length(?) IS DISTINCT FROM 32",
        row.payload_encryption_version,
        row.prompt_snapshot,
        row.result_summary,
        row.legacy_prompt_snapshot,
        row.legacy_result_summary,
        row.payload_binding_version,
        row.payload_binding_key_tag,
        row.payload_binding_mac
      )
    )
  end

  defp backlog_query(:assistant_steps) do
    Step
    |> where([row], is_nil(row.payload_purged_at))
    |> where(
      [row],
      fragment(
        "? IS DISTINCT FROM 1 OR ? IS NULL OR ? IS NULL OR ? IS DISTINCT FROM '{}'::jsonb OR ? IS DISTINCT FROM '{}'::jsonb OR ? IS DISTINCT FROM 1 OR ? IS NULL OR octet_length(?) IS DISTINCT FROM 32",
        row.payload_encryption_version,
        row.request_payload,
        row.response_payload,
        row.legacy_request_payload,
        row.legacy_response_payload,
        row.payload_binding_version,
        row.payload_binding_key_tag,
        row.payload_binding_mac
      )
    )
  end

  defp backlog_query(:prepared_actions) do
    PreparedAction
    |> where([row], is_nil(row.payload_purged_at))
    |> where(
      [row],
      fragment(
        "? IS DISTINCT FROM 1 OR ? IS NULL OR ? IS NULL OR ? IS DISTINCT FROM '{}'::jsonb OR ? IS NOT NULL OR ? IS DISTINCT FROM 1 OR ? IS NULL OR octet_length(?) IS DISTINCT FROM 32",
        row.payload_encryption_version,
        row.payload,
        row.preview_text,
        row.legacy_payload,
        row.legacy_preview_text,
        row.payload_binding_version,
        row.payload_binding_key_tag,
        row.payload_binding_mac
      )
    )
  end

  defp backlog_query(:agent_runs) do
    AgentRun
    |> where([row], is_nil(row.private_payload_purged_at))
    |> where(
      [row],
      fragment(
        "? IS DISTINCT FROM 1 OR ? IS NULL OR ? IS NULL OR ? IS DISTINCT FROM '{}'::jsonb OR ? IS DISTINCT FROM '{}'::jsonb OR ? IS DISTINCT FROM '{}'::jsonb OR ? IS NULL OR ? IS NULL OR ? IS DISTINCT FROM 1 OR ? IS NULL OR octet_length(?) IS DISTINCT FROM 32",
        row.private_payload_encryption_version,
        row.trigger,
        row.metadata,
        row.legacy_trigger,
        row.legacy_metadata,
        row.legacy_budget_snapshot,
        row.budget_llm_calls,
        row.budget_tool_calls,
        row.payload_binding_version,
        row.payload_binding_key_tag,
        row.payload_binding_mac
      )
    )
  end

  defp backlog_query(:operator_events) do
    OperatorEvent
    |> where([row], is_nil(row.payload_purged_at))
    |> where(
      [row],
      fragment(
        "? IS DISTINCT FROM 1 OR ? IS NULL OR ? IS NULL OR ? IS DISTINCT FROM '{}'::jsonb OR ? IS DISTINCT FROM '{}'::jsonb OR ? IS DISTINCT FROM 1 OR ? IS NULL OR octet_length(?) IS DISTINCT FROM 32",
        row.payload_encryption_version,
        row.payload,
        row.metadata,
        row.legacy_payload,
        row.legacy_metadata,
        row.payload_binding_version,
        row.payload_binding_key_tag,
        row.payload_binding_mac
      )
    )
  end

  defp backlog_query(:user_memory_profiles) do
    UserMemoryProfile
    |> where([row], is_nil(row.content_erased_at))
    |> where(
      [row],
      fragment(
        "? IS DISTINCT FROM 1 OR ? IS NULL OR ? IS NULL OR ? IS DISTINCT FROM ? OR ? IS DISTINCT FROM '{}'::jsonb OR ? IS DISTINCT FROM 1 OR ? IS NULL OR octet_length(?) IS DISTINCT FROM 32",
        row.payload_encryption_version,
        row.summary,
        row.profile,
        row.legacy_summary,
        ^UserMemoryProfile.legacy_tombstone(),
        row.legacy_profile,
        row.payload_binding_version,
        row.payload_binding_key_tag,
        row.payload_binding_mac
      )
    )
  end

  defp backlog_query(:operator_memory_summaries) do
    OperatorMemorySummary
    |> where([row], is_nil(row.content_erased_at))
    |> where(
      [row],
      fragment(
        "? IS DISTINCT FROM 1 OR ? IS NULL OR ? IS DISTINCT FROM ? OR ? IS DISTINCT FROM 1 OR ? IS NULL OR octet_length(?) IS DISTINCT FROM 32",
        row.payload_encryption_version,
        row.content,
        row.legacy_content,
        ^OperatorMemorySummary.legacy_tombstone(),
        row.payload_binding_version,
        row.payload_binding_key_tag,
        row.payload_binding_mac
      )
    )
  end

  defp backlog_query(:background_jobs) do
    BackgroundJob
    |> where([row], is_nil(row.payload_purged_at))
    |> where(
      [row],
      fragment(
        "? IS DISTINCT FROM 1 OR ? IS NULL OR ? IS NULL OR ? IS DISTINCT FROM '{}'::jsonb OR ? IS DISTINCT FROM '{}'::jsonb OR ? IS DISTINCT FROM 1 OR ? IS NULL OR octet_length(?) IS DISTINCT FROM 32",
        row.payload_encryption_version,
        row.payload,
        row.result,
        row.legacy_payload,
        row.legacy_result,
        row.payload_binding_version,
        row.payload_binding_key_tag,
        row.payload_binding_mac
      )
    )
  end

  defp backlog_query(:scheduled_jobs) do
    ScheduledJob
    |> where([row], is_nil(row.payload_purged_at))
    |> where(
      [row],
      fragment(
        "? IS DISTINCT FROM 1 OR ? IS NULL OR ? IS DISTINCT FROM '{}'::jsonb OR ? IS NULL OR ? IS DISTINCT FROM 1 OR ? IS NULL OR octet_length(?) IS DISTINCT FROM 32",
        row.payload_encryption_version,
        row.payload,
        row.legacy_payload,
        row.payload_empty,
        row.payload_binding_version,
        row.payload_binding_key_tag,
        row.payload_binding_mac
      )
    )
  end

  defp backlog_query(:ingress_receipts) do
    IngressReceipt
    |> where([row], is_nil(row.payload_purged_at))
    |> where(
      [row],
      fragment(
        "? IS DISTINCT FROM 1 OR ? IS NULL OR ? IS DISTINCT FROM '{}'::jsonb OR ? IS DISTINCT FROM 1 OR ? IS NULL OR octet_length(?) IS DISTINCT FROM 32",
        row.payload_encryption_version,
        row.payload,
        row.legacy_payload,
        row.payload_binding_version,
        row.payload_binding_key_tag,
        row.payload_binding_mac
      )
    )
  end

  defp backlog_query(:agent_work_results) do
    AgentWorkResult
    |> where([row], is_nil(row.result_purged_at))
    |> where(
      [row],
      fragment(
        "? IS DISTINCT FROM 1 OR ? IS NULL OR ? IS DISTINCT FROM '{}'::jsonb OR ? IS DISTINCT FROM 1 OR ? IS DISTINCT FROM 1 OR ? IS NULL OR octet_length(?) IS DISTINCT FROM 32",
        row.payload_encryption_version,
        row.result,
        row.legacy_result,
        row.result_digest_version,
        row.payload_binding_version,
        row.payload_binding_key_tag,
        row.payload_binding_mac
      )
    )
  end

  defp deferred_query(query, :assistant_runs),
    do: where(query, [row], row.status in ^@active_run_statuses)

  defp deferred_query(query, :assistant_steps),
    do: where(query, [row], row.status == "running")

  defp deferred_query(query, :agent_runs),
    do: where(query, [row], row.status == "running")

  defp deferred_query(query, :background_jobs),
    do: where(query, [row], row.status in ["pending", "running"])

  defp deferred_query(query, :agent_work_results),
    do: where(query, [row], row.status == "provisional")

  defp deferred_query(query, _family), do: where(query, [row], row.id != row.id)

  defmacrop pg_size(field), do: quote(do: fragment("pg_column_size(?)", unquote(field)))

  defmacrop octet_length(field), do: quote(do: fragment("octet_length(?)", unquote(field)))

  defp blocked_query(query, :turns) do
    where(
      query,
      [row],
      octet_length(row.legacy_text) > 64_000 or pg_size(row.legacy_structured_data) > 160_000 or
        octet_length(row.text) > 70_000 or octet_length(row.structured_data) > 200_000
    )
  end

  defp blocked_query(query, :conversations) do
    where(
      query,
      [row],
      octet_length(row.legacy_summary) > 32_000 or pg_size(row.metadata) > 128_000 or
        octet_length(row.summary) > 40_000 or octet_length(row.historical_summary) > 40_000
    )
  end

  defp blocked_query(query, :assistant_runs) do
    where(
      query,
      [row],
      pg_size(row.legacy_prompt_snapshot) > 640_000 or
        pg_size(row.legacy_result_summary) > 256_000 or
        octet_length(row.prompt_snapshot) > 700_000 or
        octet_length(row.result_summary) > 300_000
    )
  end

  defp blocked_query(query, :assistant_steps) do
    where(
      query,
      [row],
      pg_size(row.legacy_request_payload) > 256_000 or
        pg_size(row.legacy_response_payload) > 640_000 or
        octet_length(row.request_payload) > 300_000 or
        octet_length(row.response_payload) > 700_000
    )
  end

  defp blocked_query(query, :prepared_actions) do
    where(
      query,
      [row],
      pg_size(row.legacy_payload) > 512_000 or octet_length(row.legacy_preview_text) > 4_000 or
        octet_length(row.payload) > 600_000 or octet_length(row.preview_text) > 12_000
    )
  end

  defp blocked_query(query, :agent_runs) do
    where(
      query,
      [row],
      pg_size(row.legacy_trigger) > 256_000 or pg_size(row.legacy_metadata) > 128_000 or
        octet_length(row.trigger) > 300_000 or octet_length(row.metadata) > 160_000
    )
  end

  defp blocked_query(query, :operator_events) do
    where(
      query,
      [row],
      pg_size(row.legacy_payload) > 384_000 or pg_size(row.legacy_metadata) > 128_000 or
        octet_length(row.payload) > 430_000 or octet_length(row.metadata) > 160_000
    )
  end

  defp blocked_query(query, :user_memory_profiles) do
    where(
      query,
      [row],
      octet_length(row.legacy_summary) > 32_000 or pg_size(row.legacy_profile) > 128_000 or
        octet_length(row.summary) > 40_000 or octet_length(row.profile) > 160_000
    )
  end

  defp blocked_query(query, :operator_memory_summaries) do
    where(
      query,
      [row],
      octet_length(row.legacy_content) > 32_000 or octet_length(row.content) > 40_000
    )
  end

  defp blocked_query(query, :background_jobs) do
    where(
      query,
      [row],
      pg_size(row.legacy_payload) > 384_000 or pg_size(row.legacy_result) > 384_000 or
        octet_length(row.payload) > 430_000 or octet_length(row.result) > 430_000
    )
  end

  defp blocked_query(query, :scheduled_jobs) do
    where(
      query,
      [row],
      pg_size(row.legacy_payload) > 256_000 or octet_length(row.payload) > 300_000
    )
  end

  defp blocked_query(query, :ingress_receipts) do
    where(
      query,
      [row],
      pg_size(row.legacy_payload) > 128_000 or octet_length(row.payload) > 160_000
    )
  end

  defp blocked_query(query, :agent_work_results) do
    where(
      query,
      [row],
      pg_size(row.legacy_result) > 128_000 or octet_length(row.result) > 160_000
    )
  end

  defp migrate_rows(family, ids) do
    Enum.reduce(ids, {0, []}, fn id, {migrated, blocked} ->
      try do
        row = family |> schema_for_family() |> Repo.get!(id)
        :ok = contract_row!(family, row)
        {migrated + 1, blocked}
      rescue
        _error -> {migrated, [%{id: id, failure: :payload_schema_invalid} | blocked]}
      catch
        :exit, _reason -> {migrated, [%{id: id, failure: :payload_schema_invalid} | blocked]}
      end
    end)
    |> then(fn {count, blocked} -> {count, Enum.reverse(blocked)} end)
  end

  defp schema_for_family(:turns), do: Turn
  defp schema_for_family(:conversations), do: Conversation
  defp schema_for_family(:assistant_runs), do: Run
  defp schema_for_family(:assistant_steps), do: Step
  defp schema_for_family(:prepared_actions), do: PreparedAction
  defp schema_for_family(:agent_runs), do: AgentRun
  defp schema_for_family(:operator_events), do: OperatorEvent
  defp schema_for_family(:user_memory_profiles), do: UserMemoryProfile
  defp schema_for_family(:operator_memory_summaries), do: OperatorMemorySummary
  defp schema_for_family(:background_jobs), do: BackgroundJob
  defp schema_for_family(:scheduled_jobs), do: ScheduledJob
  defp schema_for_family(:ingress_receipts), do: IngressReceipt
  defp schema_for_family(:agent_work_results), do: AgentWorkResult

  defp contract_row!(:turns, row) do
    hydrated = Turn.hydrate(row, :legacy)

    row
    |> Turn.changeset(%{text: hydrated.text, structured_data: hydrated.structured_data})
    |> Ecto.Changeset.force_change(:legacy_text, Turn.legacy_text_tombstone())
    |> Ecto.Changeset.force_change(:legacy_structured_data, %{})
    |> preserve_updated_at(row)
    |> update_contracted!()
  end

  defp contract_row!(:conversations, row) do
    hydrated = Conversation.hydrate(row, :legacy)
    metadata = Map.delete(hydrated.metadata || %{}, "historical_summary")

    row
    |> Conversation.changeset(%{
      summary: hydrated.summary,
      historical_summary: hydrated.historical_summary,
      metadata: metadata
    })
    |> Ecto.Changeset.force_change(:legacy_summary, nil)
    |> Ecto.Changeset.force_change(:metadata, metadata)
    |> preserve_updated_at(row)
    |> update_contracted!()
  end

  defp contract_row!(:assistant_runs, row) do
    hydrated = Run.hydrate_payloads(row, :legacy)

    row
    |> Run.changeset(%{
      prompt_snapshot: hydrated.prompt_snapshot,
      result_summary: hydrated.result_summary
    })
    |> Ecto.Changeset.force_change(:legacy_prompt_snapshot, %{})
    |> Ecto.Changeset.force_change(:legacy_result_summary, %{})
    |> preserve_updated_at(row)
    |> update_contracted!()
  end

  defp contract_row!(:assistant_steps, row) do
    hydrated = Step.hydrate_payloads(row, :legacy)

    row
    |> Step.changeset(%{
      request_payload: hydrated.request_payload,
      response_payload: hydrated.response_payload
    })
    |> Ecto.Changeset.force_change(:legacy_request_payload, %{})
    |> Ecto.Changeset.force_change(:legacy_response_payload, %{})
    |> preserve_updated_at(row)
    |> update_contracted!()
  end

  defp contract_row!(:prepared_actions, row) do
    hydrated = PreparedAction.hydrate_payload(row, :legacy)

    row
    |> PreparedAction.changeset(%{
      payload: hydrated.payload,
      preview_text: hydrated.preview_text
    })
    |> Ecto.Changeset.force_change(:legacy_payload, %{})
    |> Ecto.Changeset.force_change(:legacy_preview_text, nil)
    |> preserve_updated_at(row)
    |> update_contracted!()
  end

  defp contract_row!(:agent_runs, row) do
    hydrated = AgentRun.hydrate_private_payloads(row, :legacy)

    row
    |> AgentRun.changeset(%{
      trigger: hydrated.trigger,
      metadata: hydrated.metadata,
      budget_snapshot: hydrated.budget_snapshot
    })
    |> Ecto.Changeset.force_change(:legacy_trigger, %{})
    |> Ecto.Changeset.force_change(:legacy_metadata, %{})
    |> Ecto.Changeset.force_change(:legacy_budget_snapshot, %{})
    |> preserve_updated_at(row)
    |> update_contracted!()
  end

  defp contract_row!(:operator_events, row) do
    hydrated = OperatorEvent.hydrate_payloads(row, :legacy)

    row
    |> OperatorEvent.changeset(%{payload: hydrated.payload, metadata: hydrated.metadata})
    |> Ecto.Changeset.force_change(:legacy_payload, %{})
    |> Ecto.Changeset.force_change(:legacy_metadata, %{})
    |> preserve_updated_at(row)
    |> update_contracted!()
  end

  defp contract_row!(:user_memory_profiles, row) do
    hydrated = UserMemoryProfile.hydrate_content(row, :legacy)

    row
    |> UserMemoryProfile.changeset(%{summary: hydrated.summary, profile: hydrated.profile})
    |> Ecto.Changeset.force_change(:legacy_summary, UserMemoryProfile.legacy_tombstone())
    |> Ecto.Changeset.force_change(:legacy_profile, %{})
    |> preserve_updated_at(row)
    |> update_contracted!()
  end

  defp contract_row!(:operator_memory_summaries, row) do
    hydrated = OperatorMemorySummary.hydrate_content(row, :legacy)

    row
    |> OperatorMemorySummary.changeset(%{content: hydrated.content})
    |> Ecto.Changeset.force_change(:legacy_content, OperatorMemorySummary.legacy_tombstone())
    |> preserve_updated_at(row)
    |> update_contracted!()
  end

  defp contract_row!(:background_jobs, row) do
    hydrated = BackgroundJob.hydrate_payloads(row, :legacy)

    row
    |> BackgroundJob.changeset(%{payload: hydrated.payload, result: hydrated.result})
    |> Ecto.Changeset.force_change(:legacy_payload, %{})
    |> Ecto.Changeset.force_change(:legacy_result, %{})
    |> preserve_updated_at(row)
    |> update_contracted!()
  end

  defp contract_row!(:scheduled_jobs, row) do
    hydrated = ScheduledJob.hydrate_payload(row, :legacy)

    row
    |> ScheduledJob.changeset(%{payload: hydrated.payload})
    |> Ecto.Changeset.force_change(:legacy_payload, %{})
    |> preserve_updated_at(row)
    |> update_contracted!()
  end

  defp contract_row!(:ingress_receipts, row) do
    hydrated = IngressReceipt.hydrate_payload(row, :legacy)

    row
    |> IngressReceipt.changeset(%{payload: hydrated.payload})
    |> Ecto.Changeset.force_change(:legacy_payload, %{})
    |> update_contracted!()
  end

  defp contract_row!(:agent_work_results, row) do
    hydrated = AgentWorkResult.hydrate_result(row, :legacy)

    row
    |> AgentWorkResult.changeset(%{result: hydrated.result})
    |> Ecto.Changeset.force_change(:legacy_result, %{})
    |> preserve_updated_at(row)
    |> update_contracted!()
  end

  defp preserve_updated_at(changeset, %{updated_at: updated_at}),
    do: Ecto.Changeset.force_change(changeset, :updated_at, updated_at)

  defp update_contracted!(changeset) do
    case Repo.update(changeset) do
      {:ok, _row} -> :ok
      {:error, _changeset} -> raise "durable payload contraction validation failed"
    end
  end

  defp eligible_conversations(cutoff) do
    active_run =
      from run in Run,
        where:
          run.conversation_id == parent_as(:conversation).id and
            (is_nil(run.finished_at) or run.status in ^@active_run_statuses),
        select: 1

    active_run_linked_by_turn =
      from run in Run,
        join: turn in Turn,
        on: turn.assistant_run_id == run.id,
        where:
          turn.conversation_id == parent_as(:conversation).id and
            (is_nil(run.finished_at) or run.status in ^@active_run_statuses),
        select: 1

    pending_action =
      from action in PreparedAction,
        where:
          action.conversation_id == parent_as(:conversation).id and
            (is_nil(action.status) or action.status not in ^@terminal_action_statuses),
        select: 1

    pending_action_linked_by_turn =
      from action in PreparedAction,
        join: turn in Turn,
        on: turn.prepared_action_id == action.id,
        where:
          turn.conversation_id == parent_as(:conversation).id and
            (is_nil(action.status) or action.status not in ^@terminal_action_statuses),
        select: 1

    active_todo_linked_by_turn =
      from todo in Todo,
        join: turn in Turn,
        on: turn.linked_todo_id == todo.id,
        where:
          turn.conversation_id == parent_as(:conversation).id and
            (is_nil(todo.status) or todo.status not in ^@terminal_todo_statuses),
        select: 1

    active_todo_linked_by_conversation =
      from todo in Todo,
        where:
          (is_nil(todo.status) or todo.status not in ^@terminal_todo_statuses) and
            (fragment(
               "?::text = ?->>'linked_todo_id'",
               todo.id,
               parent_as(:conversation).metadata
             ) or
               fragment(
                 "? = 'todo:' || ?::text",
                 parent_as(:conversation).root_message_id,
                 todo.id
               )),
        select: 1

    needs_turn_scrub =
      from turn in Turn,
        where:
          turn.conversation_id == parent_as(:conversation).id and
            is_nil(turn.content_scrubbed_at) and turn.inserted_at < ^cutoff,
        select: 1

    from conversation in Conversation,
      as: :conversation,
      where: conversation.status == "closed",
      where:
        fragment(
          "COALESCE(?, ?) < ?",
          conversation.last_turn_at,
          conversation.updated_at,
          ^cutoff
        ),
      where: not exists(subquery(active_run)),
      where: not exists(subquery(active_run_linked_by_turn)),
      where: not exists(subquery(pending_action)),
      where: not exists(subquery(pending_action_linked_by_turn)),
      where: not exists(subquery(active_todo_linked_by_turn)),
      where: not exists(subquery(active_todo_linked_by_conversation)),
      where: is_nil(conversation.content_scrubbed_at) or exists(subquery(needs_turn_scrub))
  end

  defp lock_unscrubbed_turn_ids([], _cutoff, _limit), do: []

  defp lock_unscrubbed_turn_ids(conversation_ids, cutoff, limit) do
    Turn
    |> where([turn], turn.conversation_id in ^conversation_ids)
    |> where([turn], is_nil(turn.content_scrubbed_at) and turn.inserted_at < ^cutoff)
    |> order_by([turn], asc: turn.inserted_at, asc: turn.id)
    |> select([turn], turn.id)
    |> limit(^limit)
    |> lock("FOR UPDATE SKIP LOCKED")
    |> Repo.all()
  end

  defp scrub_turn_ids([], _now), do: 0

  defp scrub_turn_ids(turn_ids, now) do
    {count, _rows} =
      Turn
      |> where([turn], turn.id in ^turn_ids and is_nil(turn.content_scrubbed_at))
      |> Repo.update_all(
        set: [
          text: nil,
          legacy_text: Turn.legacy_text_tombstone(),
          structured_data: nil,
          legacy_structured_data: %{},
          payload_binding_version: nil,
          payload_binding_key_tag: nil,
          payload_binding_mac: nil,
          content_scrubbed_at: now
        ]
      )

    count
  end

  defp scrub_conversation_summaries(conversations, now) do
    ids =
      conversations
      |> Enum.filter(&is_nil(&1.content_scrubbed_at))
      |> Enum.map(& &1.id)

    if ids == [] do
      0
    else
      {count, _rows} =
        from(conversation in Conversation,
          where: conversation.id in ^ids and is_nil(conversation.content_scrubbed_at),
          update: [
            set: [
              summary: nil,
              legacy_summary: nil,
              historical_summary: nil,
              metadata: fragment("? - 'historical_summary'", conversation.metadata),
              payload_binding_version: nil,
              payload_binding_key_tag: nil,
              payload_binding_mac: nil,
              content_scrubbed_at: ^now
            ]
          ]
        )
        |> Repo.update_all([])

      count
    end
  end

  defp batch_size(opts) do
    opts
    |> Keyword.get(:batch_size, Keyword.get(opts, :limit, @default_batch_size))
    |> positive_integer(@default_batch_size)
    |> min(@max_batch_size)
  end

  defp bounded_max_batches(value),
    do: value |> positive_integer(@default_max_batches) |> min(@max_batches)

  defp positive_integer(value, _default) when is_integer(value) and value > 0, do: value

  defp positive_integer(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} when parsed > 0 -> parsed
      _other -> default
    end
  end

  defp positive_integer(_value, default), do: default
end
