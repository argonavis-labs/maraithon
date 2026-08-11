defmodule Maraithon.PrivacyErasure do
  @moduledoc """
  Durable, bounded erasure coordination for users and Agents.

  PostgreSQL rows are the only authority. Requests and work are idempotent,
  every worker generation is claim-token fenced against the database clock,
  and expired claims are reclaimable. Agent authority is removed exclusively
  through `Maraithon.Runtime.delete_agent/1`; raw SQL is limited to credentials
  and non-authoritative copies so unreadable ciphertext cannot prevent erasure.
  """

  import Ecto.Query

  alias Maraithon.Accounts.User
  alias Maraithon.Accounts.ConnectedAccount
  alias Maraithon.Agents.Agent
  alias Maraithon.OAuth.Token
  alias Maraithon.Privacy.ErasureAgentTarget
  alias Maraithon.Privacy.ErasureProviderRevocation
  alias Maraithon.Privacy.ErasureReceipt
  alias Maraithon.Privacy.ErasureRequest
  alias Maraithon.Repo
  alias Maraithon.Runtime
  alias Maraithon.Runtime.BackgroundJob
  alias Maraithon.Runtime.BackgroundJobs
  alias Maraithon.Runtime.DatabaseClock

  alias Maraithon.Runtime.Coordination.{
    NodeIncarnation,
    Protocol,
    Session,
    TaskAssignment,
    TaskClaims
  }

  @job_type "privacy_erasure"
  @queue "privacy"
  @dedupe_prefix "privacy-erasure:"
  @default_claim_ttl_ms 60_000
  @default_copy_batch 100
  @max_batch 500
  @receipt_ttl_seconds 90 * 24 * 60 * 60
  @conversation_privacy_migration 20_260_810_140_002
  @reschedule_ms 1_000

  # These rows can authenticate a device or receive private output. They are
  # destroyed in the same transaction that publishes the user fence.
  @immediate_user_tables [
    "companion_device_keys",
    "companion_devices",
    "mobile_node_pairings",
    "mobile_node_devices",
    "mobile_push_devices",
    "user_magic_links",
    "user_sessions"
  ]

  # Non-authoritative Agent references not covered by an ON DELETE CASCADE in
  # every supported schema generation. Effect/Directive/Run authority is
  # intentionally absent: Runtime.delete_agent/1 owns those rows.
  @agent_cleanup_tables [
    "action_ledger_actions",
    "agent_work_result_acquisitions",
    "chief_projection_receipts",
    "project_implementation_runs",
    "runtime_incidents",
    "source_cursor_advancements"
  ]

  # Complete fixed proof surface for Agent identifiers. Coordinator rows are
  # checked separately and removed only in the final receipt transaction.
  @agent_proof_specs [
    {"action_ledger_actions", "agent_id"},
    {"agent_directives", "agent_id"},
    {"agent_isolation_bindings", "agent_id"},
    {"agent_isolation_sessions", "agent_id"},
    {"agent_lifecycle_operations", "agent_id"},
    {"agent_restart_guards", "agent_id"},
    {"agent_run_steps", "agent_id"},
    {"agent_runs", "agent_id"},
    {"agent_runtime_leases", "agent_id"},
    {"agent_subscriptions", "agent_id"},
    {"agent_work_result_acquisitions", "agent_id"},
    {"agent_work_results", "agent_id"},
    {"agents", "id"},
    {"briefs", "agent_id"},
    {"chief_acquisition_runs", "agent_id"},
    {"chief_decisions", "agent_id"},
    {"chief_projection_receipts", "agent_id"},
    {"chief_semantic_effects", "agent_id"},
    {"effects", "agent_id"},
    {"events", "agent_id"},
    {"insights", "agent_id"},
    {"project_implementation_runs", "agent_id"},
    {"runtime_incidents", "agent_id"},
    {"runtime_ingress_receipts", "agent_id"},
    {"scheduled_jobs", "agent_id"},
    {"snapshot_quarantines", "agent_id"},
    {"snapshots", "agent_id"},
    {"source_cursor_advancements", "agent_id"},
    {"travel_itineraries", "agent_id"}
  ]

  # Child-first, fixed deletion plan for user/domain copies. Agent execution
  # authority is deliberately excluded and is proven absent below.
  @user_copy_specs [
    {:update_null, "project_repo_grants", "granted_by_user_id"},
    {:update_null, "todos", "owner_user_id"},
    {:delete, "action_ledger_actions", "user_id"},
    {:delete, "agent_isolation_sessions", "user_id"},
    {:delete, "agent_isolation_bindings", "user_id"},
    {:delete, "agent_subscriptions", "user_id"},
    {:delete, "background_jobs", "user_id"},
    {:delete, "briefs", "user_id"},
    {:delete, "commitments", "user_id"},
    {:delete, "companion_device_keys", "user_id"},
    {:delete, "companion_devices", "user_id"},
    {:delete, "control_calls", "user_id"},
    {:delete, "crm_observations", "user_id"},
    {:delete, "crm_person_merges", "user_id"},
    {:delete, "crm_person_links", "user_id"},
    {:delete, "local_contacts", "user_id"},
    {:delete, "crm_ingest_windows", "user_id"},
    {:delete, "crm_people", "user_id"},
    {:delete, "goal_links", "user_id"},
    {:delete, "goal_progress_updates", "user_id"},
    {:delete, "goal_review_runs", "user_id"},
    {:delete, "goals", "user_id"},
    {:delete, "insight_preference_rule_events", "user_id"},
    {:delete, "telegram_prepared_actions", "user_id"},
    {:delete, "telegram_push_receipts", "user_id"},
    {:delete, "telegram_assistant_runs", "user_id"},
    {:delete, "telegram_conversations", "user_id"},
    {:delete, "insight_deliveries", "user_id"},
    {:delete, "insight_preference_profiles", "user_id"},
    {:delete, "insight_preference_rules", "user_id"},
    {:delete, "insight_threshold_profiles", "user_id"},
    {:delete, "insights", "user_id"},
    {:delete, "local_browser_visits", "user_id"},
    {:delete, "local_calendar_events", "user_id"},
    {:delete, "local_files", "user_id"},
    {:delete, "local_messages", "user_id"},
    {:delete, "local_notes", "user_id"},
    {:delete, "local_reminders", "user_id"},
    {:delete, "local_voice_memos", "user_id"},
    {:delete, "memory_events", "user_id"},
    {:delete, "memory_items", "user_id"},
    {:delete, "mobile_node_pairings", "user_id"},
    {:delete, "mobile_node_devices", "user_id"},
    {:delete, "mobile_push_devices", "user_id"},
    {:delete, "operator_events", "user_id"},
    {:delete, "operator_memory_summaries", "user_id"},
    {:delete, "proactive_candidates", "user_id"},
    {:delete, "proactive_planner_user_cursors", "user_id"},
    {:delete, "project_implementation_runs", "user_id"},
    {:delete, "project_items", "user_id"},
    {:delete, "project_recommendation_decisions", "user_id"},
    {:delete, "project_repo_grants", "user_id"},
    {:delete, "projects", "user_id"},
    {:delete, "source_cursors", "user_id"},
    {:delete, "todo_activity_events", "user_id"},
    {:delete, "todo_staleness_batches", "user_id"},
    {:delete, "todos", "user_id"},
    {:delete, "travel_itineraries", "user_id"},
    {:delete, "user_calendar_links", "user_id"},
    {:delete, "user_identity_profiles", "user_id"},
    {:delete, "user_magic_links", "user_id"},
    {:delete, "user_memory_profiles", "user_id"},
    {:delete, "user_scheduled_task_runs", "user_id"},
    {:delete, "user_scheduled_tasks", "user_id"},
    {:delete, "user_sessions", "user_id"},
    {:delete, "agent_packages", "owner_user_id"}
  ]

  # Rows in this set are execution authority or lineage. They must disappear
  # through the proven Agent/credential cascades, never a user-id raw delete.
  @user_authority_specs [
    {"agents", "user_id"},
    {"agent_directives", "user_id"},
    {"agent_runs", "user_id"},
    {"agent_work_results", "user_id"},
    {"agent_work_result_acquisitions", "user_id"},
    {"chief_acquisition_envelopes", "user_id"},
    {"chief_acquisition_runs", "user_id"},
    {"chief_decisions", "user_id"},
    {"chief_projection_receipts", "user_id"},
    {"chief_semantic_effects", "user_id"},
    {"chief_source_envelopes", "user_id"},
    {"effects", "owner_user_id"},
    {"runtime_ingress_receipts", "user_id"},
    {"source_cursor_advancements", "user_id"}
  ]

  @doc "Atomically fences and requests complete erasure for one user."
  def request_user(user_or_id, opts \\ [])

  def request_user(%User{id: user_id}, opts), do: request_user(user_id, opts)

  def request_user(user_id, opts) when is_binary(user_id) and is_list(opts) do
    with {:ok, digest} <- idempotency_digest("user", user_id, opts) do
      Repo.transaction(fn ->
        protocol = Protocol.locked_pair!()
        request_user_locked!(user_id, digest, protocol)
      end)
      |> normalize_transaction()
    end
  end

  def request_user(_user_id, _opts), do: {:error, :invalid_erasure_request}

  @doc "Requests erasure of one Agent without deleting its owning user."
  def request_agent(agent_id, opts \\ [])

  def request_agent(agent_id, opts) when is_binary(agent_id) and is_list(opts) do
    with {:ok, agent_id} <- cast_uuid(agent_id),
         {:ok, digest} <- idempotency_digest("agent", agent_id, opts) do
      Repo.transaction(fn ->
        case Protocol.locked_pair!() do
          :exact -> request_agent_locked!(agent_id, digest, opts)
          :legacy -> Repo.rollback(:exact_runtime_required_for_agent_erasure)
        end
      end)
      |> normalize_transaction()
    end
  end

  def request_agent(_agent_id, _opts), do: {:error, :invalid_erasure_request}

  @doc "Returns a content-free progress projection for a request ID."
  def status(request_id) when is_binary(request_id) do
    with {:ok, request_id} <- cast_uuid(request_id),
         %ErasureRequest{} = request <- Repo.get(ErasureRequest, request_id) do
      {:ok, serialize_status(request)}
    else
      nil -> {:error, :not_found}
      {:error, _reason} -> {:error, :not_found}
    end
  end

  def status(_request_id), do: {:error, :not_found}

  @doc "Returns the active authenticated-user request, if any."
  def status_for_user(user_id) when is_binary(user_id) do
    case Repo.one(
           from(request in ErasureRequest,
             where: request.scope == "user",
             where: request.subject_user_id == ^user_id,
             where: request.state != "completed",
             order_by: [desc: request.requested_at],
             limit: 1
           )
         ) do
      %ErasureRequest{} = request -> {:ok, serialize_status(request)}
      nil -> {:ok, nil}
    end
  end

  def status_for_user(_user_id), do: {:error, :invalid_user}

  @doc "Claims and advances at most one bounded state-machine unit."
  def perform(request_id, opts \\ [])

  def perform(request_id, opts) when is_binary(request_id) and is_list(opts) do
    with {:ok, request_id} <- cast_uuid(request_id),
         {:ok, claim_ttl_ms, copy_batch} <- perform_opts(opts) do
      case claim(request_id, claim_ttl_ms) do
        {:ok, request} -> advance(request, copy_batch)
        {:busy, request} -> {:ok, Map.put(serialize_status(request), :busy, true)}
        {:completed, request} -> {:ok, serialize_status(request)}
        {:error, _reason} = error -> error
      end
    end
  end

  def perform(_request_id, _opts), do: {:error, :invalid_erasure_request}

  @doc "Repairs a bounded page of active requests whose durable job disappeared."
  def discover_missing_jobs(limit \\ 50)

  def discover_missing_jobs(limit) when is_integer(limit) and limit in 1..@max_batch do
    Repo.transaction(fn ->
      ids =
        Repo.query!(
          """
          SELECT request.id
          FROM privacy_erasure_requests AS request
          WHERE request.state <> 'completed'
            AND NOT EXISTS (
              SELECT 1
              FROM background_jobs AS job
              WHERE job.dedupe_key = $1 || request.id::text
                AND job.status IN ('pending', 'running')
            )
          ORDER BY request.last_attempted_at NULLS FIRST, request.requested_at, request.id
          FOR UPDATE OF request SKIP LOCKED
          LIMIT $2
          """,
          [@dedupe_prefix, limit],
          log: false
        ).rows
        |> Enum.map(fn row -> row |> List.first() |> load_uuid!() end)

      Enum.each(ids, &enqueue_locked!/1)
      %{repaired: length(ids)}
    end)
    |> normalize_transaction()
  end

  def discover_missing_jobs(_limit), do: {:error, :invalid_limit}

  @doc false
  def job_type, do: @job_type

  @doc false
  def reschedule_ms, do: @reschedule_ms

  defp request_user_locked!(user_id, digest, protocol) do
    user =
      Repo.one(from(user in User, where: user.id == ^user_id, lock: "FOR UPDATE")) ||
        Repo.rollback(:user_not_found)

    if protocol != :exact and Repo.exists?(from(agent in Agent, where: agent.user_id == ^user_id)) do
      Repo.rollback(:exact_runtime_required_for_agent_erasure)
    end

    now = DatabaseClock.now!()

    request =
      lock_active_request("user", :subject_user_id, user_id) ||
        insert_request!(%{
          scope: "user",
          subject_user_id: user_id,
          idempotency_digest: digest,
          state: "requested",
          requested_at: now,
          target_agent_count: 0
        })

    set_erasure_context!(request.id, protocol)

    if is_nil(user.privacy_erasure_requested_at) do
      user
      |> Ecto.Changeset.change(privacy_erasure_requested_at: now, updated_at: now)
      |> Repo.update!()
    end

    revoke_immediate_user_access!(user_id, now)
    snapshot_user_agents!(request.id, user_id, now)
    snapshot_credentials!(request.id, user_id, now)

    target_count =
      Repo.aggregate(
        from(target in ErasureAgentTarget, where: target.request_id == ^request.id),
        :count
      )

    request =
      request
      |> Ecto.Changeset.change(target_agent_count: target_count, updated_at: now)
      |> Repo.update!()

    enqueue_locked!(request.id)
    request
  end

  defp request_agent_locked!(agent_id, digest, opts) do
    observed_agent = Repo.get(Agent, agent_id) || Repo.rollback(:agent_not_found)
    expected_user_id = Keyword.get(opts, :user_id)
    validate_agent_owner!(observed_agent, expected_user_id)
    lock_agent_user!(observed_agent.user_id)

    agent =
      Repo.one(from(candidate in Agent, where: candidate.id == ^agent_id, lock: "FOR UPDATE")) ||
        Repo.rollback(:agent_not_found)

    if agent.user_id != observed_agent.user_id, do: Repo.rollback(:agent_owner_changed)
    validate_agent_owner!(agent, expected_user_id)

    now = DatabaseClock.now!()

    request =
      lock_active_request("agent", :subject_agent_id, agent_id) ||
        insert_request!(%{
          scope: "agent",
          subject_agent_id: agent_id,
          idempotency_digest: digest,
          state: "requested",
          requested_at: now,
          target_agent_count: 1
        })

    insert_target!(request.id, agent_id, now)
    enqueue_locked!(request.id)
    request
  end

  defp validate_agent_owner!(_agent, nil), do: :ok

  defp validate_agent_owner!(%Agent{user_id: user_id}, expected_user_id) do
    if user_id != expected_user_id, do: Repo.rollback(:agent_not_found)
  end

  defp lock_agent_user!(user_id) when is_binary(user_id) do
    case Repo.one(from(user in User, where: user.id == ^user_id, lock: "FOR UPDATE")) do
      %User{privacy_erasure_requested_at: nil} -> :ok
      %User{} -> Repo.rollback(:privacy_erasure_requested)
      nil -> Repo.rollback(:user_not_found)
    end
  end

  defp lock_agent_user!(nil), do: :ok

  defp lock_active_request(scope, field, subject) do
    Repo.one(
      from(request in ErasureRequest,
        where: request.scope == ^scope,
        where: field(request, ^field) == ^subject,
        where: request.state != "completed",
        lock: "FOR UPDATE"
      )
    )
  end

  defp insert_request!(attrs) do
    %ErasureRequest{}
    |> ErasureRequest.changeset(attrs)
    |> Repo.insert!()
  end

  defp insert_target!(request_id, agent_id, now) do
    Repo.insert_all(
      ErasureAgentTarget,
      [
        %{
          request_id: request_id,
          agent_id: agent_id,
          state: "pending",
          inserted_at: now,
          updated_at: now
        }
      ],
      on_conflict: :nothing,
      conflict_target: [:request_id, :agent_id]
    )

    :ok
  end

  defp snapshot_user_agents!(request_id, user_id, now) do
    rows =
      Repo.all(
        from(agent in Agent,
          where: agent.user_id == ^user_id,
          order_by: [asc: agent.id],
          select: agent.id
        )
      )
      |> Enum.map(fn agent_id ->
        %{
          request_id: request_id,
          agent_id: agent_id,
          state: "pending",
          inserted_at: now,
          updated_at: now
        }
      end)

    if rows != [] do
      Repo.insert_all(ErasureAgentTarget, rows,
        on_conflict: :nothing,
        conflict_target: [:request_id, :agent_id]
      )
    end

    :ok
  end

  defp snapshot_credentials!(request_id, user_id, now) do
    Enum.each([{"oauth_tokens", "oauth_tokens"}, {"connected_accounts", "connected_accounts"}], fn
      {table, credential_table} ->
        Repo.query!(
          """
          INSERT INTO privacy_erasure_provider_revocations
            (request_id, credential_table, credential_row_id, provider_code, state,
             attempt_count, inserted_at, updated_at)
          SELECT $1, $2, credential.id,
                 left(CASE WHEN btrim(credential.provider) = '' THEN 'unknown'
                           ELSE btrim(credential.provider) END, 80),
                 'pending', 0, $4, $4
          FROM #{table} AS credential
          WHERE credential.user_id = $3
          ON CONFLICT (request_id, credential_table, credential_row_id) DO NOTHING
          """,
          [dump_uuid!(request_id), credential_table, user_id, now],
          log: false
        )
    end)

    :ok
  end

  defp revoke_immediate_user_access!(user_id, now) do
    # Revoke durable jobs before deleting the authentication/device rows. A
    # running generation loses its job claim and cannot persist a result.
    Repo.query!(
      """
      UPDATE background_jobs
      SET status = 'cancelled', claimed_by = NULL, claimed_at = NULL,
          claim_token = NULL, cancelled_at = $2, updated_at = $2
      WHERE user_id = $1 AND status = 'pending'
        AND coordination_task_assignment_id IS NULL
        AND claim_token IS NULL
      """,
      [user_id, now],
      log: false
    )

    Enum.each(@immediate_user_tables, fn table ->
      Repo.query!("DELETE FROM #{table} WHERE user_id = $1", [user_id], log: false)
    end)

    :ok
  end

  defp enqueue_locked!(request_id) do
    case BackgroundJobs.enqueue(@job_type, %{
           queue: @queue,
           dedupe_key: @dedupe_prefix <> request_id,
           max_attempts: 25,
           payload: %{"request_id" => request_id},
           scheduled_at: DatabaseClock.now!()
         }) do
      {:ok, %BackgroundJob{} = job} -> job
      {:error, reason} -> Repo.rollback({:privacy_job_enqueue_failed, reason})
    end
  end

  defp claim(request_id, ttl_ms) do
    Repo.transaction(fn ->
      request =
        Repo.one(
          from(request in ErasureRequest,
            where: request.id == ^request_id,
            where: request.state != "completed",
            where:
              is_nil(request.claim_token) or
                request.claim_expires_at <= fragment("timezone('UTC', clock_timestamp())"),
            lock: "FOR UPDATE SKIP LOCKED"
          )
        )

      case request do
        %ErasureRequest{} ->
          {now, expires_at} = DatabaseClock.window!(ttl_ms)
          token = Ecto.UUID.generate()

          request
          |> Ecto.Changeset.change(%{
            claim_token: token,
            claimed_at: now,
            claim_expires_at: expires_at,
            last_attempted_at: now,
            updated_at: now
          })
          |> Repo.update!()

        nil ->
          nil
      end
    end)
    |> case do
      {:ok, %ErasureRequest{} = request} ->
        {:ok, request}

      {:ok, nil} ->
        case Repo.get(ErasureRequest, request_id) do
          %ErasureRequest{state: "completed"} = request -> {:completed, request}
          %ErasureRequest{} = request -> {:busy, request}
          nil -> {:error, :not_found}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp advance(%ErasureRequest{state: "requested"} = request, _batch) do
    release_claim(request, state: "draining", blocker_code: nil)
  end

  defp advance(%ErasureRequest{state: "draining"} = request, batch) do
    case next_target(request.id) do
      %ErasureAgentTarget{} = target -> process_agent_target(request, target, batch)
      nil -> transition_after_agents(request)
    end
  end

  defp advance(%ErasureRequest{state: "revoking_credentials"} = request, _batch) do
    process_credentials(request)
  end

  defp advance(%ErasureRequest{state: "erasing", scope: "user"} = request, batch) do
    erase_user_copies(request, batch)
  end

  defp advance(%ErasureRequest{state: "erasing", scope: "agent"} = request, _batch) do
    finalize_agent_request(request)
  end

  defp advance(%ErasureRequest{state: "completed"} = request, _batch) do
    {:ok, serialize_status(request)}
  end

  defp next_target(request_id) do
    Repo.one(
      from(target in ErasureAgentTarget,
        where: target.request_id == ^request_id,
        where: target.state != "drained",
        order_by: [asc: target.last_attempted_at, asc: target.id],
        limit: 1
      )
    )
  end

  defp process_agent_target(request, target, batch) do
    with :ok <- mark_target_attempt(request, target, "draining") do
      result =
        case Repo.exists?(from(agent in Agent, where: agent.id == ^target.agent_id)) do
          true ->
            Runtime.delete_agent(target.agent_id,
              privacy_erasure_request_id: request.id
            )

          false ->
            :ok
        end

      case result do
        :ok ->
          finish_agent_target(request, target, batch)

        {:error, :not_found} ->
          finish_agent_target(request, target, batch)

        {:error, reason} ->
          defer_agent_target(request, target, agent_blocker(target.agent_id, reason))
      end
    end
  rescue
    _error -> defer_agent_target(request, target, "agent_lifecycle_unavailable")
  catch
    :exit, _reason -> defer_agent_target(request, target, "agent_lifecycle_unavailable")
  end

  defp finish_agent_target(request, target, batch) do
    case cleanup_agent_copies(request, target.agent_id, batch) do
      :clean ->
        now = DatabaseClock.now!()

        Repo.transaction(fn ->
          _owned = lock_owned_request!(request)

          Repo.update_all(
            from(candidate in ErasureAgentTarget,
              where: candidate.id == ^target.id,
              where: candidate.request_id == ^request.id
            ),
            set: [
              state: "drained",
              blocker_code: nil,
              drained_at: now,
              last_attempted_at: now,
              updated_at: now
            ]
          )
        end)

        release_claim(request, blocker_code: nil)

      :pending ->
        defer_agent_target(request, target, "agent_copy_cleanup_pending", "erasing")
    end
  end

  defp cleanup_agent_copies(request, agent_id, batch) do
    Repo.transaction(fn ->
      _owned = lock_owned_request!(request)

      Enum.reduce_while(@agent_cleanup_tables, :clean, fn table, _acc ->
        count = delete_batch(table, "agent_id", dump_uuid!(agent_id), batch)

        if count > 0, do: {:halt, :pending}, else: {:cont, :clean}
      end)
    end)
    |> case do
      {:ok, result} -> result
      {:error, _reason} -> :pending
    end
  end

  defp mark_target_attempt(request, target, state) do
    now = DatabaseClock.now!()

    Repo.transaction(fn ->
      _owned = lock_owned_request!(request)

      {count, _rows} =
        Repo.update_all(
          from(candidate in ErasureAgentTarget,
            where: candidate.id == ^target.id,
            where: candidate.request_id == ^request.id
          ),
          set: [state: state, last_attempted_at: now, updated_at: now]
        )

      if count == 1, do: :ok, else: Repo.rollback(:target_lost)
    end)
    |> case do
      {:ok, :ok} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp defer_agent_target(request, target, blocker, state \\ "draining") do
    now = DatabaseClock.now!()

    _ =
      Repo.update_all(
        from(candidate in ErasureAgentTarget,
          where: candidate.id == ^target.id,
          where: candidate.request_id == ^request.id
        ),
        set: [
          state: state,
          blocker_code: blocker,
          last_attempted_at: now,
          updated_at: now
        ]
      )

    release_claim(request, blocker_code: blocker)
  end

  defp agent_blocker(agent_id, _reason) do
    dumped_agent_id = dump_uuid!(agent_id)

    cond do
      row_exists?(
        "effects",
        "agent_id = $1 AND status IN ('claimed', 'cancelling')",
        [dumped_agent_id]
      ) ->
        "effect_termination_proof_required"

      row_exists?(
        "effects",
        "agent_id = $1 AND status NOT IN ('pending','claimed','cancelling','completed','failed','cancelled')",
        [dumped_agent_id]
      ) ->
        "effect_unknown_authority"

      row_exists?(
        "agent_lifecycle_operations",
        "agent_id = $1 AND requires_external_drain = TRUE AND external_drain_confirmed_at IS NULL",
        [dumped_agent_id]
      ) ->
        "operator_drain_proof_required"

      true ->
        "agent_drain_pending"
    end
  end

  defp transition_after_agents(%ErasureRequest{scope: "user"} = request) do
    release_claim(request, state: "revoking_credentials", blocker_code: nil)
  end

  defp transition_after_agents(%ErasureRequest{scope: "agent"} = request) do
    release_claim(request, state: "erasing", blocker_code: nil)
  end

  defp process_credentials(%ErasureRequest{subject_user_id: nil} = request) do
    release_claim(request, blocker_code: "user_subject_missing")
  end

  defp process_credentials(%ErasureRequest{subject_user_id: user_id} = request) do
    now = DatabaseClock.now!()

    _ =
      Repo.transaction(fn ->
        _owned = lock_owned_request!(request)
        snapshot_credentials!(request.id, user_id, now)
      end)

    case next_revocation(request.id) do
      %ErasureProviderRevocation{} = revocation ->
        process_revocation(request, revocation)

      nil ->
        if credentials_exist?(user_id) do
          release_claim(request, blocker_code: "credential_snapshot_pending")
        else
          release_claim(request,
            state: "erasing",
            blocker_code: nil,
            credentials_locally_revoked: true
          )
        end
    end
  end

  defp next_revocation(request_id) do
    Repo.one(
      from(revocation in ErasureProviderRevocation,
        where: revocation.request_id == ^request_id,
        where: revocation.state in ["pending", "failed"],
        order_by: [asc: revocation.last_attempted_at, asc: revocation.id],
        limit: 1
      )
    )
  end

  defp process_revocation(request, revocation) do
    outcome =
      case load_credential(revocation) do
        {:ok, provider, token} -> provider_revoker().revoke(provider, token)
        {:error, code} -> {:unavailable, code}
      end

    {state, error_code} =
      case outcome do
        :confirmed -> {"confirmed", nil}
        {:ok, :confirmed} -> {"confirmed", nil}
        {:unavailable, code} -> {"unavailable", normalize_provider_error(code)}
        {:error, code} -> {"unavailable", normalize_provider_error(code)}
        _other -> {"unavailable", "provider_unavailable"}
      end

    now = DatabaseClock.now!()

    case Repo.transaction(fn ->
           _owned = lock_owned_request!(request)
           delete_credential!(revocation.credential_table, revocation.credential_row_id)

           {count, _rows} =
             Repo.update_all(
               from(candidate in ErasureProviderRevocation,
                 where: candidate.id == ^revocation.id,
                 where: candidate.request_id == ^request.id
               ),
               set: [
                 state: state,
                 attempt_count: revocation.attempt_count + 1,
                 error_code: error_code,
                 last_attempted_at: now,
                 completed_at: now,
                 updated_at: now
               ]
             )

           if count == 1, do: :ok, else: Repo.rollback(:revocation_lost)
         end) do
      {:ok, :ok} -> release_claim(request, blocker_code: nil)
      {:error, _reason} -> {:error, :privacy_claim_lost}
    end
  end

  defp load_credential(%ErasureProviderRevocation{
         credential_table: "oauth_tokens",
         credential_row_id: id
       }) do
    case Repo.one(
           from(token in Token,
             where: token.id == ^id,
             select: {token.provider, token.access_token, token.refresh_token}
           )
         ) do
      {provider, access_token, refresh_token} ->
        credential_token(provider, access_token, refresh_token)

      nil ->
        {:error, :credential_missing}
    end
  rescue
    _error -> {:error, :credential_unreadable}
  end

  defp load_credential(%ErasureProviderRevocation{
         credential_table: "connected_accounts",
         credential_row_id: id
       }) do
    case Repo.one(
           from(account in ConnectedAccount,
             where: account.id == ^id,
             select: {account.provider, account.access_token, account.refresh_token}
           )
         ) do
      {provider, access_token, refresh_token} ->
        credential_token(provider, access_token, refresh_token)

      nil ->
        {:error, :credential_missing}
    end
  rescue
    _error -> {:error, :credential_unreadable}
  end

  defp load_credential(_revocation), do: {:error, :credential_unreadable}

  defp credential_token(provider, access_token, refresh_token) when is_binary(provider) do
    token =
      if String.starts_with?(provider, "google") do
        refresh_token || access_token
      else
        access_token || refresh_token
      end

    if is_binary(token) and token != "",
      do: {:ok, provider, token},
      else: {:error, :credential_unreadable}
  end

  defp credential_token(_provider, _access_token, _refresh_token),
    do: {:error, :credential_unreadable}

  defp provider_revoker do
    Application.get_env(:maraithon, __MODULE__, [])
    |> Keyword.get(:provider_revoker, Maraithon.PrivacyErasure.ProviderRevoker)
  end

  defp normalize_provider_error(code)
       when code in [
              :credential_missing,
              :credential_unreadable,
              :provider_not_configured,
              :provider_rejected,
              :provider_timeout,
              :provider_unavailable,
              :provider_unsupported
            ],
       do: Atom.to_string(code)

  defp normalize_provider_error(_code), do: "provider_unavailable"

  defp delete_credential!(table, id) when table in ["oauth_tokens", "connected_accounts"] do
    Repo.query!("DELETE FROM #{table} WHERE id = $1", [id], log: false)
    :ok
  end

  defp credentials_exist?(user_id) do
    row_exists?("oauth_tokens", "user_id = $1", [user_id]) or
      row_exists?("connected_accounts", "user_id = $1", [user_id])
  end

  defp erase_user_copies(%ErasureRequest{subject_user_id: nil} = request, _batch) do
    release_claim(request, blocker_code: "user_subject_missing")
  end

  defp erase_user_copies(%ErasureRequest{subject_user_id: user_id} = request, batch) do
    case erase_exact_conversation_batch(request, user_id, batch) do
      :ready -> erase_plain_user_copies(request, user_id, batch)
      {:pending, blocker} -> release_claim(request, blocker_code: blocker)
    end
  end

  defp erase_plain_user_copies(request, user_id, batch) do
    result =
      Repo.transaction(fn ->
        protocol = Protocol.locked_pair!()
        _owned = lock_owned_request!(request)
        set_erasure_context!(request.id, protocol)

        Enum.reduce_while(@user_copy_specs, :clean, fn spec, _acc ->
          count = mutate_user_copy_batch(spec, user_id, batch)

          if count > 0,
            do: {:halt, {:pending, copy_code(spec)}},
            else: {:cont, :clean}
        end)
      end)

    case result do
      {:ok, :clean} -> finalize_user_request(request)
      {:ok, {:pending, blocker}} -> release_claim(request, blocker_code: blocker)
      {:error, _reason} -> {:error, :user_copy_cleanup_failed}
    end
  end

  defp erase_exact_conversation_batch(request, user_id, batch) do
    with :ready <- drain_conversation_authority(request, user_id, batch),
         {:ok, protocol} <- erasure_protocol_pair() do
      case {protocol, conversation_erasure_adapter()} do
        {:legacy, _adapter} ->
          :ready

        {:exact, nil} ->
          {:pending, "conversation_adapter_unavailable"}

        {:exact, adapter} ->
          if Code.ensure_loaded?(adapter) and function_exported?(adapter, :erase_user_batch, 4) do
            now = DatabaseClock.now!()

            case adapter.erase_user_batch(user_id, request.id, request.claim_token,
                   limit: batch,
                   now: now
                 ) do
              {:ok, %{processed: processed, deferred: deferred}}
              when is_integer(processed) and processed >= 0 and is_map(deferred) ->
                cond do
                  processed > 0 -> {:pending, "conversation_copy_cleanup_pending"}
                  positive_count?(deferred) -> {:pending, "conversation_authority_deferred"}
                  true -> :ready
                end

              {:error, _reason} ->
                {:pending, "conversation_erasure_unavailable"}

              _invalid ->
                {:pending, "conversation_erasure_unavailable"}
            end
          else
            {:pending, "conversation_adapter_unavailable"}
          end
      end
    else
      {:pending, blocker} -> {:pending, blocker}
      {:error, _reason} -> {:pending, "conversation_erasure_unavailable"}
    end
  rescue
    _error -> {:pending, "conversation_erasure_unavailable"}
  catch
    :exit, _reason -> {:pending, "conversation_erasure_unavailable"}
  end

  defp erasure_protocol_pair do
    Repo.transaction(fn -> Protocol.locked_pair!() end)
  end

  defp conversation_erasure_adapter do
    config = Application.get_env(:maraithon, __MODULE__, [])
    configured_adapter = Keyword.get(config, :conversation_erasure_adapter)

    if migration_recorded?(@conversation_privacy_migration) or not is_nil(configured_adapter),
      do: configured_adapter || Module.concat(Maraithon.TelegramConversations, Privacy),
      else: nil
  end

  # The exact adapter intentionally defers active conversation authority. Move
  # only states with an unambiguous local cancellation outcome to terminal
  # states first; externally ambiguous prepared actions remain proof blockers.
  defp drain_conversation_authority(request, user_id, batch) do
    case request_background_job_terminations(request, user_id, batch) do
      {:pending, blocker} ->
        {:pending, blocker}

      :ready ->
        now = DatabaseClock.now!()

        case Repo.transaction(fn ->
               protocol = Protocol.locked_pair!()
               _owned = lock_owned_request!(request)

               set_erasure_context!(request.id, protocol)

               cond do
                 row_exists?(
                   "telegram_prepared_actions",
                   "user_id = $1 AND status IN ('confirmed','execution_unknown')",
                   [user_id]
                 ) ->
                   {:pending, "prepared_action_external_proof_required"}

                 cancel_background_job_batch(user_id, batch, now) > 0 ->
                   {:pending, "conversation_background_job_drain_pending"}

                 reject_prepared_action_batch(user_id, batch, now) > 0 ->
                   {:pending, "prepared_action_drain_pending"}

                 fail_assistant_step_batch(user_id, batch, now) > 0 ->
                   {:pending, "assistant_step_drain_pending"}

                 cancel_assistant_run_batch(user_id, batch, now) > 0 ->
                   {:pending, "assistant_run_drain_pending"}

                 close_conversation_batch(user_id, batch, now) > 0 ->
                   {:pending, "conversation_close_pending"}

                 true ->
                   :ready
               end
             end) do
          {:ok, result} -> result
          {:error, _reason} -> {:pending, "conversation_authority_drain_unavailable"}
        end
    end
  end

  defp request_background_job_terminations(request, user_id, batch) do
    termination_limit = min(batch, 16)
    _ = TaskClaims.reconcile_proven(termination_limit)

    result =
      Repo.transaction(fn ->
        _owned = lock_owned_request!(request)

        rows =
          Repo.all(
            from assignment in TaskAssignment,
              join: job in BackgroundJob,
              on:
                assignment.work_kind == "background_job" and
                  assignment.work_id == job.id,
              join: node in NodeIncarnation,
              on: node.id == assignment.node_incarnation_id,
              where: job.user_id == ^user_id,
              where: job.status in ["pending", "running"],
              where: assignment.state in ["reserved", "running", "termination_requested"],
              order_by: assignment.id,
              limit: ^termination_limit,
              lock: "FOR UPDATE SKIP LOCKED",
              select: {assignment, node.node_name}
          )

        Enum.map(rows, fn {assignment, node_name} ->
          requested =
            if assignment.state == "termination_requested" do
              assignment
            else
              case TaskClaims.request_termination(assignment) do
                {:ok, requested} -> requested
                {:error, reason} -> Repo.rollback(reason)
              end
            end

          {requested.id, node_name}
        end)
      end)

    case result do
      {:ok, []} ->
        if row_exists?("background_jobs", "user_id = $1 AND status = 'running'", [user_id]),
          do: {:pending, "conversation_background_job_termination_unproven"},
          else: :ready

      {:ok, assignments} ->
        assignments
        |> Task.async_stream(
          fn {assignment_id, node_name} ->
            terminate_background_job_assignment(node_name, assignment_id)
          end,
          max_concurrency: 16,
          ordered: false,
          timeout: 3_000,
          on_timeout: :kill_task
        )
        |> Stream.run()

        {:pending, "conversation_background_job_termination_pending"}

      {:error, _reason} ->
        {:pending, "conversation_background_job_termination_unavailable"}
    end
  rescue
    _error -> {:pending, "conversation_background_job_termination_unavailable"}
  catch
    :exit, _reason -> {:pending, "conversation_background_job_termination_unavailable"}
  end

  defp terminate_background_job_assignment(node_name, assignment_id) do
    case Enum.find([node() | Node.list()], &(Atom.to_string(&1) == node_name)) do
      nil ->
        {:unknown, :task_node_unreachable}

      target_node when target_node == node() ->
        Session.terminate_background_job_assignment(assignment_id)

      target_node ->
        :rpc.call(
          target_node,
          Session,
          :terminate_background_job_assignment,
          [assignment_id],
          2_500
        )
    end
  end

  defp cancel_background_job_batch(user_id, batch, now) do
    Repo.query!(
      """
      UPDATE background_jobs AS target
      SET status = 'cancelled', claimed_by = NULL, claimed_at = NULL,
          claim_token = NULL, cancelled_at = $3, updated_at = $3
      WHERE target.id IN (
        SELECT candidate.id
        FROM background_jobs AS candidate
        WHERE candidate.user_id = $1
          AND candidate.status = 'pending'
          AND candidate.coordination_task_assignment_id IS NULL
          AND candidate.claim_token IS NULL
        ORDER BY candidate.id
        LIMIT $2
        FOR UPDATE SKIP LOCKED
      )
      """,
      [user_id, batch, now],
      log: false
    ).num_rows
  end

  defp reject_prepared_action_batch(user_id, batch, now) do
    Repo.query!(
      """
      UPDATE telegram_prepared_actions AS target
      SET status = 'rejected', updated_at = $3
      WHERE target.id IN (
        SELECT candidate.id
        FROM telegram_prepared_actions AS candidate
        WHERE candidate.user_id = $1 AND candidate.status = 'awaiting_confirmation'
        ORDER BY candidate.id
        LIMIT $2
        FOR UPDATE SKIP LOCKED
      )
      """,
      [user_id, batch, now],
      log: false
    ).num_rows
  end

  defp fail_assistant_step_batch(user_id, batch, now) do
    Repo.query!(
      """
      UPDATE telegram_assistant_steps AS target
      SET status = 'failed', finished_at = COALESCE(finished_at, $3), updated_at = $3
      WHERE target.id IN (
        SELECT step.id
        FROM telegram_assistant_steps AS step
        INNER JOIN telegram_assistant_runs AS run ON run.id = step.run_id
        WHERE run.user_id = $1 AND step.status = 'running'
        ORDER BY step.id
        LIMIT $2
        FOR UPDATE OF step SKIP LOCKED
      )
      """,
      [user_id, batch, now],
      log: false
    ).num_rows
  end

  defp cancel_assistant_run_batch(user_id, batch, now) do
    Repo.query!(
      """
      UPDATE telegram_assistant_runs AS target
      SET status = 'cancelled', finished_at = COALESCE(finished_at, $3), updated_at = $3
      WHERE target.id IN (
        SELECT candidate.id
        FROM telegram_assistant_runs AS candidate
        WHERE candidate.user_id = $1
          AND candidate.status IN ('queued','running','waiting_confirmation')
        ORDER BY candidate.id
        LIMIT $2
        FOR UPDATE SKIP LOCKED
      )
      """,
      [user_id, batch, now],
      log: false
    ).num_rows
  end

  defp close_conversation_batch(user_id, batch, now) do
    Repo.query!(
      """
      UPDATE telegram_conversations AS target
      SET status = 'closed', updated_at = $3
      WHERE target.id IN (
        SELECT conversation.id
        FROM telegram_conversations AS conversation
        WHERE conversation.user_id = $1 AND conversation.status <> 'closed'
          AND NOT EXISTS (
            SELECT 1 FROM telegram_assistant_runs AS run
            WHERE run.conversation_id = conversation.id
              AND run.status IN ('queued','running','waiting_confirmation')
          )
          AND NOT EXISTS (
            SELECT 1 FROM telegram_prepared_actions AS action
            WHERE action.conversation_id = conversation.id
              AND action.status NOT IN ('executed','rejected','expired','failed')
          )
        ORDER BY conversation.id
        LIMIT $2
        FOR UPDATE SKIP LOCKED
      )
      """,
      [user_id, batch, now],
      log: false
    ).num_rows
  end

  defp set_erasure_context!(request_id, :exact) do
    Repo.query!(
      """
      SELECT set_config('maraithon.privacy_erasure_request_id', $1, true),
             set_config('maraithon.effect_writer_protocol', 'generation_fenced_v1', true)
      """,
      [request_id],
      log: false
    )

    :ok
  end

  defp set_erasure_context!(request_id, :legacy) do
    Repo.query!(
      "SELECT set_config('maraithon.privacy_erasure_request_id', $1, true)",
      [request_id],
      log: false
    )

    :ok
  end

  defp migration_recorded?(version) do
    case Repo.query!(
           "SELECT EXISTS (SELECT 1 FROM schema_migrations WHERE version = $1)",
           [version],
           log: false
         ).rows do
      [[true]] -> true
      _missing -> false
    end
  end

  defp positive_count?(counts) do
    Enum.any?(counts, fn
      {_family, count} when is_integer(count) and count > 0 -> true
      _other -> false
    end)
  end

  defp mutate_user_copy_batch({:delete, table, column}, user_id, batch) do
    delete_batch(table, column, user_id, batch)
  end

  defp mutate_user_copy_batch({:update_null, table, column}, user_id, batch) do
    %{num_rows: count} =
      Repo.query!(
        """
        UPDATE #{table}
        SET #{column} = NULL
        WHERE ctid IN (
          SELECT ctid FROM #{table}
          WHERE #{column} = $1
          ORDER BY ctid
          FOR UPDATE SKIP LOCKED
          LIMIT $2
        )
        """,
        [user_id, batch],
        log: false
      )

    count
  end

  defp delete_batch(table, column, value, batch) do
    %{num_rows: count} =
      Repo.query!(
        """
        DELETE FROM #{table}
        WHERE ctid IN (
          SELECT ctid FROM #{table}
          WHERE #{column} = $1
          ORDER BY ctid
          FOR UPDATE SKIP LOCKED
          LIMIT $2
        )
        """,
        [value, batch],
        log: false
      )

    count
  end

  defp copy_code({_operation, table, _column}) do
    "copy_" <> String.replace(table, ~r/[^a-z0-9_]/, "")
  end

  defp finalize_user_request(%ErasureRequest{subject_user_id: user_id} = request) do
    Repo.transaction(fn ->
      user =
        Repo.one(from(user in User, where: user.id == ^user_id, lock: "FOR UPDATE")) ||
          Repo.rollback(:user_subject_missing)

      owned = lock_owned_request!(request)

      if is_nil(user.privacy_erasure_requested_at),
        do: Repo.rollback(:user_erasure_fence_lost)

      prove_user_clean!(owned, user_id)
      finalize_locked!(owned, user_id)
    end)
    |> case do
      {:ok, completed} -> {:ok, serialize_status(completed)}
      {:error, reason} -> release_after_finalization_failure(request, reason)
    end
  end

  defp finalize_agent_request(request) do
    Repo.transaction(fn ->
      owned = lock_owned_request!(request)
      targets = lock_targets(owned.id)

      if targets == [] and owned.target_agent_count > 0 do
        # Older schemas cascade coordinator rows. The policy migration removes
        # that FK; fail-closed proof is possible only with retained targets.
        if is_binary(owned.subject_agent_id),
          do: Repo.rollback(:agent_target_proof_missing)
      end

      Enum.each(targets, fn target ->
        if target.state != "drained", do: Repo.rollback(:agent_drain_pending)
        prove_agent_clean!(target.agent_id)
      end)

      finalize_locked!(owned, nil)
    end)
    |> case do
      {:ok, completed} -> {:ok, serialize_status(completed)}
      {:error, reason} -> release_after_finalization_failure(request, reason)
    end
  end

  defp prove_user_clean!(request, user_id) do
    if credentials_exist?(user_id), do: Repo.rollback(:credential_copy_remaining)

    Enum.each(@user_copy_specs, fn {_operation, table, column} ->
      if row_exists?(table, "#{column} = $1", [user_id]),
        do: Repo.rollback(:user_copy_remaining)
    end)

    Enum.each(@user_authority_specs, fn {table, column} ->
      if row_exists?(table, "#{column} = $1", [user_id]),
        do: Repo.rollback(:user_authority_remaining)
    end)

    targets = lock_targets(request.id)

    Enum.each(targets, fn target ->
      if target.state != "drained", do: Repo.rollback(:agent_drain_pending)
      prove_agent_clean!(target.agent_id)
    end)

    :ok
  end

  defp prove_agent_clean!(agent_id) do
    dumped_agent_id = dump_uuid!(agent_id)

    Enum.each(@agent_proof_specs, fn {table, column} ->
      if row_exists?(table, "#{column} = $1", [dumped_agent_id]),
        do: Repo.rollback(:agent_copy_remaining)
    end)
  end

  defp lock_targets(request_id) do
    Repo.all(
      from(target in ErasureAgentTarget,
        where: target.request_id == ^request_id,
        order_by: [asc: target.id],
        lock: "FOR UPDATE"
      )
    )
  end

  defp finalize_locked!(request, user_id) do
    now = DatabaseClock.now!()
    expires_at = DateTime.add(now, @receipt_ttl_seconds, :second)
    _targets = lock_targets(request.id)
    provider_outcome = provider_outcome(request)

    if is_binary(user_id) do
      {deleted, _rows} = Repo.delete_all(from(user in User, where: user.id == ^user_id))
      if deleted != 1, do: Repo.rollback(:user_subject_missing)
    end

    Repo.delete_all(from(target in ErasureAgentTarget, where: target.request_id == ^request.id))

    %ErasureReceipt{
      request_id: request.id,
      classification: "content_free_erasure_authority_v1",
      scope: request.scope,
      outcome: "completed",
      local_data_deleted: true,
      credentials_locally_revoked: request.credentials_locally_revoked,
      provider_revocation_outcome: provider_outcome,
      erased_agent_count: request.target_agent_count,
      issued_at: now,
      expires_at: expires_at,
      inserted_at: now
    }
    |> Repo.insert!()

    {count, _rows} =
      Repo.update_all(
        from(candidate in ErasureRequest,
          where: candidate.id == ^request.id,
          where: candidate.claim_token == ^request.claim_token
        ),
        set: [
          state: "completed",
          subject_user_id: nil,
          subject_agent_id: nil,
          idempotency_digest: nil,
          blocker_code: nil,
          claim_token: nil,
          claimed_at: nil,
          claim_expires_at: nil,
          completed_at: now,
          expires_at: expires_at,
          last_attempted_at: now,
          updated_at: now
        ]
      )

    if count != 1, do: Repo.rollback(:privacy_claim_lost)
    Repo.get!(ErasureRequest, request.id)
  end

  defp provider_outcome(%ErasureRequest{scope: "agent"}), do: "not_applicable"

  defp provider_outcome(%ErasureRequest{} = request) do
    states =
      Repo.all(
        from(revocation in ErasureProviderRevocation,
          where: revocation.request_id == ^request.id,
          select: revocation.state
        )
      )

    cond do
      states == [] -> "not_applicable"
      Enum.all?(states, &(&1 == "confirmed")) -> "confirmed"
      true -> "partial_unverified"
    end
  end

  defp release_after_finalization_failure(request, reason) do
    blocker =
      case reason do
        :agent_drain_pending -> "agent_drain_pending"
        :agent_target_proof_missing -> "agent_target_proof_missing"
        :agent_copy_remaining -> "agent_copy_remaining"
        :credential_copy_remaining -> "credential_copy_remaining"
        :user_authority_remaining -> "user_authority_remaining"
        :user_copy_remaining -> "user_copy_remaining"
        :user_erasure_fence_lost -> "user_erasure_fence_lost"
        :user_subject_missing -> "user_subject_missing"
        _other -> "finalization_proof_failed"
      end

    release_claim(request, blocker_code: blocker)
  end

  defp release_claim(request, attrs) do
    now = DatabaseClock.now!()

    allowed =
      attrs
      |> Keyword.take([:state, :blocker_code, :credentials_locally_revoked])
      |> Keyword.merge(
        claim_token: nil,
        claimed_at: nil,
        claim_expires_at: nil,
        last_attempted_at: now,
        updated_at: now
      )

    case Repo.update_all(
           from(candidate in ErasureRequest,
             where: candidate.id == ^request.id,
             where: candidate.claim_token == ^request.claim_token,
             where: candidate.state != "completed"
           ),
           set: allowed
         ) do
      {1, _rows} -> {:ok, request.id |> then(&Repo.get(ErasureRequest, &1)) |> serialize_status()}
      {0, _rows} -> {:error, :privacy_claim_lost}
    end
  end

  defp lock_owned_request!(request) do
    Repo.one(
      from(candidate in ErasureRequest,
        where: candidate.id == ^request.id,
        where: candidate.claim_token == ^request.claim_token,
        where: candidate.state != "completed",
        lock: "FOR UPDATE"
      )
    ) || Repo.rollback(:privacy_claim_lost)
  end

  defp serialize_status(%ErasureRequest{} = request) do
    target_counts =
      Repo.all(
        from(target in ErasureAgentTarget,
          where: target.request_id == ^request.id,
          group_by: target.state,
          select: {target.state, count(target.id)}
        )
      )
      |> Map.new()

    receipt = Repo.get_by(ErasureReceipt, request_id: request.id)

    %{
      request_id: request.id,
      scope: request.scope,
      state: request.state,
      blocker_code: request.blocker_code,
      target_agent_count: request.target_agent_count,
      pending_agent_count:
        Enum.reduce(target_counts, 0, fn
          {"drained", _count}, acc -> acc
          {_state, count}, acc -> acc + count
        end),
      requested_at: request.requested_at,
      completed_at: request.completed_at,
      provider_revocation_outcome:
        if(receipt, do: receipt.provider_revocation_outcome, else: nil),
      receipt: serialize_receipt(receipt)
    }
  end

  defp serialize_receipt(nil), do: nil

  defp serialize_receipt(%ErasureReceipt{} = receipt) do
    %{
      classification: receipt.classification,
      scope: receipt.scope,
      outcome: receipt.outcome,
      local_data_deleted: receipt.local_data_deleted,
      credentials_locally_revoked: receipt.credentials_locally_revoked,
      provider_revocation_outcome: receipt.provider_revocation_outcome,
      erased_agent_count: receipt.erased_agent_count,
      issued_at: receipt.issued_at,
      expires_at: receipt.expires_at
    }
  end

  defp row_exists?(table, predicate, params) do
    case Repo.query!(
           "SELECT EXISTS (SELECT 1 FROM #{table} WHERE #{predicate} LIMIT 1)",
           params,
           log: false
         ).rows do
      [[true]] -> true
      _ -> false
    end
  end

  defp idempotency_digest(scope, subject, opts) do
    if Keyword.keyword?(opts) and
         Enum.all?(Keyword.keys(opts), &(&1 in [:idempotency_key, :user_id])) do
      key = Keyword.get(opts, :idempotency_key, "default")

      if is_binary(key) and byte_size(key) in 1..512 and String.valid?(key) do
        {:ok, :crypto.hash(:sha256, [scope, <<0>>, subject, <<0>>, key])}
      else
        {:error, :invalid_idempotency_key}
      end
    else
      {:error, :invalid_erasure_request}
    end
  end

  defp perform_opts(opts) do
    claim_ttl_ms = Keyword.get(opts, :claim_ttl_ms, @default_claim_ttl_ms)
    copy_batch = Keyword.get(opts, :copy_batch, @default_copy_batch)

    if Keyword.keyword?(opts) and
         Enum.all?(Keyword.keys(opts), &(&1 in [:claim_ttl_ms, :copy_batch])) and
         is_integer(claim_ttl_ms) and claim_ttl_ms in 1_000..300_000 and
         is_integer(copy_batch) and copy_batch in 1..@max_batch do
      {:ok, claim_ttl_ms, copy_batch}
    else
      {:error, :invalid_erasure_options}
    end
  end

  defp dump_uuid!(value), do: Ecto.UUID.dump!(value)
  defp load_uuid!(value), do: Ecto.UUID.load!(value)

  defp cast_uuid(value) do
    case Ecto.UUID.cast(value) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, :invalid_erasure_request}
    end
  end

  defp normalize_transaction({:ok, result}), do: {:ok, result}
  defp normalize_transaction({:error, reason}), do: {:error, reason}
end
