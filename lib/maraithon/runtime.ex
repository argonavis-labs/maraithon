defmodule Maraithon.Runtime do
  @moduledoc """
  Runtime facade for managing agents.
  Provides the main API for starting, stopping, and interacting with agents.
  """

  import Ecto.Query

  alias Maraithon.Agents
  alias Maraithon.Agents.AgentRun
  alias Maraithon.Agents.AgentRunStep
  alias Maraithon.Effects.Effect
  alias Maraithon.Repo
  alias Maraithon.AgentSubscriptions
  alias Maraithon.Runtime.AgentDirective
  alias Maraithon.Runtime.AgentLeases
  alias Maraithon.Runtime.AgentSupervisor
  alias Maraithon.Runtime.AgentRegistry
  alias Maraithon.Runtime.Dispatch
  alias Maraithon.Events
  alias Maraithon.Runtime.BackgroundJobs
  alias Maraithon.Runtime.IncidentLog
  alias Maraithon.Runtime.AgentRestartGuards
  alias Maraithon.Runtime.Scheduler

  require Logger

  @doc """
  Enqueue durable app-level background work.

  Use this for non-interactive processing such as email scans, relationship
  learning, open-loop refreshes, and other long-running user-scoped work.
  """
  def enqueue_background_job(job_type, attrs \\ %{}) when is_binary(job_type) do
    BackgroundJobs.enqueue(job_type, attrs)
  end

  def enqueue_email_processing(user_id, attrs \\ %{}) when is_binary(user_id) do
    BackgroundJobs.enqueue_email_processing(user_id, attrs)
  end

  def enqueue_relationship_learning(user_id, observations, attrs \\ [])
      when is_binary(user_id) and is_list(observations) do
    BackgroundJobs.enqueue_relationship_learning(user_id, observations, attrs)
  end

  def enqueue_open_loop_check(user_id, attrs \\ %{}) when is_binary(user_id) do
    BackgroundJobs.enqueue_open_loop_check(user_id, attrs)
  end

  @doc """
  Start a new agent with the given parameters.
  """
  def start_agent(params) do
    attrs = %{
      user_id: params["user_id"] || params[:user_id],
      project_id: normalize_optional_string(params["project_id"] || params[:project_id]),
      behavior: params["behavior"] || params[:behavior],
      config: params["config"] || params[:config] || %{},
      status: "running",
      started_at: DateTime.utc_now(),
      install_status: params["install_status"] || params[:install_status] || "enabled",
      installed_at: params["installed_at"] || params[:installed_at] || DateTime.utc_now(),
      agent_package_id: params["agent_package_id"] || params[:agent_package_id],
      agent_package_version_id:
        params["agent_package_version_id"] || params[:agent_package_version_id],
      connector_grants: params["connector_grants"] || params[:connector_grants] || %{},
      schedule_policy: params["schedule_policy"] || params[:schedule_policy] || %{},
      delivery_policy: params["delivery_policy"] || params[:delivery_policy] || %{},
      memory_scope: params["memory_scope"] || params[:memory_scope] || %{}
    }

    # Add budget to config if provided
    attrs =
      if budget = params["budget"] || params[:budget] do
        put_in(attrs, [:config, "budget"], budget)
      else
        put_in(attrs, [:config, "budget"], default_budget())
      end

    with {:ok, agent} <- Agents.create_agent(attrs),
         {:ok, _pid} <- start_agent_process(agent) do
      Logger.info("Started agent #{agent.id}", agent_id: agent.id, behavior: agent.behavior)
      {:ok, agent}
    else
      {:error, reason} = error ->
        Logger.error("Failed to start agent: #{inspect(reason)}")
        error
    end
  end

  @doc """
  Install the latest package version for a user and start its runtime process.
  """
  def install_agent_package(user_id, package_slug, opts \\ [])
      when is_binary(user_id) and is_binary(package_slug) do
    opts =
      opts
      |> Keyword.put_new(:runtime_status, "running")
      |> Keyword.put_new(:install_status, "enabled")

    with {:ok, agent} <- Agents.install_agent_package(user_id, package_slug, opts),
         {:ok, _pid_or_status} <- maybe_start_installed_agent(agent) do
      Logger.info("Installed package agent #{agent.id}",
        agent_id: agent.id,
        package_slug: package_slug,
        behavior: agent.behavior
      )

      {:ok, agent}
    else
      {:error, reason} = error ->
        Logger.error("Failed to install package #{package_slug}: #{inspect(reason)}")
        error
    end
  end

  @doc """
  Installs the Chief of Staff package and starts it only when setup is complete.
  """
  def install_chief_of_staff(user_id, opts \\ []) when is_binary(user_id) do
    with {:ok, agent} <- Agents.install_chief_of_staff(user_id, opts),
         {:ok, _pid_or_status} <- maybe_start_installed_agent(agent) do
      {:ok, agent}
    end
  end

  @doc """
  Start an existing persisted agent by ID.
  """
  def start_existing_agent(id) when is_binary(id) do
    with_agent_lifecycle_lock(id, fn -> do_start_existing_agent(id) end)
  end

  defp do_start_existing_agent(id) do
    case Agents.get_agent(id) do
      nil ->
        {:error, :not_found}

      %{status: status} when status in ["running", "degraded"] ->
        {:error, :already_running}

      %{status: "recovering"} ->
        {:error, :agent_recovering}

      %{install_status: "removed"} ->
        {:error, :agent_removed}

      %{install_status: "paused"} ->
        {:error, :agent_paused}

      %{install_status: "setup_required"} ->
        {:error, :agent_setup_required}

      agent ->
        case Agents.claim_agent_start(agent.id) do
          {:ok, updated_agent} ->
            case start_agent_process(updated_agent) do
              {:ok, _pid} ->
                Logger.info("Started existing agent #{id}",
                  agent_id: id,
                  behavior: updated_agent.behavior
                )

                {:ok, updated_agent}

              {:error, reason} = error ->
                # `running` is desired state, not process liveness. An ambiguous
                # spawn may already have crossed init, and an owned remote
                # incarnation is also a successful durable intent. Never roll
                # desired state back based on a launcher return classification.
                Logger.error("Failed to start existing agent #{id}: #{inspect(reason)}",
                  agent_id: id
                )

                error
            end

          {:error, reason} = error ->
            Logger.error("Failed to claim agent start #{id}: #{inspect(reason)}", agent_id: id)
            error
        end
    end
  end

  @doc """
  Stop an agent by ID.
  """
  def stop_agent(id, reason \\ "manual_stop") do
    with_agent_lifecycle_lock(id, fn -> do_stop_agent(id, reason) end)
  end

  defp do_stop_agent(id, reason) do
    case Agents.get_agent(id) do
      nil ->
        {:error, :not_found}

      agent ->
        with {:ok, %{agent: stopped_agent} = stop_fence} <- fence_agent_for_stop(agent),
             {:ok, drain_status} <- stop_running_agent(stop_fence, reason),
             :ok <- fence_future_agent_delivery(stopped_agent.id) do
          Logger.info("Persisted Agent stop intent",
            agent_reference: Maraithon.Redaction.fingerprint(id),
            status: "stopped",
            drain_status: drain_status
          )

          {:ok, %{stopped_at: stopped_agent.stopped_at, drain_status: drain_status}}
        end
    end
  end

  @doc """
  Update an existing agent definition. Running agents are stopped, updated, and restarted.
  """
  def update_agent(id, params) when is_binary(id) do
    with_agent_lifecycle_lock(id, fn -> do_update_agent(id, params) end)
  end

  defp do_update_agent(id, params) do
    case Agents.get_agent(id) do
      nil ->
        {:error, :not_found}

      agent ->
        was_running = agent.status in ["recovering", "running", "degraded"]

        with {:ok, stopped_agent} <- stop_for_update(agent, was_running),
             {:ok, updated_agent} <- apply_agent_update(stopped_agent, params),
             {:ok, final_agent} <- maybe_restart(updated_agent, was_running) do
          Logger.info("Updated agent #{id}", agent_id: id, behavior: final_agent.behavior)
          {:ok, final_agent}
        else
          {:error, reason} = error ->
            Logger.error("Failed to update agent #{id}: #{inspect(reason)}", agent_id: id)
            error
        end
    end
  end

  @doc """
  Delete an agent and all dependent runtime records.
  """
  def delete_agent(id) when is_binary(id) do
    with_agent_lifecycle_lock(id, fn -> do_delete_agent(id) end)
  end

  defp do_delete_agent(id) do
    case Agents.get_agent(id) do
      nil ->
        {:error, :not_found}

      agent ->
        with {:ok, %{agent: stopped_agent} = stop_fence} <- fence_agent_for_stop(agent),
             {:ok, drain_status} <- stop_running_agent(stop_fence, "deleted_from_admin"),
             :ok <- fence_future_agent_delivery(stopped_agent.id),
             :ok <- require_agent_quiesced(drain_status),
             {:ok, _deleted_agent} <- Agents.delete_agent(stopped_agent) do
          Logger.info("Deleted agent",
            agent_reference: Maraithon.Redaction.fingerprint(id),
            status: "deleted"
          )

          :ok
        else
          {:error, reason} = error ->
            Logger.error("Failed to delete agent",
              agent_reference: Maraithon.Redaction.fingerprint(id),
              failure_code: Maraithon.Redaction.error_class(reason)
            )

            error
        end
    end
  end

  @doc """
  Soft-remove an installed agent from the user's marketplace workspace.
  """
  def remove_agent_installation(id) when is_binary(id) do
    with_agent_lifecycle_lock(id, fn -> do_remove_agent_installation(id) end)
  end

  defp do_remove_agent_installation(id) do
    case Agents.get_agent(id) do
      nil ->
        {:error, :not_found}

      agent ->
        with {:ok, stopped_agent} <-
               deactivate_agent_installation(agent, "removed_from_marketplace"),
             {:ok, _agent} <- Agents.remove_agent_installation(stopped_agent) do
          Logger.info("Removed agent installation",
            agent_reference: Maraithon.Redaction.fingerprint(id),
            status: "removed"
          )

          :ok
        end
    end
  end

  @doc """
  Pause an installed marketplace agent and cancel all scheduled work.
  """
  def pause_agent_installation(id) when is_binary(id) do
    with_agent_lifecycle_lock(id, fn -> do_pause_agent_installation(id) end)
  end

  defp do_pause_agent_installation(id) do
    case Agents.get_agent(id) do
      nil ->
        {:error, :not_found}

      %{install_status: "removed"} ->
        {:error, :agent_removed}

      agent ->
        with {:ok, stopped_agent} <-
               deactivate_agent_installation(agent, "paused_from_marketplace") do
          Agents.pause_agent_installation(stopped_agent)
        end
    end
  end

  @doc """
  Resume a paused installed marketplace agent and start its runtime process.
  """
  def resume_agent_installation(id) when is_binary(id) do
    with_agent_lifecycle_lock(id, fn -> do_resume_agent_installation(id) end)
  end

  defp do_resume_agent_installation(id) do
    case Agents.get_agent(id, include_removed: true) do
      nil ->
        {:error, :not_found}

      %{install_status: "removed"} ->
        {:error, :agent_removed}

      agent ->
        with {:ok, enabled_agent} <- Agents.resume_agent_installation(agent),
             {:ok, running_agent} <- do_start_existing_agent(enabled_agent.id) do
          {:ok, running_agent}
        end
    end
  end

  @doc """
  Upgrade an installed marketplace agent to a newer package version.
  """
  def upgrade_agent_installation(id, version_id \\ :latest) when is_binary(id) do
    with_agent_lifecycle_lock(id, fn -> do_upgrade_agent_installation(id, version_id) end)
  end

  defp do_upgrade_agent_installation(id, version_id) do
    case Agents.get_agent(id, preload: [:agent_package]) do
      nil ->
        {:error, :not_found}

      %{install_status: "removed"} ->
        {:error, :agent_removed}

      agent ->
        was_running = agent.status in ["recovering", "running", "degraded"]

        with {:ok, stopped_agent} <- stop_for_update(agent, was_running),
             {:ok, upgraded_agent} <- upgrade_agent_version(stopped_agent, version_id),
             {:ok, final_agent} <- maybe_restart(upgraded_agent, was_running) do
          {:ok, final_agent}
        end
    end
  end

  @doc """
  Get detailed status of an agent.
  """
  def get_agent_status(id) do
    case Agents.get_agent(id) do
      nil ->
        {:error, :not_found}

      agent ->
        status = build_status(agent)
        {:ok, status}
    end
  end

  @doc """
  Send a message to an agent.
  """
  def send_message(id, message, metadata \\ %{}) do
    case Agents.get_agent(id) do
      nil ->
        {:error, :not_found}

      %{status: status} when status in ["running", "degraded"] ->
        message_id = Ecto.UUID.generate()
        :ok = Dispatch.dispatch(id, {:message, message, metadata, message_id})
        {:ok, %{message_id: message_id}}

      _agent ->
        {:error, :agent_stopped}
    end
  end

  @doc """
  Send a message to a running agent and wait briefly for a correlated response.
  """
  def request_response(id, message, metadata \\ %{}, opts \\ []) do
    timeout_ms = Keyword.get(opts, :timeout_ms, 12_000)
    poll_interval_ms = Keyword.get(opts, :poll_interval_ms, 250)
    correlation_id = correlation_id(metadata)
    after_seq = Events.latest_sequence_num(id)
    enriched_metadata = put_correlation_id(metadata, correlation_id)

    with {:ok, %{message_id: message_id}} <- send_message(id, message, enriched_metadata) do
      wait_for_agent_response(
        id,
        correlation_id,
        message_id,
        after_seq,
        timeout_ms,
        poll_interval_ms
      )
    end
  end

  @doc """
  Get events for an agent.
  """
  def get_events(id, opts \\ []) do
    case Agents.get_agent(id) do
      nil ->
        {:error, :not_found}

      _agent ->
        events = Events.list_events(id, opts)
        {:ok, events}
    end
  end

  @doc """
  Resume all agents that were running before a restart.
  Called during application startup.
  """
  def resume_all_agents do
    agents = Agents.list_resumable_agents()
    Logger.info("Resuming #{length(agents)} agents")

    case start_resumable_agents(agents) do
      {:ok, _pids} -> :ok
      {:error, _reason} = error -> error
    end
  end

  defp start_resumable_agents(agents) do
    Enum.reduce_while(agents, {:ok, []}, fn agent, {:ok, pids} ->
      case with_agent_lifecycle_lock(agent.id, fn ->
             start_resumable_agent(agent.id,
               resume_trigger: "node_boot",
               admission: :bootstrap
             )
           end) do
        {:ok, pid} when is_pid(pid) ->
          Logger.info("Resumed agent #{agent.id}", agent_id: agent.id)
          {:cont, {:ok, [pid | pids]}}

        {:error, reason}
        when reason in [
               :runtime_lease_owned,
               :agent_restart_backoff,
               :agent_lifecycle_busy,
               :agent_binding_not_active,
               :agent_not_resumable,
               :agent_not_runnable,
               :agent_restart_tripped
             ] ->
          # Another exact node owns it, its durable guard is not due, or
          # desired-state/Binding consent makes it intentionally non-resident.
          # No one legacy row may hold global effect admission closed.
          Logger.info("Deferred exact Agent resume", agent_id: agent.id, reason: inspect(reason))
          {:cont, {:ok, pids}}

        {:error, reason} ->
          Logger.error("Failed to resume agent #{agent.id}: #{inspect(reason)}",
            agent_id: agent.id
          )

          {:halt, {:error, :agent_recovery_incomplete}}
      end
    end)
  end

  @doc """
  Resume a persisted agent after AgentWatcher detects an abnormal process exit.
  """
  def resume_agent_after_crash(id, metadata \\ %{}) when is_binary(id) and is_map(metadata) do
    case AgentRestartGuards.get(id) do
      %{generation: generation, needs_recovery: true, tripped: false} ->
        resume_agent_after_crash(id, generation, metadata)

      _missing_or_stale ->
        {:error, :stale_recovery_generation}
    end
  end

  def resume_agent_after_crash(id, guard_generation, metadata)
      when is_binary(id) and is_binary(guard_generation) and is_map(metadata) do
    with_agent_lifecycle_lock(id, fn ->
      start_resumable_agent(id,
        resume_trigger: "targeted_reresume",
        admission: :recovery,
        recovery_generation: guard_generation,
        metadata: metadata
      )
    end)
  end

  # Private functions

  defp with_agent_lifecycle_lock(id, fun) when is_binary(id) and is_function(fun, 0) do
    # The database row/lease transactions serialize lifecycle authority. A
    # distributed Erlang lock is neither complete (unconnected nodes) nor
    # durable, so it must not gate exact ownership.
    if byte_size(id) in 1..255 and String.valid?(id) do
      fun.()
    else
      {:error, :invalid_agent_id}
    end
  catch
    :exit, _reason -> {:error, :agent_lifecycle_unavailable}
  end

  defp start_resumable_agent(id, opts) do
    case Agents.get_agent(id, include_removed: true) do
      %{status: status, install_status: "enabled"} = agent
      when status in ["running", "degraded"] ->
        start_agent_process(agent, opts)

      nil ->
        {:error, :not_found}

      _inactive_agent ->
        {:error, :agent_not_resumable}
    end
  end

  defp put_recorded_recovery_generation(agent_id, opts) do
    if Keyword.has_key?(opts, :recovery_generation) do
      opts
    else
      case AgentRestartGuards.get(agent_id) do
        %{generation: generation, needs_recovery: true, tripped: false} ->
          Keyword.put(opts, :recovery_generation, generation)

        _no_due_recovery ->
          opts
      end
    end
  end

  defp maybe_start_installed_agent(%{install_status: "enabled", status: "running"} = agent) do
    start_agent_process(agent)
  end

  defp maybe_start_installed_agent(_agent), do: {:ok, :not_started}

  defp start_agent_process(agent, opts \\ []) do
    opts = put_recorded_recovery_generation(agent.id, opts)

    supervisor_opts =
      opts
      |> Keyword.take([:recovery_generation])
      |> Keyword.put(:admission, start_admission(opts))

    case AgentSupervisor.start_agent(agent, supervisor_opts) do
      {:ok, pid} = result ->
        maybe_record_agent_resumed(agent, pid, opts)
        result

      other ->
        other
    end
  end

  defp start_admission(opts) do
    cond do
      Keyword.has_key?(opts, :recovery_generation) -> :recovery
      Keyword.get(opts, :resume_trigger) == "node_boot" -> :bootstrap
      true -> :normal
    end
  end

  defp deactivate_agent_installation(agent, reason) do
    with {:ok, %{agent: stopped_agent} = stop_fence} <- fence_agent_for_stop(agent),
         {:ok, _drain_status} <- stop_running_agent(stop_fence, reason),
         :ok <- fence_future_agent_delivery(stopped_agent.id) do
      {:ok, stopped_agent}
    end
  end

  defp fence_future_agent_delivery(agent_id) do
    case Scheduler.cancel_all(agent_id) do
      {count, _rows} when is_integer(count) ->
        case AgentSubscriptions.deactivate_for_agent(agent_id) do
          {deactivated_count, _subscriptions} when is_integer(deactivated_count) -> :ok
          _unexpected -> {:error, :agent_delivery_fence_failed}
        end

      {:error, reason} ->
        {:error, reason}

      _unexpected ->
        {:error, :agent_delivery_fence_failed}
    end
  rescue
    _error -> {:error, :agent_delivery_fence_failed}
  catch
    :exit, _reason -> {:error, :agent_delivery_fence_failed}
  end

  # Desired state and exact readiness were committed before this function. It
  # may route/wait only after the transaction has ended, and it never performs
  # unfenced broad Effect/run cleanup on behalf of a remote or lost owner.
  defp stop_running_agent(
         %{agent: agent, lease: nil, lost_lease: lost_lease},
         reason
       ) do
    _route_result = route_fenced_agent_stop(agent.id, lost_lease, reason)
    {:ok, :reconciliation_pending}
  end

  defp stop_running_agent(%{agent: agent, lease: nil}, _reason) do
    case lookup_agent_process(agent.id) do
      {:ok, _unfenced_local_pid} ->
        # A rolling legacy/stale PID is not ownership proof. Do not send an
        # unqualified stop that a successor could consume, and do not claim
        # quiescence without an explicit bridge/fleet-drain operation.
        {:ok, :reconciliation_pending}

      :not_running ->
        if exact_work_quiesced?(agent.id),
          do: {:ok, :quiesced},
          else: {:ok, :reconciliation_pending}
    end
  end

  defp stop_running_agent(%{agent: agent, lease: lease}, reason) do
    _route_result = route_fenced_agent_stop(agent.id, lease, reason)

    case AgentLeases.get(agent.id) do
      nil ->
        if exact_work_quiesced?(agent.id),
          do: {:ok, :quiesced},
          else: {:ok, :reconciliation_pending}

      _owned_or_reconciling ->
        {:ok, :reconciliation_pending}
    end
  end

  defp exact_work_quiesced?(agent_id) do
    active_run_pointer? =
      case Agents.get_agent(agent_id, include_removed: true) do
        %{active_run_id: active_run_id} when is_binary(active_run_id) -> true
        _no_active_run -> false
      end

    running_run? =
      Repo.exists?(
        from(run in AgentRun,
          where: run.agent_id == ^agent_id,
          where: run.status == "running"
        )
      )

    requested_run_step? =
      Repo.exists?(
        from(step in AgentRunStep,
          where: step.agent_id == ^agent_id,
          where: step.status == "requested"
        )
      )

    active_effect? =
      Repo.exists?(
        from(effect in Effect,
          where: effect.agent_id == ^agent_id,
          where: effect.status in ["pending", "claimed", "cancelling"]
        )
      )

    processing_directive? =
      Repo.exists?(
        from(directive in AgentDirective,
          where: directive.agent_id == ^agent_id,
          where: directive.status == "processing"
        )
      )

    unresolved_generation? =
      case AgentRestartGuards.get(agent_id) do
        %{needs_recovery: true} -> true
        %{tripped: true} -> true
        _settled_or_absent -> false
      end

    not active_run_pointer? and not running_run? and not requested_run_step? and
      not active_effect? and not processing_directive? and not unresolved_generation?
  rescue
    _error -> false
  catch
    :exit, _reason -> false
  end

  defp require_agent_quiesced(:quiesced), do: :ok
  defp require_agent_quiesced(:reconciliation_pending), do: {:error, :agent_drain_pending}

  defp route_fenced_agent_stop(agent_id, lease, reason) do
    local_node = Atom.to_string(node())

    case Registry.lookup(AgentRegistry, agent_id) do
      [{pid, owner_token}] when is_pid(pid) and owner_token == lease.owner_token ->
        if lease.owner_node == local_node do
          AgentSupervisor.stop_agent(pid, reason, lease.owner_token)
        else
          dispatch_fenced_agent_stop(agent_id, lease.owner_token, reason)
        end

      _not_local_exact_owner ->
        dispatch_fenced_agent_stop(agent_id, lease.owner_token, reason)
    end
  catch
    :exit, _reason -> {:error, :agent_stop_route_unavailable}
  end

  defp dispatch_fenced_agent_stop(agent_id, owner_token, reason) do
    # The immutable token prevents a delayed cross-node stop from killing a
    # successor incarnation after desired state changes again.
    Dispatch.dispatch(agent_id, {:control, :stop, reason, owner_token})
  end

  defp fence_agent_for_stop(agent), do: fence_agent_for_stop(agent, 3, nil)

  defp fence_agent_for_stop(_agent, 0, _lost_lease),
    do: {:error, :agent_stop_reconciliation_pending}

  defp fence_agent_for_stop(agent, attempts_remaining, lost_lease) do
    case AgentLeases.fence_for_stop(agent.id) do
      {:ok, stop_fence} ->
        stop_fence =
          if lost_lease, do: Map.put(stop_fence, :lost_lease, lost_lease), else: stop_fence

        {:ok, stop_fence}

      {:error, {:expired_lease_requires_reconciliation, expired_lease}} ->
        # Expired ownership is recorded before desired state is changed. A
        # concurrent renewal or reconciler is benign; retry the exact fence.
        case AgentRestartGuards.record_expired(agent.id, expired_lease.owner_token) do
          {:recorded, _guard} ->
            fence_agent_for_stop(agent, attempts_remaining - 1, expired_lease)

          {:duplicate, _guard} ->
            fence_agent_for_stop(agent, attempts_remaining - 1, expired_lease)

          {:ignored, :lease_renewed} ->
            fence_agent_for_stop(agent, attempts_remaining - 1, nil)

          {:ignored, _reason} ->
            fence_agent_for_stop(agent, attempts_remaining - 1, expired_lease)

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp lookup_agent_process(id) do
    case Registry.lookup(AgentRegistry, id) do
      [{pid, _routing_metadata}] when is_pid(pid) -> {:ok, pid}
      [] -> :not_running
    end
  end

  defp build_status(agent) do
    base = %{
      id: agent.id,
      project_id: agent.project_id,
      status: agent.status,
      behavior: agent.behavior,
      started_at: agent.started_at,
      stopped_at: agent.stopped_at,
      config: agent.config
    }

    # Add runtime info if process is running
    case lookup_agent_process(agent.id) do
      {:ok, pid} ->
        runtime_info = get_runtime_info(pid)
        Map.merge(base, %{runtime: runtime_info})

      :not_running ->
        base
    end
  end

  defp get_runtime_info(pid) do
    try do
      # This would call into the agent process for live stats
      # For now, return basic process info
      info = Process.info(pid, [:message_queue_len, :memory])

      %{
        pid: inspect(pid),
        message_queue_len: info[:message_queue_len],
        memory_bytes: info[:memory]
      }
    rescue
      _ -> %{}
    end
  end

  defp default_budget do
    %{
      "llm_calls" => 500,
      "tool_calls" => 1000
    }
  end

  defp maybe_record_agent_resumed(agent, pid, opts) do
    case Keyword.get(opts, :resume_trigger) do
      nil ->
        :ok

      trigger ->
        metadata =
          %{
            "resume_trigger" => trigger,
            "behavior" => agent.behavior,
            "user_id" => agent.user_id,
            "pid" => inspect(pid)
          }
          |> Map.merge(Keyword.get(opts, :metadata, %{}))

        IncidentLog.record(%{
          kind: :agent_resumed,
          agent_id: agent.id,
          metadata: metadata
        })

        :ok
    end
  end

  defp stop_for_update(%{status: "terminated"} = agent, false), do: {:ok, agent}

  defp stop_for_update(agent, _was_running) do
    with {:ok, %{agent: stopped_agent} = stop_fence} <- fence_agent_for_stop(agent),
         {:ok, drain_status} <-
           stop_running_agent(stop_fence, "restarting_with_updated_config"),
         :ok <- fence_future_agent_delivery(stopped_agent.id),
         :ok <- require_agent_quiesced(drain_status) do
      {:ok, stopped_agent}
    end
  end

  defp apply_agent_update(agent, params) do
    existing_config = agent.config || %{}
    incoming_config = params["config"] || params[:config] || %{}
    behavior = params["behavior"] || params[:behavior] || agent.behavior

    config =
      case incoming_config do
        map when is_map(map) -> Map.merge(existing_config, map)
        _ -> existing_config
      end

    attrs = %{
      behavior: behavior,
      config: config
    }

    attrs =
      case fetch_optional_param(params, "user_id") do
        :missing -> attrs
        value -> Map.put(attrs, :user_id, normalize_optional_string(value))
      end

    attrs =
      case fetch_optional_param(params, "project_id") do
        :missing -> attrs
        value -> Map.put(attrs, :project_id, normalize_optional_string(value))
      end

    budget = params["budget"] || params[:budget] || Map.get(existing_config, "budget")

    attrs =
      if is_map(budget) do
        put_in(attrs, [:config, "budget"], budget)
      else
        attrs
      end

    Agents.update_agent(agent, attrs)
  end

  defp maybe_restart(agent, false), do: {:ok, agent}

  defp maybe_restart(agent, true), do: do_start_existing_agent(agent.id)

  defp upgrade_agent_version(agent, :latest),
    do: Agents.upgrade_agent_installation_to_latest(agent)

  defp upgrade_agent_version(agent, version_id) when is_binary(version_id),
    do: Agents.upgrade_agent_installation(agent, version_id)

  defp wait_for_agent_response(
         id,
         correlation_id,
         message_id,
         _after_seq,
         timeout_ms,
         _poll_interval_ms
       )
       when timeout_ms <= 0 do
    {:ok,
     %{
       status: "queued",
       agent_id: id,
       correlation_id: correlation_id,
       message_id: message_id
     }}
  end

  defp wait_for_agent_response(
         id,
         correlation_id,
         message_id,
         after_seq,
         timeout_ms,
         poll_interval_ms
       ) do
    case matching_agent_response(id, correlation_id, message_id, after_seq) do
      {:ok, event} ->
        {:ok,
         %{
           status: response_status(event.event_type),
           agent_id: id,
           correlation_id: correlation_id,
           message_id: message_id,
           response: event.payload["response"] || event.payload[:response],
           error: event.payload["error"] || event.payload[:error],
           event_type: event.event_type
         }}

      :not_found ->
        wait_time = min(timeout_ms, poll_interval_ms)

        receive do
        after
          wait_time ->
            wait_for_agent_response(
              id,
              correlation_id,
              message_id,
              after_seq,
              timeout_ms - wait_time,
              poll_interval_ms
            )
        end
    end
  end

  defp matching_agent_response(id, correlation_id, message_id, after_seq) do
    id
    |> Events.list_events(
      after_seq: after_seq,
      limit: 50,
      types: ["agent_response", "agent_error"]
    )
    |> Enum.find(fn event ->
      payload = event.payload || %{}

      event_message_id = payload["message_id"] || payload[:message_id]
      event_correlation_id = payload["correlation_id"] || payload[:correlation_id]

      event_message_id == message_id or event_correlation_id == correlation_id
    end)
    |> case do
      nil -> :not_found
      event -> {:ok, event}
    end
  end

  defp response_status("agent_error"), do: "error"
  defp response_status(_event_type), do: "completed"

  defp correlation_id(metadata) when is_map(metadata) do
    metadata["correlation_id"] || metadata[:correlation_id] || Ecto.UUID.generate()
  end

  defp correlation_id(_metadata), do: Ecto.UUID.generate()

  defp put_correlation_id(metadata, correlation_id) when is_map(metadata) do
    metadata
    |> Map.delete(:correlation_id)
    |> Map.put("correlation_id", correlation_id)
  end

  defp put_correlation_id(_metadata, correlation_id), do: %{"correlation_id" => correlation_id}

  defp fetch_optional_param(params, key) when is_map(params) do
    cond do
      Map.has_key?(params, key) -> Map.get(params, key)
      key == "user_id" and Map.has_key?(params, :user_id) -> Map.get(params, :user_id)
      key == "project_id" and Map.has_key?(params, :project_id) -> Map.get(params, :project_id)
      true -> :missing
    end
  end

  defp normalize_optional_string(nil), do: nil
  defp normalize_optional_string(""), do: nil
  defp normalize_optional_string(value) when is_binary(value), do: String.trim(value)
  defp normalize_optional_string(value), do: value
end
