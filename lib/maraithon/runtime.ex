defmodule Maraithon.Runtime do
  @moduledoc """
  Runtime facade for managing agents.
  Provides the main API for starting, stopping, and interacting with agents.
  """

  alias Maraithon.Agents
  alias Maraithon.AgentSubscriptions
  alias Maraithon.Runtime.AgentSupervisor
  alias Maraithon.Runtime.AgentRegistry
  alias Maraithon.Runtime.Dispatch
  alias Maraithon.Events
  alias Maraithon.Runtime.BackgroundJobs
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
         {:ok, _pid} <- start_agent_process(agent) do
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
  Start an existing persisted agent by ID.
  """
  def start_existing_agent(id) when is_binary(id) do
    case Agents.get_agent(id) do
      nil ->
        {:error, :not_found}

      %{status: status} when status in ["running", "degraded"] ->
        {:error, :already_running}

      %{install_status: "removed"} ->
        {:error, :agent_removed}

      %{install_status: "paused"} ->
        {:error, :agent_paused}

      %{install_status: "setup_required"} ->
        {:error, :agent_setup_required}

      agent ->
        running_attrs = %{status: "running", started_at: DateTime.utc_now(), stopped_at: nil}

        with {:ok, updated_agent} <- Agents.update_agent(agent, running_attrs),
             {:ok, _pid} <- start_agent_process(updated_agent) do
          Logger.info("Started existing agent #{id}",
            agent_id: id,
            behavior: updated_agent.behavior
          )

          {:ok, updated_agent}
        else
          {:error, reason} = error ->
            _ = Agents.update_agent(agent, %{status: "stopped", stopped_at: DateTime.utc_now()})
            Logger.error("Failed to start existing agent #{id}: #{inspect(reason)}", agent_id: id)
            error
        end
    end
  end

  @doc """
  Stop an agent by ID.
  """
  def stop_agent(id, reason \\ "manual_stop") do
    case Agents.get_agent(id) do
      nil ->
        {:error, :not_found}

      agent ->
        stop_running_agent(agent, reason)
        {:ok, agent} = Agents.mark_stopped(agent)

        Logger.info("Stopped agent #{id}", agent_id: id, reason: reason)
        {:ok, %{stopped_at: agent.stopped_at}}
    end
  end

  @doc """
  Update an existing agent definition. Running agents are stopped, updated, and restarted.
  """
  def update_agent(id, params) when is_binary(id) do
    case Agents.get_agent(id) do
      nil ->
        {:error, :not_found}

      agent ->
        was_running = agent.status in ["running", "degraded"]

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
    case Agents.get_agent(id) do
      nil ->
        {:error, :not_found}

      agent ->
        stop_running_agent(agent, "deleted_from_admin")

        case Agents.delete_agent(agent) do
          {:ok, _agent} ->
            Logger.info("Deleted agent #{id}", agent_id: id)
            :ok

          {:error, reason} = error ->
            Logger.error("Failed to delete agent #{id}: #{inspect(reason)}", agent_id: id)
            error
        end
    end
  end

  @doc """
  Soft-remove an installed agent from the user's marketplace workspace.
  """
  def remove_agent_installation(id) when is_binary(id) do
    case Agents.get_agent(id) do
      nil ->
        {:error, :not_found}

      agent ->
        deactivate_agent_installation(agent, "removed_from_marketplace")

        with {:ok, _agent} <- Agents.remove_agent_installation(agent) do
          Logger.info("Removed agent installation #{id}", agent_id: id)
          :ok
        end
    end
  end

  @doc """
  Pause an installed marketplace agent and cancel all scheduled work.
  """
  def pause_agent_installation(id) when is_binary(id) do
    case Agents.get_agent(id) do
      nil ->
        {:error, :not_found}

      %{install_status: "removed"} ->
        {:error, :agent_removed}

      agent ->
        deactivate_agent_installation(agent, "paused_from_marketplace")
        Agents.pause_agent_installation(agent)
    end
  end

  @doc """
  Resume a paused installed marketplace agent and start its runtime process.
  """
  def resume_agent_installation(id) when is_binary(id) do
    case Agents.get_agent(id, include_removed: true) do
      nil ->
        {:error, :not_found}

      %{install_status: "removed"} ->
        {:error, :agent_removed}

      agent ->
        with {:ok, enabled_agent} <- Agents.resume_agent_installation(agent),
             {:ok, running_agent} <- start_existing_agent(enabled_agent.id) do
          {:ok, running_agent}
        end
    end
  end

  @doc """
  Upgrade an installed marketplace agent to a newer package version.
  """
  def upgrade_agent_installation(id, version_id \\ :latest) when is_binary(id) do
    case Agents.get_agent(id, preload: [:agent_package]) do
      nil ->
        {:error, :not_found}

      %{install_status: "removed"} ->
        {:error, :agent_removed}

      agent ->
        was_running = agent.status in ["running", "degraded"]

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

    Enum.each(agents, fn agent ->
      case start_agent_process(agent) do
        {:ok, _pid} ->
          Logger.info("Resumed agent #{agent.id}", agent_id: agent.id)

        {:error, reason} ->
          Logger.error("Failed to resume agent #{agent.id}: #{inspect(reason)}",
            agent_id: agent.id
          )
      end
    end)
  end

  # Private functions

  defp start_agent_process(agent) do
    AgentSupervisor.start_agent(agent)
  end

  defp stop_agent_process(id) do
    case lookup_agent_process(id) do
      {:ok, pid} ->
        AgentSupervisor.stop_agent(pid)

      :not_running ->
        :ok
    end
  end

  defp deactivate_agent_installation(agent, reason) do
    stop_running_agent(agent, reason)
    Scheduler.cancel_all(agent.id)
    AgentSubscriptions.deactivate_for_agent(agent.id)
    :ok
  end

  defp stop_running_agent(agent, reason) do
    if running_agent?(agent) do
      Dispatch.dispatch(agent.id, {:control, :stop, reason})
      stop_agent_process(agent.id)
    end

    :ok
  end

  defp running_agent?(%{status: status}), do: status in ["running", "degraded"]
  defp running_agent?(_agent), do: false

  defp lookup_agent_process(id) do
    case Registry.lookup(AgentRegistry, id) do
      [{pid, _}] -> {:ok, pid}
      [] -> lookup_global_agent_process(id)
    end
  end

  defp lookup_global_agent_process(id) do
    case :global.whereis_name({:maraithon_agent, id}) do
      pid when is_pid(pid) -> {:ok, pid}
      :undefined -> :not_running
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

  defp stop_for_update(agent, false), do: {:ok, agent}

  defp stop_for_update(agent, true) do
    stop_running_agent(agent, "restarting_with_updated_config")
    Agents.mark_stopped(agent)
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

  defp maybe_restart(agent, true) do
    running_attrs = %{status: "running", started_at: DateTime.utc_now(), stopped_at: nil}

    with {:ok, running_agent} <- Agents.update_agent(agent, running_attrs),
         {:ok, _pid} <- start_agent_process(running_agent) do
      {:ok, running_agent}
    else
      {:error, reason} ->
        _ = Agents.update_agent(agent, %{status: "stopped", stopped_at: DateTime.utc_now()})
        {:error, reason}
    end
  end

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
