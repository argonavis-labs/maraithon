defmodule Maraithon.Agents do
  @moduledoc """
  Context for managing agent records in the database.
  """

  import Ecto.Query

  alias Maraithon.AgentBuilder
  alias Maraithon.AgentHarness.Manifest, as: HarnessManifest
  alias Maraithon.AgentHarness.MarkdownSkill
  alias Maraithon.AgentIsolation.Binding
  alias Maraithon.AgentSubscriptions
  alias Maraithon.DurablePayload
  alias Maraithon.Effects.Effect
  alias Maraithon.Projects
  alias Maraithon.PrivacyErasure.WriteFence
  alias Maraithon.Repo
  alias Maraithon.Runtime.AgentLeases
  alias Maraithon.Runtime.AgentLifecycleOperation
  alias Maraithon.Runtime.AgentRestartGuard
  alias Maraithon.Runtime.AgentRuntimeLease
  alias Maraithon.Runtime.Config, as: RuntimeConfig
  alias Maraithon.Runtime.DatabaseClock
  alias Maraithon.Agents.Agent
  alias Maraithon.Agents.AgentPackage
  alias Maraithon.Agents.AgentPackageVersion
  alias Maraithon.Agents.AgentRun
  alias Maraithon.Agents.AgentRunStep

  @agent_run_cancel_timeout_ms 2_000
  @closed_step_reason "agent_run_closed_without_step_result"
  @default_run_step_payload_purge_batch 100
  @max_run_step_payload_purge_batch 500
  @default_run_step_payload_backfill_batch 25
  @max_run_step_payload_backfill_batch 100
  @run_step_payload_backfill_timeout_ms 30_000
  @run_identity_fields [
    :agent_id,
    :user_id,
    :project_id,
    :agent_package_id,
    :agent_package_version_id,
    :behavior,
    :started_at,
    :completed_at
  ]
  @immutable_run_update_fields @run_identity_fields ++ [:trigger_type, :trigger]
  @step_identity_fields [:agent_id, :agent_run_id, :started_at, :completed_at]
  @immutable_step_update_fields @step_identity_fields ++
                                  [
                                    :sequence,
                                    :step_type,
                                    :tool_name,
                                    :effect_type,
                                    :request_payload
                                  ]

  @doc """
  List all agents.
  """
  def list_agents(opts \\ []) do
    user_id = Keyword.get(opts, :user_id)
    project_id = Keyword.get(opts, :project_id)
    preload = Keyword.get(opts, :preload, [])

    Agent
    |> maybe_filter_user(user_id)
    |> maybe_filter_project(project_id)
    |> maybe_filter_removed(Keyword.get(opts, :include_removed, false))
    |> order_by([agent], desc: agent.updated_at, desc: agent.inserted_at)
    |> Repo.all()
    |> Repo.preload(preload)
  end

  @doc """
  Get an agent by ID.
  """
  def get_agent(id, opts \\ []) do
    user_id = Keyword.get(opts, :user_id)
    preload = Keyword.get(opts, :preload, [])

    Agent
    |> maybe_filter_user(user_id)
    |> maybe_filter_removed(Keyword.get(opts, :include_removed, false))
    |> Repo.get(id)
    |> Repo.preload(preload)
  end

  @doc """
  Get an agent by ID, raising if not found.
  """
  def get_agent!(id) do
    Repo.get!(Agent, id)
  end

  def get_agent_for_user(id, user_id, opts \\ []) when is_binary(user_id) do
    preload = Keyword.get(opts, :preload, [])

    Agent
    |> where([agent], agent.id == ^id and agent.user_id == ^user_id)
    |> maybe_filter_removed(Keyword.get(opts, :include_removed, false))
    |> Repo.one()
    |> Repo.preload(preload)
  end

  @doc """
  Create a new agent record.
  """
  def create_agent(attrs \\ %{}) do
    Repo.transaction(fn ->
      user_id = attrs[:user_id] || attrs["user_id"]
      if is_binary(user_id), do: WriteFence.lock_user_writable!(user_id)

      with {:ok, agent} <-
             %Agent{}
             |> Agent.changeset(attrs)
             |> Repo.insert(),
           {:ok, _subscriptions} <- AgentSubscriptions.sync_for_agent(agent) do
        agent
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> case do
      {:ok, agent} -> {:ok, agent}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Update an agent record.
  """
  def update_agent(%Agent{} = agent, attrs) do
    Repo.transaction(fn ->
      with {:ok, updated_agent} <-
             agent
             |> Agent.changeset(attrs)
             |> Repo.update(),
           {:ok, _subscriptions} <- AgentSubscriptions.sync_for_agent(updated_agent) do
        updated_agent
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> case do
      {:ok, updated_agent} -> {:ok, updated_agent}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Delete an agent record.
  """
  def delete_agent(%Agent{} = agent) do
    Repo.delete(agent)
  end

  @doc """
  Soft-remove a user's installed agent package instance.
  """
  def remove_agent_installation(%Agent{} = agent) do
    update_agent(agent, %{
      install_status: "removed",
      status: "stopped",
      stopped_at: DateTime.utc_now(),
      removed_at: DateTime.utc_now()
    })
  end

  @doc """
  Pause an installed package agent without removing its configuration.
  """
  def pause_agent_installation(%Agent{} = agent) do
    update_agent(agent, %{
      install_status: "paused",
      status: "stopped",
      stopped_at: DateTime.utc_now()
    })
  end

  @doc """
  Resume a paused or setup-ready installed package agent.
  """
  def resume_agent_installation(%Agent{} = agent) do
    update_agent(agent, %{install_status: "enabled", removed_at: nil})
  end

  @doc """
  Upgrade an installed package agent to a package version.
  """
  def upgrade_agent_installation(%Agent{} = agent, %AgentPackageVersion{} = version) do
    if version.agent_package_id == agent.agent_package_id do
      config =
        agent.config
        |> Kernel.||(%{})
        |> Map.put("agent_package_version_id", version.id)

      update_agent(agent, %{
        behavior: version.behavior,
        agent_package_version_id: version.id,
        config: config
      })
    else
      {:error, :package_mismatch}
    end
  end

  def upgrade_agent_installation(%Agent{} = agent, version_id) when is_binary(version_id) do
    case get_agent_package_version(version_id) do
      nil -> {:error, :version_not_found}
      %AgentPackageVersion{} = version -> upgrade_agent_installation(agent, version)
    end
  end

  def upgrade_agent_installation_to_latest(%Agent{} = agent) do
    agent = Repo.preload(agent, [:agent_package])

    case agent.agent_package do
      %AgentPackage{} = package ->
        package = Repo.preload(package, [:latest_version], force: true)
        upgrade_agent_installation(agent, package.latest_version)

      _ ->
        {:error, :package_not_found}
    end
  end

  @doc """
  Create a durable execution record for one runtime cycle.
  """
  def start_agent_run(%Agent{} = agent, attrs \\ %{}) when is_map(attrs) do
    with :ok <-
           reject_immutable_update(attrs, @run_identity_fields, :immutable_agent_run_identity),
         {:ok, attrs} <- canonicalize_run_attrs(attrs),
         :ok <- validate_creation_status(attrs, "running", :invalid_agent_run_status) do
      Repo.transaction(fn ->
        {persisted_agent, operation} = lock_lifecycle_prefix!(agent.id)
        if operation, do: Repo.rollback(:agent_drain_pending)
        now = DatabaseClock.now!()

        %AgentRun{}
        |> AgentRun.changeset(agent_run_attrs(persisted_agent, attrs, now))
        |> insert_or_rollback()
      end)
    end
  end

  @doc false
  def start_exact_runtime_agent_run(%Agent{} = agent, owner_token, attrs \\ %{})
      when is_binary(owner_token) and is_map(attrs) do
    Repo.transaction(fn ->
      :ok = AgentLeases.fence_ready!(agent.id, owner_token)

      case start_runtime_agent_run(agent, attrs) do
        {:ok, run} -> run
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  @doc false
  def start_runtime_agent_run(%Agent{} = agent, attrs \\ %{}) when is_map(attrs) do
    with :ok <-
           reject_immutable_update(attrs, @run_identity_fields, :immutable_agent_run_identity),
         {:ok, attrs} <- canonicalize_run_attrs(attrs),
         :ok <- validate_creation_status(attrs, "running", :invalid_agent_run_status) do
      Repo.transaction(fn ->
        {persisted_agent, operation} = lock_lifecycle_prefix!(agent.id)
        if operation, do: Repo.rollback(:agent_drain_pending)

        case persisted_agent do
          %Agent{active_run_id: nil, status: status, install_status: "enabled"} = persisted_agent
          when status in ["running", "degraded"] ->
            now = DatabaseClock.now!()

            run =
              %AgentRun{}
              |> AgentRun.changeset(agent_run_attrs(persisted_agent, attrs, now))
              |> insert_or_rollback()

            {1, _rows} =
              Repo.update_all(
                from(stored_agent in Agent,
                  where: stored_agent.id == ^persisted_agent.id,
                  where: is_nil(stored_agent.active_run_id)
                ),
                set: [active_run_id: run.id, updated_at: now]
              )

            run

          %Agent{active_run_id: active_run_id} when is_binary(active_run_id) ->
            Repo.rollback(:active_agent_run_exists)

          %Agent{} ->
            Repo.rollback(:agent_not_runnable)
        end
      end)
    end
  end

  def complete_agent_run(run_id, attrs \\ %{}) when is_binary(run_id) and is_map(attrs) do
    with :ok <-
           reject_immutable_update(
             attrs,
             @immutable_run_update_fields,
             :immutable_agent_run_identity
           ),
         {:ok, attrs} <- canonicalize_run_attrs(attrs) do
      status = attrs["status"] || "completed"
      do_update_agent_run(run_id, Map.put(attrs, "status", status))
    end
  end

  def fail_agent_run(run_id, attrs \\ %{}) when is_binary(run_id) and is_map(attrs) do
    with :ok <-
           reject_immutable_update(
             attrs,
             @immutable_run_update_fields,
             :immutable_agent_run_identity
           ),
         {:ok, attrs} <- canonicalize_run_attrs(attrs) do
      do_update_agent_run(run_id, Map.put(attrs, "status", "failed"))
    end
  end

  @doc """
  Closes one exact run whose owning process is terminating.

  The run row is locked before requested child steps are failed. Already
  terminal runs and steps are never overwritten, and provider completion facts
  such as finish reason and generation mode are preserved.
  """
  def cancel_agent_run(run_id, agent_id, reason)
      when is_binary(run_id) and byte_size(run_id) in 1..255 and is_binary(agent_id) and
             byte_size(agent_id) in 1..255 and is_binary(reason) and
             byte_size(reason) in 1..255 do
    if valid_database_text?(run_id) and valid_database_text?(agent_id) and
         valid_database_text?(reason) do
      Repo.transaction(
        fn ->
          :ok = DurablePayload.require_current_mutation!()
          {_agent, _operation} = lock_lifecycle_prefix!(agent_id, :run_not_found)
          now = DatabaseClock.now!()

          run =
            AgentRun
            |> where([run], run.id == ^run_id and run.agent_id == ^agent_id)
            |> lock("FOR UPDATE")
            |> Repo.one()

          case run do
            nil ->
              Repo.rollback(:run_not_found)

            %AgentRun{status: "running"} = run ->
              step_count = close_requested_run_steps(run.id, reason, now)

              run =
                run
                |> AgentRun.changeset(%{
                  "status" => "cancelled",
                  "error" => run.error || reason,
                  "completed_at" => now
                })
                |> update_or_rollback()

              clear_active_run_pointer(run.agent_id, run.id, now)
              %{cancelled: true, run: run, steps: step_count}

            %AgentRun{} = run ->
              clear_active_run_pointer(run.agent_id, run.id, now)
              %{cancelled: false, run: run, steps: 0}
          end
        end,
        timeout: @agent_run_cancel_timeout_ms
      )
    else
      {:error, :invalid_agent_run_cancellation}
    end
  end

  def cancel_agent_run(_run_id, _agent_id, _reason),
    do: {:error, :invalid_agent_run_cancellation}

  def update_agent_run(run_id, attrs) when is_binary(run_id) and is_map(attrs) do
    with :ok <-
           reject_immutable_update(
             attrs,
             @immutable_run_update_fields,
             :immutable_agent_run_identity
           ),
         {:ok, attrs} <- canonicalize_run_attrs(attrs) do
      do_update_agent_run(run_id, attrs)
    end
  end

  defp do_update_agent_run(run_id, attrs) do
    status = attrs["status"]

    Repo.transaction(fn ->
      :ok = DurablePayload.require_current_mutation!()

      agent_id =
        Repo.one(from(run in AgentRun, where: run.id == ^run_id, select: run.agent_id)) ||
          Repo.rollback(:run_not_found)

      {_agent, _operation} = lock_lifecycle_prefix!(agent_id, :run_not_found)
      now = DatabaseClock.now!()

      attrs =
        if status in ["completed", "failed", "cancelled"] do
          attrs
          |> Map.put("status", status)
          |> Map.put("completed_at", now)
        else
          attrs
        end

      run =
        AgentRun
        |> where([run], run.id == ^run_id and run.agent_id == ^agent_id)
        |> lock("FOR UPDATE")
        |> Repo.one()

      case run do
        nil ->
          Repo.rollback(:run_not_found)

        %AgentRun{status: "running"} = run ->
          if status in ["completed", "failed", "cancelled"] do
            close_requested_run_steps(run.id, @closed_step_reason, now)
          end

          updated_run = run |> AgentRun.changeset(attrs) |> update_or_rollback()

          if status in ["completed", "failed", "cancelled"] do
            clear_active_run_pointer(run.agent_id, run.id, now)
          end

          updated_run

        %AgentRun{} = run ->
          Repo.rollback({:run_not_running, run.status})
      end
    end)
  end

  def list_agent_runs(agent_id, opts \\ []) when is_binary(agent_id) do
    preload = Keyword.get(opts, :preload, [])
    limit = Keyword.get(opts, :limit, 50)

    AgentRun
    |> where([run], run.agent_id == ^agent_id)
    |> order_by([run], desc: run.started_at)
    |> limit(^limit)
    |> Repo.all()
    |> Repo.preload(preload)
    |> Enum.map(&hydrate_run_step_payloads!/1)
  end

  @doc """
  Lists the latest durable OTP agent runs for one user.

  The result contains only user-safe scalar run and step headers. Private run,
  request, and response payloads are intentionally not loaded.
  """
  def list_recent_runs_for_user(user_id, opts \\ [])

  def list_recent_runs_for_user(user_id, opts)
      when is_binary(user_id) and is_list(opts) do
    limit = recent_run_limit(opts)

    runs =
      AgentRun
      |> join(:inner, [run], agent in Agent,
        on: agent.id == run.agent_id and agent.user_id == run.user_id
      )
      |> join(:left, [run, _agent], package in AgentPackage,
        on: package.id == run.agent_package_id
      )
      |> where([run, agent, _package], run.user_id == ^user_id and agent.user_id == ^user_id)
      |> order_by([run, _agent, _package], desc: run.started_at, desc: run.id)
      |> limit(^limit)
      |> select([run, _agent, package], %{
        id: run.id,
        agent_id: run.agent_id,
        package_name: package.name,
        behavior: run.behavior,
        status: run.status,
        trigger_type: run.trigger_type,
        budget_llm_calls: run.budget_llm_calls,
        budget_tool_calls: run.budget_tool_calls,
        error: run.error,
        started_at: run.started_at,
        completed_at: run.completed_at
      })
      |> Repo.all()

    steps_by_run = recent_run_step_headers(user_id, Enum.map(runs, & &1.id))

    Enum.map(runs, fn run ->
      Map.put(run, :steps, Map.get(steps_by_run, run.id, []))
    end)
  end

  def list_recent_runs_for_user(_user_id, _opts), do: []

  @doc """
  Returns eligible and deferred legacy AgentRunStep ciphertext backlog counts.

  Deferred rows are requested, belong to a running run, or belong to a run
  still pointed to as active. This preflight reads no payload content.
  """
  def legacy_run_step_payload_encryption_backlogs do
    %{rows: [[eligible, deferred]]} =
      Repo.query!(
        """
        SELECT
          COUNT(*) FILTER (
            WHERE steps.status IN ('completed', 'failed')
              AND steps.completed_at IS NOT NULL
              AND runs.status IN ('completed', 'failed', 'cancelled')
              AND runs.completed_at IS NOT NULL
              AND agents.active_run_id IS DISTINCT FROM runs.id
          )::bigint AS eligible,
          COUNT(*) FILTER (
            WHERE NOT (
              steps.status IN ('completed', 'failed')
              AND steps.completed_at IS NOT NULL
              AND runs.status IN ('completed', 'failed', 'cancelled')
              AND runs.completed_at IS NOT NULL
              AND agents.active_run_id IS DISTINCT FROM runs.id
            )
          )::bigint AS deferred
        FROM agent_run_steps AS steps
        JOIN agent_runs AS runs
          ON runs.id = steps.agent_run_id
         AND runs.agent_id = steps.agent_id
        JOIN agents
          ON agents.id = steps.agent_id
        WHERE steps.payload_purged_at IS NULL
          AND (
            steps.request_payload_ciphertext IS NULL
            OR steps.response_payload_ciphertext IS NULL
            OR steps.request_payload <> '{}'::jsonb
            OR steps.response_payload <> '{}'::jsonb
          )
        """,
        [],
        timeout: @run_step_payload_backfill_timeout_ms,
        log: false
      )

    %{eligible: eligible, deferred: deferred}
  end

  @doc false
  def legacy_run_step_payload_encryption_backlog,
    do: legacy_run_step_payload_encryption_backlogs().eligible

  @doc """
  Promotes one bounded batch of terminal, inactive AgentRunStep payloads.

  Candidate step rows use `FOR UPDATE ... SKIP LOCKED`; active/requested work is
  deferred, payload headers and timestamps are preserved, and plaintext JSONB
  is cleared only after both encrypted maps validate and persist. The result
  contains migrated counts and blocked IDs with closed error codes; deferred
  rows become eligible after their run closes.
  """
  def backfill_legacy_run_step_payload_encryption(opts \\ [])

  def backfill_legacy_run_step_payload_encryption(opts) when is_list(opts) do
    with {:ok, {limit, skip}} <- run_step_payload_backfill_options(opts) do
      Repo.transaction(
        fn ->
          :ok = DurablePayload.require_legacy_mutation!()
          :ok = Maraithon.DurablePayloadContraction.require_authorized!()
          step_ids = lock_legacy_run_step_payload_ids(limit, skip)

          steps =
            AgentRunStep
            |> where([step], step.id in ^step_ids)
            |> Repo.all(log: false)

          if length(steps) != length(step_ids) do
            Repo.rollback(:agent_run_step_payload_backfill_race)
          end

          Enum.reduce(
            steps,
            %{migrated_run_steps: 0, blocked_run_steps: []},
            fn step, result ->
              case promote_legacy_run_step_payloads(step) do
                :ok ->
                  %{result | migrated_run_steps: result.migrated_run_steps + 1}

                {:blocked, blocked} ->
                  %{result | blocked_run_steps: [blocked | result.blocked_run_steps]}
              end
            end
          )
          |> Map.update!(:blocked_run_steps, &Enum.reverse/1)
        end,
        timeout: @run_step_payload_backfill_timeout_ms
      )
    end
  end

  def backfill_legacy_run_step_payload_encryption(_opts),
    do: {:error, :invalid_agent_run_step_payload_backfill}

  @doc """
  Purges one bounded batch of terminal AgentRunStep payload bodies.

  A step is eligible only after both it and its parent run are terminal and
  older than `cutoff`, and only while no Agent points at that run as active.
  Step identity, sequence, status, timing, and other headers are preserved.
  Repeated calls returning `{:ok, count}` are suitable for a durable job.
  """
  def purge_agent_run_step_payloads_before(cutoff, opts \\ [])

  def purge_agent_run_step_payloads_before(%DateTime{} = cutoff, opts) when is_list(opts) do
    with :ok <- validate_run_step_retention_cutoff(cutoff),
         {:ok, limit} <- run_step_payload_purge_limit(opts) do
      Repo.transaction(fn ->
        :ok = DurablePayload.require_current_mutation!()

        candidate_ids =
          from(candidate in AgentRunStep,
            join: run in AgentRun,
            on: run.id == candidate.agent_run_id and run.agent_id == candidate.agent_id,
            join: agent in Agent,
            on: agent.id == candidate.agent_id,
            where: is_nil(candidate.payload_purged_at),
            where: candidate.status in ["completed", "failed"],
            where: run.status in ["completed", "failed", "cancelled"],
            where: not is_nil(candidate.completed_at),
            where: candidate.completed_at < ^cutoff,
            where: not is_nil(run.completed_at),
            where: run.completed_at < ^cutoff,
            where: fragment("? IS DISTINCT FROM ?", agent.active_run_id, run.id),
            order_by: [asc: candidate.completed_at, asc: candidate.id],
            limit: ^limit,
            select: candidate.id
          )

        now = DatabaseClock.now!()

        {count, _rows} =
          Repo.update_all(
            from(step in AgentRunStep,
              where: is_nil(step.payload_purged_at),
              where: step.id in subquery(candidate_ids)
            ),
            set: [
              request_payload: nil,
              response_payload: nil,
              legacy_request_payload: %{},
              legacy_response_payload: %{},
              payload_purged_at: now
            ]
          )

        count
      end)
    end
  end

  def purge_agent_run_step_payloads_before(_cutoff, _opts),
    do: {:error, :invalid_agent_run_step_payload_retention}

  def record_agent_run_step(run_id, agent_id, attrs)
      when is_binary(run_id) and is_binary(agent_id) and is_map(attrs) do
    with :ok <-
           reject_immutable_update(
             attrs,
             @step_identity_fields,
             :immutable_agent_run_step_identity
           ),
         {:ok, attrs} <- canonicalize_run_step_attrs(attrs),
         :ok <-
           validate_creation_status(attrs, "requested", :invalid_agent_run_step_status) do
      Repo.transaction(fn ->
        :ok = DurablePayload.require_current_mutation!()
        {_agent, operation} = lock_lifecycle_prefix!(agent_id)
        if operation, do: Repo.rollback(:agent_drain_pending)
        now = DatabaseClock.now!()

        run =
          AgentRun
          |> where([run], run.id == ^run_id and run.agent_id == ^agent_id)
          |> lock("FOR UPDATE")
          |> Repo.one()

        case run do
          nil ->
            Repo.rollback(:run_not_found)

          %AgentRun{status: "running"} ->
            sequence = attrs["sequence"] || next_run_step_sequence(run_id)

            attrs =
              attrs
              |> Map.put("agent_run_id", run_id)
              |> Map.put("agent_id", agent_id)
              |> Map.put("sequence", sequence)
              |> Map.put("status", "requested")
              |> Map.put("started_at", now)

            case %AgentRunStep{} |> AgentRunStep.changeset(attrs) |> Repo.insert() do
              {:ok, step} -> step
              {:error, reason} -> Repo.rollback(reason)
            end

          %AgentRun{} = run ->
            Repo.rollback({:run_not_running, run.status})
        end
      end)
    end
  end

  @doc false
  def reconcile_terminal_effect_step(
        %{agent_run_step_id: step_id, agent_run_id: run_id, agent_id: agent_id, status: status} =
          effect
      )
      when is_binary(step_id) and is_binary(run_id) and is_binary(agent_id) and
             status in ["completed", "failed"] do
    attrs =
      if status == "completed" do
        %{"status" => "completed", "response_payload" => Effect.result_payload(effect) || %{}}
      else
        %{
          "status" => "failed",
          "error" => effect.error || "effect_failed",
          "response_payload" => %{"error" => effect.error || "effect_failed"}
        }
      end

    case update_agent_run_step(step_id, agent_id, run_id, attrs) do
      {:ok, _step} -> :ok
      {:error, {:run_step_not_requested, ^status}} -> :ok
      {:error, _reason} -> :error
    end
  end

  def reconcile_terminal_effect_step(_effect), do: :ok

  def reconcile_terminal_effect_steps(effects) when is_list(effects) do
    Enum.reduce_while(effects, :ok, fn effect, :ok ->
      case reconcile_terminal_effect_step(effect) do
        :ok -> {:cont, :ok}
        :error -> {:halt, {:error, :agent_run_step_reconciliation_failed}}
      end
    end)
  end

  @doc false
  def reconcile_terminal_effect_steps_in_transaction(effects) when is_list(effects) do
    if Repo.in_transaction?() do
      now = DatabaseClock.now!()

      Enum.reduce_while(effects, :ok, fn effect, :ok ->
        case reconcile_terminal_effect_step_in_transaction(effect, now) do
          :ok -> {:cont, :ok}
          {:error, _reason} = error -> {:halt, error}
        end
      end)
    else
      {:error, :transaction_required}
    end
  end

  def reconcile_terminal_effect_steps_in_transaction(_effects),
    do: {:error, :invalid_terminal_effects}

  defp reconcile_terminal_effect_step_in_transaction(
         %{
           agent_run_step_id: step_id,
           agent_run_id: run_id,
           agent_id: agent_id,
           status: status
         } = effect,
         now
       )
       when is_binary(step_id) and is_binary(run_id) and is_binary(agent_id) and
              status in ["completed", "failed"] do
    error = if status == "failed", do: effect.error || "effect_failed"

    response_payload =
      if status == "completed",
        do: Effect.result_payload(effect) || %{},
        else: %{"error" => error}

    with {:ok, response_payload} <- AgentRunStep.prepare_response_payload(response_payload) do
      set_fields =
        if status == "completed" do
          [
            status: "completed",
            response_payload: response_payload,
            legacy_response_payload:
              if(DurablePayload.legacy_write?(), do: response_payload, else: %{}),
            completed_at: now,
            updated_at: now
          ]
        else
          [
            status: "failed",
            error: error,
            response_payload: response_payload,
            legacy_response_payload:
              if(DurablePayload.legacy_write?(), do: response_payload, else: %{}),
            completed_at: now,
            updated_at: now
          ]
        end

      {updated_count, _rows} =
        Repo.update_all(
          from(step in AgentRunStep,
            where: step.id == ^step_id,
            where: step.agent_run_id == ^run_id,
            where: step.agent_id == ^agent_id,
            where: step.status == "requested"
          ),
          set: set_fields
        )

      case updated_count do
        1 ->
          :ok

        0 ->
          case Repo.one(
                 from(step in AgentRunStep,
                   where: step.id == ^step_id,
                   where: step.agent_run_id == ^run_id,
                   where: step.agent_id == ^agent_id,
                   select: step.status
                 )
               ) do
            ^status -> :ok
            nil -> {:error, :run_step_not_owned}
            other_status -> {:error, {:run_step_not_requested, other_status}}
          end
      end
    else
      {:error, :invalid_payload} -> {:error, :invalid_agent_run_step_payload}
    end
  end

  defp reconcile_terminal_effect_step_in_transaction(_effect, _now), do: :ok

  def update_agent_run_step(step_id, agent_id, run_id, attrs)
      when is_binary(step_id) and is_binary(agent_id) and is_binary(run_id) and is_map(attrs) do
    do_update_agent_run_step(step_id, attrs, {agent_id, run_id})
  end

  def update_agent_run_step(_step_id, _agent_id, _run_id, _attrs),
    do: {:error, :invalid_agent_run_step_update}

  def update_agent_run_step(step_id, attrs) when is_binary(step_id) and is_map(attrs) do
    do_update_agent_run_step(step_id, attrs, nil)
  end

  defp do_update_agent_run_step(step_id, attrs, expected_owner) do
    with :ok <-
           reject_immutable_update(
             attrs,
             @immutable_step_update_fields,
             :immutable_agent_run_step_identity
           ),
         {:ok, attrs} <- canonicalize_run_step_attrs(attrs) do
      status = attrs["status"]

      Repo.transaction(fn ->
        :ok = DurablePayload.require_current_mutation!()

        hint =
          Repo.one(
            from(step in AgentRunStep,
              where: step.id == ^step_id,
              select: %{agent_id: step.agent_id, run_id: step.agent_run_id}
            )
          )

        {agent_id, run_id} = validate_run_step_owner!(hint, expected_owner)

        missing_reason =
          if expected_owner, do: :run_step_not_owned, else: :run_step_not_found

        {_agent, _operation} = lock_lifecycle_prefix!(agent_id, missing_reason)
        now = DatabaseClock.now!()

        attrs =
          if status in ["completed", "failed"] do
            attrs
            |> Map.put("status", status)
            |> Map.put("completed_at", now)
          else
            attrs
          end

        run =
          AgentRun
          |> where([run], run.id == ^run_id and run.agent_id == ^agent_id)
          |> lock("FOR UPDATE")
          |> Repo.one()

        step =
          AgentRunStep
          |> where([step], step.id == ^step_id)
          |> where([step], step.agent_run_id == ^run_id and step.agent_id == ^agent_id)
          |> lock("FOR UPDATE")
          |> Repo.one()

        case {step, run} do
          {nil, _run} ->
            if expected_owner,
              do: Repo.rollback(:run_step_not_owned),
              else: Repo.rollback(:run_step_not_found)

          {%AgentRunStep{status: step_status}, _run} when step_status != "requested" ->
            Repo.rollback({:run_step_not_requested, step_status})

          {%AgentRunStep{}, nil} ->
            Repo.rollback(:run_not_found)

          {%AgentRunStep{} = requested_step, %AgentRun{status: "running"}} ->
            requested_step |> AgentRunStep.changeset(attrs) |> update_or_rollback()

          {%AgentRunStep{}, %AgentRun{} = run} ->
            Repo.rollback({:run_not_running, run.status})
        end
      end)
    end
  end

  defp validate_run_step_owner!(nil, nil), do: Repo.rollback(:run_step_not_found)
  defp validate_run_step_owner!(nil, _expected_owner), do: Repo.rollback(:run_step_not_owned)

  defp validate_run_step_owner!(%{agent_id: agent_id, run_id: run_id}, nil),
    do: {agent_id, run_id}

  defp validate_run_step_owner!(
         %{agent_id: agent_id, run_id: run_id},
         {agent_id, run_id}
       ),
       do: {agent_id, run_id}

  defp validate_run_step_owner!(_hint, _expected_owner),
    do: Repo.rollback(:run_step_not_owned)

  @doc """
  List marketplace packages.
  """
  def list_agent_packages(opts \\ []) do
    preload = Keyword.get(opts, :preload, [])
    status = Keyword.get(opts, :status, "published")

    AgentPackage
    |> maybe_filter_package_status(status)
    |> order_by([package], asc: package.name)
    |> Repo.all()
    |> Repo.preload(preload)
  end

  @doc """
  Return packages annotated with the current user's installation state.
  """
  def list_marketplace_packages(user_id, opts \\ [])

  def list_marketplace_packages(user_id, opts) when is_binary(user_id) do
    packages = list_agent_packages(Keyword.put_new(opts, :preload, [:latest_version]))

    installs =
      Agent
      |> where([agent], agent.user_id == ^user_id)
      |> where([agent], agent.install_status != "removed")
      |> where([agent], not is_nil(agent.agent_package_id))
      |> Repo.all()
      |> Map.new(&{&1.agent_package_id, &1})

    Enum.map(packages, fn package ->
      %{package: package, installation: Map.get(installs, package.id)}
    end)
  end

  def list_marketplace_packages(_user_id, opts) do
    list_agent_packages(Keyword.put_new(opts, :preload, [:latest_version]))
    |> Enum.map(&%{package: &1, installation: nil})
  end

  @doc """
  Returns the active installation for a package slug and user.
  """
  def get_package_installation(user_id, package_slug, opts \\ [])

  def get_package_installation(user_id, package_slug, opts)
      when is_binary(user_id) and is_binary(package_slug) do
    preload = Keyword.get(opts, :preload, [])

    Agent
    |> join(:inner, [agent], package in AgentPackage, on: package.id == agent.agent_package_id)
    |> where([agent, package], agent.user_id == ^user_id and package.slug == ^package_slug)
    |> where([agent, _package], agent.install_status != "removed")
    |> order_by([agent, _package], desc: agent.updated_at, desc: agent.inserted_at)
    |> limit(1)
    |> Repo.one()
    |> Repo.preload(preload)
  end

  def get_package_installation(_user_id, _package_slug, _opts), do: nil

  @doc """
  Get a package by slug.
  """
  def get_agent_package_by_slug(slug, opts \\ []) when is_binary(slug) do
    preload = Keyword.get(opts, :preload, [])

    AgentPackage
    |> where([package], package.slug == ^slug)
    |> Repo.one()
    |> Repo.preload(preload)
  end

  @doc """
  Create or update a package by slug.
  """
  def upsert_agent_package(attrs) when is_map(attrs) do
    slug = attrs[:slug] || attrs["slug"]

    case get_agent_package_by_slug(slug) do
      nil -> create_agent_package(attrs)
      %AgentPackage{} = package -> update_agent_package(package, attrs)
    end
  end

  def create_agent_package(attrs) when is_map(attrs) do
    %AgentPackage{}
    |> AgentPackage.changeset(attrs)
    |> Repo.insert()
  end

  def update_agent_package(%AgentPackage{} = package, attrs) when is_map(attrs) do
    package
    |> AgentPackage.changeset(attrs)
    |> Repo.update()
  end

  def publish_agent_package(%AgentPackage{} = package) do
    update_agent_package(package, %{status: "published"})
  end

  def deprecate_agent_package(%AgentPackage{} = package) do
    update_agent_package(package, %{status: "deprecated"})
  end

  def disable_agent_package(%AgentPackage{} = package) do
    update_agent_package(package, %{status: "disabled"})
  end

  def create_agent_package_version(attrs) when is_map(attrs) do
    %AgentPackageVersion{}
    |> AgentPackageVersion.changeset(attrs)
    |> Repo.insert()
  end

  def update_agent_package_version(%AgentPackageVersion{} = version, attrs) when is_map(attrs) do
    version
    |> AgentPackageVersion.changeset(attrs)
    |> Repo.update()
  end

  def get_agent_package_version(id, opts \\ []) when is_binary(id) do
    preload = Keyword.get(opts, :preload, [])

    AgentPackageVersion
    |> Repo.get(id)
    |> Repo.preload(preload)
  end

  def publish_agent_package_version(%AgentPackage{} = package, attrs) when is_map(attrs) do
    attrs =
      attrs
      |> Map.put_new(:agent_package_id, package.id)
      |> Map.put_new(:status, "published")

    attrs =
      if version_status(attrs) == "published" do
        Map.put_new(attrs, :published_at, DateTime.utc_now())
      else
        attrs
      end

    Repo.transaction(fn ->
      with {:ok, version} <- create_agent_package_version(attrs),
           {:ok, package} <- update_agent_package(package, %{latest_version_id: version.id}) do
        %{package | latest_version: version}
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> case do
      {:ok, package} -> {:ok, package}
      {:error, reason} -> {:error, reason}
    end
  end

  def publish_agent_package_version(%AgentPackageVersion{} = version) do
    published_at = version.published_at || DateTime.utc_now()

    Repo.transaction(fn ->
      with {:ok, version} <-
             update_agent_package_version(version, %{
               status: "published",
               published_at: published_at
             }),
           %AgentPackage{} = package <- Repo.get(AgentPackage, version.agent_package_id),
           {:ok, _package} <- update_agent_package(package, %{latest_version_id: version.id}) do
        version
      else
        nil -> Repo.rollback(:package_not_found)
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> case do
      {:ok, version} -> {:ok, version}
      {:error, reason} -> {:error, reason}
    end
  end

  def deprecate_agent_package_version(%AgentPackageVersion{} = version) do
    update_agent_package_version(version, %{status: "deprecated"})
  end

  def disable_agent_package_version(%AgentPackageVersion{} = version) do
    update_agent_package_version(version, %{status: "disabled"})
  end

  @doc """
  Install the latest published version of a package for a user.
  """
  def install_agent_package(user_id, package_slug, opts \\ [])
      when is_binary(user_id) and is_binary(package_slug) do
    with %AgentPackage{} = package <-
           get_agent_package_by_slug(package_slug, preload: [:latest_version]),
         %AgentPackageVersion{} = version <- package.latest_version do
      opts =
        opts
        |> Keyword.put(:runtime_status, "stopped")
        |> Keyword.put(:install_status, "setup_required")

      attrs = installation_attrs(user_id, package, version, opts)
      create_agent(attrs)
    else
      nil -> {:error, :package_not_found}
    end
  end

  @doc """
  Installs or updates the Chief of Staff package for a user.

  Connector readiness is discovery only. New installs are always persisted as
  setup-required and stopped; only Runtime's explicit consent transaction may
  activate them.
  """
  def install_chief_of_staff(user_id, opts \\ [])

  def install_chief_of_staff(user_id, opts) when is_binary(user_id) do
    project_id = Keyword.get(opts, :project_id)

    with :ok <- validate_install_project(user_id, project_id),
         {:ok, _packages} <- Maraithon.AgentMarketplace.sync_builtin_packages(),
         %AgentPackage{} = package <-
           get_agent_package_by_slug("ai_chief_of_staff", preload: [:latest_version]),
         %AgentPackageVersion{} = version <- package.latest_version do
      # Connector/OAuth readiness is not Binding consent. New Chief installs
      # remain non-runnable until Runtime commits an explicit consent proof.
      opts =
        opts
        |> Keyword.put(:project_id, project_id)
        |> Keyword.put(:install_status, "setup_required")
        |> Keyword.put(:runtime_status, "stopped")
        |> Keyword.put_new(:delivery_policy, %{"telegram" => "enabled"})

      case get_package_installation(user_id, package.slug) do
        nil ->
          attrs = installation_attrs(user_id, package, version, opts)
          create_agent(attrs)

        %Agent{} = existing ->
          # Re-running install discovery is not consent and must not rewrite a
          # live configuration or downgrade a previously proven active row.
          {:ok, existing}
      end
    else
      nil -> {:error, :package_not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  def install_chief_of_staff(_user_id, _opts), do: {:error, :invalid_user}

  @doc """
  Seed or update a database package from an in-memory manifest.
  """
  def sync_agent_package_manifest(manifest) when is_map(manifest) do
    with {:ok, package_attrs, version_attrs} <- package_manifest_attrs(manifest) do
      Repo.transaction(fn ->
        with {:ok, package} <- upsert_agent_package(package_attrs),
             {:ok, package} <- upsert_latest_version(package, version_attrs) do
          package
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
      |> case do
        {:ok, package} -> {:ok, Repo.preload(package, [:latest_version], force: true)}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  def sync_agent_package_manifest(_manifest) do
    {:error, {:invalid_agent_manifest, [manifest: "must be a map"]}}
  end

  @doc """
  Count agents by status.
  """
  def count_by_status(status) do
    from(a in Agent, where: a.status == ^status, select: count(a.id))
    |> Repo.one()
  end

  @doc """
  List agents that should be resumed on startup.
  """
  def list_resumable_agents(opts \\ []) do
    user_id = Keyword.get(opts, :user_id)
    project_id = Keyword.get(opts, :project_id)
    preload = Keyword.get(opts, :preload, [])

    from(a in Agent,
      left_join: operation in AgentLifecycleOperation,
      on: operation.agent_id == a.id,
      where: a.status in ["recovering", "running", "degraded"],
      where: is_nil(operation.agent_id)
    )
    |> maybe_filter_user(user_id)
    |> maybe_filter_project(project_id)
    |> maybe_filter_removed(Keyword.get(opts, :include_removed, false))
    |> Repo.all()
    |> Repo.preload(preload)
  end

  @doc false
  def begin_runtime_agent_recovery(id) when is_binary(id) do
    runtime_recovery_transition(id, :begin)
  end

  @doc false
  def finish_runtime_agent_recovery(id) when is_binary(id) do
    runtime_recovery_transition(id, :finish)
  end

  defp runtime_recovery_transition(id, transition) do
    if RuntimeConfig.exact_agent_runtime_enabled?() do
      Repo.transaction(fn ->
        agent =
          Repo.one(from(agent in Agent, where: agent.id == ^id, lock: "FOR UPDATE")) ||
            Repo.rollback(:agent_not_found)

        _binding =
          if is_binary(agent.user_id) do
            Repo.one(
              from(binding in Binding,
                where: binding.agent_id == ^id,
                where: binding.user_id == ^agent.user_id,
                lock: "FOR UPDATE"
              )
            )
          end

        _guard =
          Repo.one(
            from(guard in AgentRestartGuard,
              where: guard.agent_id == ^id,
              lock: "FOR UPDATE"
            )
          )

        _lease =
          Repo.one(
            from(lease in AgentRuntimeLease,
              where: lease.agent_id == ^id,
              lock: "FOR UPDATE"
            )
          )

        operation =
          Repo.one(
            from(operation in AgentLifecycleOperation,
              where: operation.agent_id == ^id,
              lock: "FOR UPDATE"
            )
          )

        if operation, do: Repo.rollback(:agent_drain_pending)
        now = DatabaseClock.now!()

        case {transition, agent} do
          {:begin, %Agent{status: status, install_status: "enabled"}}
          when status in ["recovering", "running", "degraded"] ->
            agent
            |> Ecto.Changeset.change(status: "recovering", updated_at: now)
            |> Repo.update!()

          {:finish, %Agent{status: "recovering", install_status: "enabled", active_run_id: nil}} ->
            agent
            |> Ecto.Changeset.change(status: "running", updated_at: now)
            |> Repo.update!()

          {:begin, _agent} ->
            Repo.rollback(:agent_not_runnable)

          {:finish, _agent} ->
            Repo.rollback(:agent_recovery_fenced)
        end
      end)
    else
      {:error, :exact_runtime_disabled}
    end
  end

  @doc false
  def claim_agent_start(id) when is_binary(id) do
    if RuntimeConfig.exact_agent_runtime_enabled?() do
      Repo.transaction(fn ->
        agent =
          Repo.one(
            from(agent in Agent,
              where: agent.id == ^id,
              lock: "FOR UPDATE"
            )
          )

        if is_nil(agent), do: Repo.rollback(:not_found)

        binding =
          if is_binary(agent.user_id) do
            Repo.one(
              from(binding in Binding,
                where: binding.agent_id == ^id,
                where: binding.user_id == ^agent.user_id,
                lock: "FOR UPDATE"
              )
            )
          end

        _guard =
          Repo.one(
            from(guard in AgentRestartGuard,
              where: guard.agent_id == ^id,
              lock: "FOR UPDATE"
            )
          )

        existing_lease =
          Repo.one(
            from(lease in AgentRuntimeLease,
              where: lease.agent_id == ^id,
              lock: "FOR UPDATE"
            )
          )

        operation =
          Repo.one(
            from(operation in AgentLifecycleOperation,
              where: operation.agent_id == ^id,
              lock: "FOR UPDATE"
            )
          )

        if operation, do: Repo.rollback(:agent_drain_pending)
        ensure_agent_startable!(agent)

        unless match?(%Binding{status: "active"}, binding) do
          Repo.rollback(:agent_binding_not_active)
        end

        if existing_lease, do: Repo.rollback(:agent_drain_pending)

        now = DatabaseClock.now!()

        updated_agent =
          agent
          |> Ecto.Changeset.change(%{
            status: "running",
            started_at: now,
            stopped_at: nil,
            updated_at: now
          })
          |> Repo.update!()

        case AgentSubscriptions.sync_for_agent_locked(updated_agent) do
          {:ok, _subscriptions} -> updated_agent
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
    else
      {:error, :exact_runtime_disabled}
    end
  end

  @doc false
  def fail_agent_start_intent(id) when is_binary(id) do
    Repo.transaction(fn ->
      agent =
        Repo.one(from(agent in Agent, where: agent.id == ^id, lock: "FOR UPDATE")) ||
          Repo.rollback(:not_found)

      _binding =
        if is_binary(agent.user_id) do
          Repo.one(
            from(binding in Binding,
              where: binding.agent_id == ^id,
              where: binding.user_id == ^agent.user_id,
              lock: "FOR UPDATE"
            )
          )
        end

      _guard =
        Repo.one(
          from(guard in AgentRestartGuard,
            where: guard.agent_id == ^id,
            lock: "FOR UPDATE"
          )
        )

      lease =
        Repo.one(
          from(lease in AgentRuntimeLease,
            where: lease.agent_id == ^id,
            lock: "FOR UPDATE"
          )
        )

      operation =
        Repo.one(
          from(operation in AgentLifecycleOperation,
            where: operation.agent_id == ^id,
            lock: "FOR UPDATE"
          )
        )

      stopped_agent =
        cond do
          operation ->
            Repo.rollback(:agent_drain_pending)

          lease ->
            Repo.rollback(:runtime_lease_owned)

          agent.status in ["running", "degraded", "recovering"] ->
            now = DatabaseClock.now!()

            agent
            |> Ecto.Changeset.change(status: "stopped", stopped_at: now, updated_at: now)
            |> Repo.update!()

          true ->
            agent
        end

      case AgentSubscriptions.sync_for_agent_locked(stopped_agent) do
        {:ok, _subscriptions} -> stopped_agent
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp ensure_agent_startable!(nil), do: Repo.rollback(:not_found)

  defp ensure_agent_startable!(%Agent{status: status})
       when status in ["running", "degraded"],
       do: Repo.rollback(:already_running)

  defp ensure_agent_startable!(%Agent{status: "recovering"}),
    do: Repo.rollback(:agent_recovering)

  defp ensure_agent_startable!(%Agent{install_status: "removed"}),
    do: Repo.rollback(:agent_removed)

  defp ensure_agent_startable!(%Agent{install_status: "paused"}),
    do: Repo.rollback(:agent_paused)

  defp ensure_agent_startable!(%Agent{install_status: "setup_required"}),
    do: Repo.rollback(:agent_setup_required)

  defp ensure_agent_startable!(%Agent{install_status: "enabled"}), do: :ok
  defp ensure_agent_startable!(%Agent{}), do: Repo.rollback(:agent_start_conflict)

  @doc """
  Mark agent as running.
  """
  def mark_running(%Agent{} = agent) do
    update_agent(agent, %{status: "running", started_at: DateTime.utc_now()})
  end

  @doc """
  Mark agent as stopped.
  """
  def mark_stopped(%Agent{} = agent) do
    update_agent(agent, %{status: "stopped", stopped_at: DateTime.utc_now()})
  end

  @doc """
  Mark agent as degraded.
  """
  def mark_degraded(%Agent{} = agent) do
    update_agent(agent, %{status: "degraded"})
  end

  defp canonicalize_run_attrs(attrs),
    do: canonicalize_top_level_attr_keys(attrs, :invalid_agent_run_attributes)

  defp canonicalize_run_step_attrs(attrs),
    do: canonicalize_top_level_attr_keys(attrs, :invalid_agent_run_step_attributes)

  defp canonicalize_top_level_attr_keys(attrs, reason) do
    Enum.reduce_while(attrs, {:ok, %{}}, fn {key, value}, {:ok, canonical_attrs} ->
      canonical_key =
        cond do
          is_atom(key) -> Atom.to_string(key)
          is_binary(key) -> key
          true -> nil
        end

      case canonical_key do
        nil ->
          {:halt, {:error, reason}}

        canonical_key ->
          case Map.fetch(canonical_attrs, canonical_key) do
            :error ->
              {:cont, {:ok, Map.put(canonical_attrs, canonical_key, value)}}

            {:ok, existing_value} when existing_value === value ->
              {:cont, {:ok, canonical_attrs}}

            {:ok, _existing_value} ->
              {:halt, {:error, reason}}
          end
      end
    end)
  end

  defp validate_creation_status(attrs, expected, reason) do
    values =
      [:status, "status"]
      |> Enum.filter(&Map.has_key?(attrs, &1))
      |> Enum.map(&Map.fetch!(attrs, &1))
      |> Enum.uniq()

    if values in [[], [expected]], do: :ok, else: {:error, reason}
  end

  defp reject_immutable_update(attrs, fields, reason) do
    if Enum.any?(fields, fn field ->
         Map.has_key?(attrs, field) or Map.has_key?(attrs, Atom.to_string(field))
       end) do
      {:error, reason}
    else
      :ok
    end
  end

  defp lock_lifecycle_prefix!(agent_id, missing_reason \\ :agent_not_found) do
    agent =
      Repo.one(from(agent in Agent, where: agent.id == ^agent_id, lock: "FOR UPDATE")) ||
        Repo.rollback(missing_reason)

    _binding =
      if is_binary(agent.user_id) do
        Repo.one(
          from(binding in Binding,
            where: binding.agent_id == ^agent.id,
            where: binding.user_id == ^agent.user_id,
            lock: "FOR UPDATE"
          )
        )
      end

    _guard =
      Repo.one(
        from(guard in AgentRestartGuard,
          where: guard.agent_id == ^agent.id,
          lock: "FOR UPDATE"
        )
      )

    _lease =
      Repo.one(
        from(lease in AgentRuntimeLease,
          where: lease.agent_id == ^agent.id,
          lock: "FOR UPDATE"
        )
      )

    operation =
      Repo.one(
        from(operation in AgentLifecycleOperation,
          where: operation.agent_id == ^agent.id,
          lock: "FOR UPDATE"
        )
      )

    {agent, operation}
  end

  defp close_requested_run_steps(run_id, reason, now) do
    query =
      from(step in AgentRunStep,
        where: step.agent_run_id == ^run_id and step.status == "requested",
        update: [
          set: [
            status: "failed",
            error: fragment("COALESCE(?, ?)", step.error, ^reason),
            completed_at: ^now,
            updated_at: ^now
          ]
        ]
      )

    {step_count, _rows} = Repo.update_all(query, [])
    step_count
  end

  defp clear_active_run_pointer(agent_id, run_id, now) do
    Repo.update_all(
      from(agent in Agent,
        where: agent.id == ^agent_id,
        where: agent.active_run_id == ^run_id
      ),
      set: [active_run_id: nil, updated_at: now]
    )

    :ok
  end

  defp agent_run_attrs(%Agent{} = agent, attrs, now) do
    attrs
    |> Map.put("agent_id", agent.id)
    |> Map.put("user_id", agent.user_id)
    |> Map.put("project_id", agent.project_id)
    |> Map.put("behavior", agent.behavior)
    |> Map.put("agent_package_id", agent.agent_package_id)
    |> Map.put("agent_package_version_id", agent.agent_package_version_id)
    |> Map.put("status", "running")
    |> Map.put("started_at", now)
  end

  defp insert_or_rollback(changeset) do
    case Repo.insert(changeset) do
      {:ok, record} -> record
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp update_or_rollback(changeset) do
    case Repo.update(changeset) do
      {:ok, record} -> record
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp lock_legacy_run_step_payload_ids(limit, skip) do
    %{rows: rows} =
      Repo.query!(
        """
        SELECT steps.id
        FROM agent_run_steps AS steps
        JOIN agent_runs AS runs
          ON runs.id = steps.agent_run_id
         AND runs.agent_id = steps.agent_id
        JOIN agents
          ON agents.id = steps.agent_id
        WHERE steps.payload_purged_at IS NULL
          AND (
            steps.request_payload_ciphertext IS NULL
            OR steps.response_payload_ciphertext IS NULL
            OR steps.request_payload <> '{}'::jsonb
            OR steps.response_payload <> '{}'::jsonb
          )
          AND steps.status IN ('completed', 'failed')
          AND steps.completed_at IS NOT NULL
          AND runs.status IN ('completed', 'failed', 'cancelled')
          AND runs.completed_at IS NOT NULL
          AND agents.active_run_id IS DISTINCT FROM runs.id
        ORDER BY steps.completed_at NULLS LAST, steps.id
        OFFSET $2
        LIMIT $1
        FOR UPDATE OF steps SKIP LOCKED
        """,
        [limit, skip],
        timeout: @run_step_payload_backfill_timeout_ms,
        log: false
      )

    Enum.map(rows, fn [id] -> load_run_step_uuid!(id) end)
  end

  defp load_run_step_uuid!(value) do
    case Ecto.UUID.load(value) do
      {:ok, uuid} -> uuid
      :error -> Repo.rollback(:invalid_agent_run_step_payload_backfill_id)
    end
  end

  defp promote_legacy_run_step_payloads(%AgentRunStep{} = step) do
    {stored_request, stored_response} = AgentRunStep.read_payloads!(step)

    request_payload =
      if step.legacy_request_payload != %{}, do: step.legacy_request_payload, else: stored_request

    response_payload =
      if step.legacy_response_payload != %{},
        do: step.legacy_response_payload,
        else: stored_response

    changeset =
      step
      |> AgentRunStep.changeset(%{
        request_payload: request_payload,
        response_payload: response_payload
      })
      |> Ecto.Changeset.put_change(:legacy_request_payload, %{})
      |> Ecto.Changeset.put_change(:legacy_response_payload, %{})
      |> Ecto.Changeset.put_change(:updated_at, step.updated_at)

    if changeset.valid? do
      case Repo.update(changeset, log: false) do
        {:ok, _step} -> :ok
        {:error, _changeset} -> {:blocked, %{id: step.id, errors: [:persistence_failed]}}
      end
    else
      {:blocked, %{id: step.id, errors: [:payload_out_of_bounds]}}
    end
  end

  defp run_step_payload_backfill_options(opts) do
    if Keyword.keyword?(opts) do
      limit = Keyword.get(opts, :limit, @default_run_step_payload_backfill_batch)
      skip = Keyword.get(opts, :skip, 0)

      if is_integer(limit) and limit in 1..@max_run_step_payload_backfill_batch and
           is_integer(skip) and skip in 0..10_000 do
        {:ok, {limit, skip}}
      else
        {:error, :invalid_agent_run_step_payload_backfill}
      end
    else
      {:error, :invalid_agent_run_step_payload_backfill}
    end
  end

  defp validate_run_step_retention_cutoff(%DateTime{utc_offset: 0, std_offset: 0}), do: :ok

  defp validate_run_step_retention_cutoff(_cutoff),
    do: {:error, :invalid_agent_run_step_payload_retention}

  defp run_step_payload_purge_limit(opts) do
    if Keyword.keyword?(opts) do
      case Keyword.get(opts, :limit, @default_run_step_payload_purge_batch) do
        limit when is_integer(limit) and limit in 1..@max_run_step_payload_purge_batch ->
          {:ok, limit}

        _invalid ->
          {:error, :invalid_agent_run_step_payload_retention}
      end
    else
      {:error, :invalid_agent_run_step_payload_retention}
    end
  end

  defp recent_run_limit(opts) do
    value = if Keyword.keyword?(opts), do: Keyword.get(opts, :limit, 50), else: 50

    case value do
      limit when is_integer(limit) -> limit |> max(1) |> min(50)
      _invalid -> 50
    end
  end

  defp recent_run_step_headers(_user_id, []), do: %{}

  defp recent_run_step_headers(user_id, run_ids) do
    ranked_steps =
      from(step in AgentRunStep,
        join: run in AgentRun,
        on: run.id == step.agent_run_id and run.agent_id == step.agent_id,
        join: agent in Agent,
        on: agent.id == run.agent_id and agent.user_id == run.user_id,
        where: step.agent_run_id in ^run_ids,
        where: run.user_id == ^user_id and agent.user_id == ^user_id,
        windows: [
          per_run: [partition_by: step.agent_run_id, order_by: [desc: step.sequence]]
        ],
        select: %{
          id: step.id,
          agent_run_id: step.agent_run_id,
          sequence: step.sequence,
          step_type: step.step_type,
          status: step.status,
          tool_name: step.tool_name,
          effect_type: step.effect_type,
          started_at: step.started_at,
          completed_at: step.completed_at,
          position: over(row_number(), :per_run)
        }
      )

    ranked_steps
    |> subquery()
    |> where([step], step.position <= 8)
    |> order_by([step], asc: step.agent_run_id, asc: step.sequence)
    |> select([step], %{
      id: step.id,
      agent_run_id: step.agent_run_id,
      sequence: step.sequence,
      step_type: step.step_type,
      status: step.status,
      tool_name: step.tool_name,
      effect_type: step.effect_type,
      started_at: step.started_at,
      completed_at: step.completed_at
    })
    |> Repo.all()
    |> Enum.group_by(& &1.agent_run_id)
  end

  defp hydrate_run_step_payloads!(%AgentRun{steps: steps} = run) when is_list(steps) do
    run = AgentRun.hydrate_private_payloads(run)
    %{run | steps: Enum.map(steps, &AgentRunStep.hydrate_payloads!/1)}
  end

  defp hydrate_run_step_payloads!(%AgentRun{} = run), do: AgentRun.hydrate_private_payloads(run)

  defp valid_database_text?(value) do
    String.valid?(value) and :binary.match(value, <<0>>) == :nomatch
  end

  defp maybe_filter_user(query, nil), do: query
  defp maybe_filter_user(query, ""), do: query

  defp maybe_filter_user(query, user_id) when is_binary(user_id) do
    where(query, [agent], agent.user_id == ^user_id)
  end

  defp maybe_filter_project(query, nil), do: query
  defp maybe_filter_project(query, ""), do: query

  defp maybe_filter_project(query, project_id) when is_binary(project_id) do
    where(query, [agent], agent.project_id == ^project_id)
  end

  defp maybe_filter_removed(query, true), do: query

  defp maybe_filter_removed(query, false) do
    where(query, [agent], agent.install_status != "removed")
  end

  defp maybe_filter_package_status(query, :all), do: query
  defp maybe_filter_package_status(query, nil), do: query

  defp maybe_filter_package_status(query, status),
    do: where(query, [package], package.status == ^status)

  defp validate_install_project(_user_id, nil), do: :ok
  defp validate_install_project(_user_id, ""), do: :ok

  defp validate_install_project(user_id, project_id)
       when is_binary(user_id) and is_binary(project_id) do
    case Projects.get_project_for_user(project_id, user_id) do
      nil -> {:error, :project_not_found}
      _project -> :ok
    end
  end

  defp validate_install_project(_user_id, _project_id), do: {:error, :project_not_found}

  defp next_run_step_sequence(run_id) do
    AgentRunStep
    |> where([step], step.agent_run_id == ^run_id)
    |> select([step], max(step.sequence))
    |> Repo.one()
    |> case do
      nil -> 1
      sequence -> sequence + 1
    end
  end

  defp installation_attrs(user_id, package, version, opts) do
    config_overrides = Keyword.get(opts, :config, %{})

    config =
      version
      |> package_default_config(user_id)
      |> deep_merge(stringify_keys(config_overrides))
      |> Map.put_new("name", package.name)
      |> Map.put("agent_package_version_id", version.id)
      |> sync_schedule_config_into_skill_configs()

    %{
      user_id: user_id,
      project_id: Keyword.get(opts, :project_id),
      behavior: version.behavior,
      config: config,
      status: Keyword.get(opts, :runtime_status, "stopped"),
      install_status: Keyword.get(opts, :install_status, "enabled"),
      installed_at: DateTime.utc_now(),
      agent_package_id: package.id,
      agent_package_version_id: version.id,
      connector_grants: Keyword.get(opts, :connector_grants, %{}),
      schedule_policy: Keyword.get(opts, :schedule_policy, %{}),
      delivery_policy: Keyword.get(opts, :delivery_policy, %{}),
      memory_scope: Keyword.get(opts, :memory_scope, %{})
    }
  end

  defp upsert_latest_version(package, attrs) do
    version = Map.fetch!(attrs, :version)

    existing =
      AgentPackageVersion
      |> where([package_version], package_version.agent_package_id == ^package.id)
      |> where([package_version], package_version.version == ^version)
      |> Repo.one()

    case existing do
      nil ->
        publish_agent_package_version(package, attrs)

      %AgentPackageVersion{} = existing ->
        with {:ok, updated_version} <-
               existing
               |> AgentPackageVersion.changeset(Map.put(attrs, :agent_package_id, package.id))
               |> Repo.update(),
             {:ok, updated_package} <-
               update_agent_package(package, %{latest_version_id: updated_version.id}) do
          {:ok, %{updated_package | latest_version: updated_version}}
        end
    end
  end

  defp package_default_config(%AgentPackageVersion{} = version, user_id) do
    case version.default_config do
      %{"behavior" => _behavior} = launch ->
        source_behavior = source_behavior(launch)
        launch_for_config = Map.put(launch, "behavior", source_behavior)

        case AgentBuilder.build_start_params(launch_for_config, user_id) do
          {:ok, %{"config" => config, "budget" => budget}} ->
            config
            |> Map.put("budget", budget)
            |> Map.put("source_behavior", source_behavior)
            |> Map.put("marketplace_behavior", version.behavior)

          {:ok, %{"config" => config}} ->
            config
            |> Map.put("source_behavior", source_behavior)
            |> Map.put("marketplace_behavior", version.behavior)

          {:error, _reason} ->
            version.default_config
        end

      config when is_map(config) ->
        config

      _ ->
        %{}
    end
  end

  defp deep_merge(left, right) when is_map(left) and is_map(right) do
    Map.merge(left, right, fn _key, left_value, right_value ->
      deep_merge(left_value, right_value)
    end)
  end

  defp deep_merge(_left, right), do: right

  defp sync_schedule_config_into_skill_configs(config) when is_map(config) do
    schedule_updates =
      config
      |> Map.take([
        "timezone",
        "timezone_name",
        "timezone_offset_hours",
        "morning_brief_hour_local",
        "morning_brief_minute_local",
        "end_of_day_brief_hour_local",
        "end_of_day_brief_minute_local",
        "weekly_review_day_local",
        "weekly_review_hour_local",
        "weekly_review_minute_local"
      ])
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new()

    case {schedule_updates, Map.get(config, "skill_configs")} do
      {updates, skill_configs} when updates != %{} and is_map(skill_configs) ->
        Map.put(config, "skill_configs", merge_skill_schedule_config(skill_configs, updates))

      _ ->
        config
    end
  end

  defp sync_schedule_config_into_skill_configs(config), do: config

  defp merge_skill_schedule_config(skill_configs, schedule_updates) do
    Map.new(skill_configs, fn
      {skill_id, skill_config} when is_map(skill_config) ->
        {skill_id, Map.merge(skill_config, schedule_updates)}

      entry ->
        entry
    end)
  end

  defp source_behavior(%{"source_behavior" => behavior})
       when is_binary(behavior) and behavior != "",
       do: behavior

  defp source_behavior(%{"behavior" => behavior}) when is_binary(behavior), do: behavior
  defp source_behavior(_launch), do: "prompt_agent"

  defp package_manifest_attrs(manifest) do
    manifest = HarnessManifest.normalize(manifest)

    errors =
      required_manifest_errors(manifest, [
        :slug,
        :name,
        :behavior,
        :model,
        :intelligence
      ])
      |> Kernel.++(semantic_manifest_errors(manifest))

    if errors == [] do
      {:ok, package_attrs(manifest), version_attrs(manifest)}
    else
      {:error, {:invalid_agent_manifest, errors}}
    end
  end

  defp required_manifest_errors(manifest, required_keys) do
    Enum.flat_map(required_keys, fn key ->
      case manifest_text(manifest, key) do
        value when is_binary(value) and value != "" -> []
        _ -> [{key, "is required"}]
      end
    end)
  end

  defp semantic_manifest_errors(manifest) do
    case manifest_text(manifest, :behavior) do
      "manifest_agent" -> markdown_skill_errors(manifest)
      _behavior -> []
    end
  end

  defp markdown_skill_errors(manifest) do
    skill_paths =
      manifest
      |> HarnessManifest.get(:skill_paths)
      |> List.wrap()
      |> Enum.filter(&present_text?/1)

    cond do
      skill_paths == [] ->
        [skill_paths: "must include at least one Markdown skill path"]

      true ->
        case MarkdownSkill.load_many(skill_paths) do
          {:ok, _skills} -> []
          {:error, reason} -> [skill_paths: "could not load Markdown skills: #{inspect(reason)}"]
        end
    end
  end

  defp package_attrs(manifest) do
    %{
      slug: manifest_text(manifest, :slug),
      name: manifest_text(manifest, :name),
      summary: HarnessManifest.get(manifest, :summary),
      category: HarnessManifest.get(manifest, :category),
      source_kind: manifest_text(manifest, :source_kind, "builtin"),
      status: manifest_text(manifest, :status, "published"),
      owner_user_id: HarnessManifest.get(manifest, :owner_user_id),
      manifest: manifest
    }
  end

  defp version_attrs(manifest) do
    %{
      version: manifest_text(manifest, :version, "1.0.0"),
      changelog: HarnessManifest.get(manifest, :changelog),
      behavior: manifest_text(manifest, :behavior),
      system_prompt: HarnessManifest.get(manifest, :system_prompt),
      model: manifest_text(manifest, :model),
      intelligence: manifest_text(manifest, :intelligence),
      goals: List.wrap(HarnessManifest.get(manifest, :goals)),
      skill_paths: List.wrap(HarnessManifest.get(manifest, :skill_paths)),
      required_connectors: manifest_map(manifest, :required_connectors),
      tool_allowlist: List.wrap(HarnessManifest.get(manifest, :tool_allowlist)),
      mcp_allowlist: List.wrap(HarnessManifest.get(manifest, :mcp_allowlist)),
      default_config: manifest_map(manifest, :default_config),
      manifest: manifest,
      status: manifest_text(manifest, :version_status, "published")
    }
  end

  defp manifest_text(manifest, key, default \\ nil) do
    case HarnessManifest.get(manifest, key, default) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> nil
          trimmed -> trimmed
        end

      value ->
        value
    end
  end

  defp present_text?(value) when is_binary(value), do: String.trim(value) != ""
  defp present_text?(_value), do: false

  defp manifest_map(manifest, key) do
    case HarnessManifest.get(manifest, key, %{}) do
      value when is_map(value) -> value
      _ -> %{}
    end
  end

  defp version_status(attrs) when is_map(attrs) do
    attrs[:status] || attrs["status"]
  end

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), value} end)
  end

  defp stringify_keys(_), do: %{}
end
