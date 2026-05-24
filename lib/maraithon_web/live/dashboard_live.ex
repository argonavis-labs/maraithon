defmodule MaraithonWeb.DashboardLive do
  use MaraithonWeb, :live_view

  alias Maraithon.AgentBuilder
  alias Maraithon.Admin
  alias Maraithon.AgentMarketplace
  alias Maraithon.Agents
  alias Maraithon.Behaviors
  alias Maraithon.BriefingSchedules
  alias Maraithon.Connections
  alias Maraithon.Insights.Detail
  alias Maraithon.Insights
  alias Maraithon.OnboardingProof
  alias Maraithon.OperatorMemory
  alias Maraithon.PreferenceMemory
  alias Maraithon.Projects
  alias Maraithon.Projects.ProjectItem
  alias Maraithon.Runtime
  alias Maraithon.Todos
  alias Maraithon.UserMemory

  @refresh_interval 5_000
  @event_limit 50
  @activity_limit 40
  @failure_limit 20

  @impl true
  def mount(_params, _session, socket) do
    user_id = current_user_id(socket)

    socket =
      socket
      |> assign(
        page_title: "Control Center",
        behaviors: Behaviors.list() |> Enum.sort(),
        launch: default_launch_params(),
        launch_error: nil,
        launch_mode: :create,
        editing_agent_id: nil,
        command: %{"message" => ""},
        agents: [],
        selected_agent: nil,
        events: [],
        inspection: empty_inspection(),
        total_spend: empty_spend(),
        agent_spend: nil,
        health: %{
          status: :unknown,
          checks: %{
            database: :unknown,
            agents: %{running: 0, degraded: 0, stopped: 0},
            memory_mb: 0,
            uptime_seconds: 0
          },
          version: nil
        },
        queue_metrics: %{
          effects: %{pending: 0, claimed: 0, completed: 0, failed: 0},
          jobs: %{pending: 0, dispatched: 0, delivered: 0, cancelled: 0}
        },
        recent_activity: [],
        recent_failures: [],
        recent_logs: [],
        fly_logs: empty_fly_logs(),
        connection_user_id: user_id,
        connection_return_to: "/dashboard",
        current_path: "/dashboard",
        connected_provider_count: 0,
        connections: [],
        raw_connections: [],
        connection_errors: [],
        chief_of_staff_package: nil,
        chief_of_staff_readiness: [],
        chief_of_staff_agent: nil,
        chief_of_staff_schedule: BriefingSchedules.summarize_for_prompt(nil),
        dashboard_errors: [],
        inspection_errors: [],
        global_memory_summaries: [],
        memory_profile: empty_memory_profile(),
        memory_rules: [],
        todos: [],
        open_todo_count: 0,
        todo_review_index: 0,
        todo_review_session: %{completed: 0, dismissed: 0, kept: 0, important: 0},
        todo_review_decided_ids: MapSet.new(),
        projects: [],
        agent_overviews: [],
        project_form: to_form(default_project_form_params(), as: :project),
        project_item_form: to_form(default_project_item_form_params(), as: :project_item),
        project_item_types: ProjectItem.item_types(),
        insights: [],
        act_now_insights: [],
        monitor_insights: [],
        expanded_insight_ids: MapSet.new(),
        detail_opened_insight_ids: MapSet.new(),
        onboarding_preview: empty_onboarding_preview(),
        onboarding_preview_eligible?: OnboardingProof.eligible?(user_id)
      )

    socket =
      if connected?(socket) do
        :timer.send_interval(@refresh_interval, self(), :refresh)
        send(self(), :load_fly_logs)
        refresh_dashboard(socket)
      else
        socket
      end

    {:ok, socket}
  end

  @impl true
  def handle_params(params, uri, socket) do
    socket =
      socket
      |> assign(:current_path, current_path_from_uri(uri))
      |> apply_dashboard_params(params, uri)

    case legacy_agents_path(params) do
      nil ->
        {:noreply,
         assign(socket,
           selected_agent: nil,
           events: [],
           agent_spend: nil,
           inspection: empty_inspection(),
           inspection_errors: [],
           page_title: "Control Center"
         )}

      to ->
        {:noreply, push_navigate(socket, to: to)}
    end
  end

  @impl true
  def handle_info(:refresh, socket) do
    {:noreply, refresh_dashboard(socket)}
  end

  def handle_info(:load_fly_logs, socket) do
    {:noreply, refresh_fly_logs(socket)}
  end

  @impl true
  def handle_async(:onboarding_preview, {:ok, {:ok, preview}}, socket) do
    {:noreply,
     assign(socket,
       onboarding_preview: %{
         status: :ready,
         items: preview.items,
         sources: preview.sources,
         generated_at: preview.generated_at,
         error: nil
       }
     )}
  end

  def handle_async(:onboarding_preview, {:ok, {:error, reason}}, socket) do
    {:noreply,
     assign(socket,
       onboarding_preview: %{
         status: :error,
         items: [],
         sources: [],
         generated_at: nil,
         error: inspect(reason)
       }
     )}
  end

  def handle_async(:onboarding_preview, {:exit, reason}, socket) do
    {:noreply,
     assign(socket,
       onboarding_preview: %{
         status: :error,
         items: [],
         sources: [],
         generated_at: nil,
         error: inspect(reason)
       }
     )}
  end

  @impl true
  def handle_event("refresh_now", _params, socket) do
    send(self(), :load_fly_logs)

    {:noreply,
     socket
     |> refresh_dashboard()
     |> put_flash(:info, "Dashboard refreshed")}
  end

  def handle_event("refresh_onboarding_preview", _params, socket) do
    {:noreply,
     socket
     |> assign(:onboarding_preview, empty_onboarding_preview())
     |> maybe_start_onboarding_preview(force: true)}
  end

  def handle_event("refresh_fly_logs", _params, socket) do
    send(self(), :load_fly_logs)
    {:noreply, put_flash(socket, :info, "Fly logs refresh started")}
  end

  def handle_event("disconnect_connection", %{"provider" => provider}, socket) do
    case Connections.disconnect(socket.assigns.connection_user_id, provider) do
      {:ok, _deleted} ->
        {:noreply,
         socket
         |> refresh_connections()
         |> put_flash(:info, "#{provider_label(provider)} disconnected")}

      {:error, :no_token} ->
        {:noreply,
         socket
         |> refresh_connections()
         |> put_flash(:error, "#{provider_label(provider)} is not connected")}

      {:error, :unsupported_provider} ->
        {:noreply, put_flash(socket, :error, "Unsupported provider")}

      {:error, reason} ->
        {:noreply,
         socket
         |> refresh_connections()
         |> put_flash(
           :error,
           "Failed to disconnect #{provider_label(provider)}: #{inspect(reason)}"
         )}
    end
  end

  def handle_event("update_project_form", %{"project" => params}, socket) do
    {:noreply,
     assign(
       socket,
       :project_form,
       to_form(Map.merge(default_project_form_params(), params), as: :project)
     )}
  end

  def handle_event("create_project", %{"project" => params}, socket) do
    attrs = Map.take(params, ["name", "summary", "description", "priority"])

    case Projects.create_project(current_user_id(socket), attrs) do
      {:ok, project} ->
        {:noreply,
         socket
         |> assign(:project_form, to_form(default_project_form_params(), as: :project))
         |> assign(
           :project_item_form,
           to_form(
             default_project_item_form_params()
             |> Map.put("project_id", project.id),
             as: :project_item
           )
         )
         |> refresh_dashboard()
         |> put_flash(:info, "Project created")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply,
         socket
         |> assign(
           :project_form,
           to_form(Map.merge(default_project_form_params(), params), as: :project)
         )
         |> put_flash(:error, "Failed to create project: #{changeset_errors(changeset)}")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to create project: #{inspect(reason)}")}
    end
  end

  def handle_event("update_project_item_form", %{"project_item" => params}, socket) do
    {:noreply,
     assign(
       socket,
       :project_item_form,
       to_form(Map.merge(default_project_item_form_params(), params), as: :project_item)
     )}
  end

  def handle_event("create_project_item", %{"project_item" => params}, socket) do
    project_id = Map.get(params, "project_id")
    attrs = Map.take(params, ["item_type", "title", "content"])

    case Projects.create_project_item(project_id, current_user_id(socket), attrs) do
      {:ok, _item} ->
        {:noreply,
         socket
         |> assign(
           :project_item_form,
           to_form(
             default_project_item_form_params()
             |> Map.put("project_id", project_id || ""),
             as: :project_item
           )
         )
         |> refresh_dashboard()
         |> put_flash(:info, "Project memory saved")}

      {:error, :project_not_found} ->
        {:noreply,
         socket
         |> assign(
           :project_item_form,
           to_form(Map.merge(default_project_item_form_params(), params), as: :project_item)
         )
         |> put_flash(:error, "Choose a valid project first")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply,
         socket
         |> assign(
           :project_item_form,
           to_form(Map.merge(default_project_item_form_params(), params), as: :project_item)
         )
         |> put_flash(:error, "Failed to save project memory: #{changeset_errors(changeset)}")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to save project memory: #{inspect(reason)}")}
    end
  end

  def handle_event("install_chief_of_staff", params, socket) do
    user_id = current_user_id(socket)
    project_id = Map.get(params, "project_id") || first_project_id(socket.assigns.projects)

    cond do
      is_nil(project_id) ->
        {:noreply, put_flash(socket, :error, "Create a project before installing Chief of Staff")}

      true ->
        case Runtime.install_chief_of_staff(user_id,
               project_id: project_id,
               delivery_policy: %{"telegram" => "enabled"}
             ) do
          {:ok, %{install_status: "setup_required"} = agent} ->
            {:noreply,
             socket
             |> refresh_dashboard()
             |> put_flash(
               :info,
               "Chief of Staff installed. Connect the missing services to enable briefs."
             )
             |> push_navigate(to: "/agents?id=#{agent.id}&panel=apps")}

          {:ok, agent} ->
            {:noreply,
             socket
             |> refresh_dashboard()
             |> put_flash(:info, "Chief of Staff installed")
             |> push_navigate(to: "/agents?id=#{agent.id}&panel=inspect")}

          {:error, :project_not_found} ->
            {:noreply, put_flash(socket, :error, "Choose a valid project before installing")}

          {:error, %Ecto.Changeset{} = changeset} ->
            {:noreply,
             put_flash(socket, :error, "Could not install: #{changeset_errors(changeset)}")}

          {:error, reason} ->
            {:noreply, put_flash(socket, :error, "Could not install: #{inspect(reason)}")}
        end
    end
  end

  def handle_event("decide_project_recommendation", params, socket) do
    user_id = current_user_id(socket)

    case Projects.decide_project_recommendation(
           params["project_id"],
           user_id,
           params["recommendation_id"],
           %{"decision" => params["decision"]}
         ) do
      {:ok, _record} ->
        {:noreply,
         socket
         |> refresh_dashboard()
         |> put_flash(:info, "Recommendation #{decision_label(params["decision"])}")}

      {:error, :project_not_found} ->
        {:noreply, socket |> refresh_dashboard() |> put_flash(:error, "Project not found")}

      {:error, :recommendation_not_found} ->
        {:noreply, socket |> refresh_dashboard() |> put_flash(:error, "Recommendation not found")}

      {:error, reason} ->
        {:noreply,
         put_flash(socket, :error, "Failed to save recommendation decision: #{inspect(reason)}")}
    end
  end

  def handle_event("grant_project_repo_access", params, socket) do
    user_id = current_user_id(socket)

    case Projects.grant_project_repo_access(params["project_id"], user_id, %{
           "repo_full_name" => params["repo_full_name"],
           "scope" => params["scope"]
         }) do
      {:ok, grant} ->
        {:noreply,
         socket
         |> refresh_dashboard()
         |> put_flash(
           :info,
           "Granted #{repo_scope_label(grant.scope)} access for #{grant.repo_full_name}"
         )}

      {:error, :project_not_found} ->
        {:noreply, socket |> refresh_dashboard() |> put_flash(:error, "Project not found")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to grant repo access: #{inspect(reason)}")}
    end
  end

  def handle_event("start_project_implementation_run", params, socket) do
    user_id = current_user_id(socket)

    case Projects.start_implementation_run(params["project_id"], user_id, %{
           "recommendation_id" => params["recommendation_id"]
         }) do
      {:ok, run} ->
        {:noreply,
         socket
         |> refresh_dashboard()
         |> put_flash(:info, run.result_summary || "Implementation run started")}

      {:error, :project_not_found} ->
        {:noreply, socket |> refresh_dashboard() |> put_flash(:error, "Project not found")}

      {:error, :recommendation_not_found} ->
        {:noreply, socket |> refresh_dashboard() |> put_flash(:error, "Recommendation not found")}

      {:error, reason} ->
        {:noreply,
         put_flash(socket, :error, "Failed to start implementation run: #{inspect(reason)}")}
    end
  end

  def handle_event("complete_todo", %{"id" => todo_id}, socket) do
    case Todos.mark_done(current_user_id(socket), todo_id, note: "Completed from dashboard.") do
      {:ok, _todo} ->
        {:noreply,
         socket
         |> refresh_dashboard()
         |> put_flash(:info, "Todo completed")}

      {:error, :not_found} ->
        {:noreply, socket |> refresh_dashboard() |> put_flash(:error, "Todo not found")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to complete todo: #{inspect(reason)}")}
    end
  end

  def handle_event("dismiss_todo", %{"id" => todo_id}, socket) do
    case Todos.dismiss(current_user_id(socket), todo_id, note: "Dismissed from dashboard.") do
      {:ok, _todo} ->
        {:noreply,
         socket
         |> refresh_dashboard()
         |> put_flash(:info, "Todo dismissed")}

      {:error, :not_found} ->
        {:noreply, socket |> refresh_dashboard() |> put_flash(:error, "Todo not found")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to dismiss todo: #{inspect(reason)}")}
    end
  end

  def handle_event("review_previous_todo", _params, socket) do
    previous_index = socket.assigns.todo_review_index - 1
    reviewable_count = reviewable_todo_count(socket)

    {:noreply,
     assign(
       socket,
       :todo_review_index,
       clamp_review_index(previous_index, reviewable_count)
     )}
  end

  def handle_event("review_next_todo", _params, socket) do
    next_index = socket.assigns.todo_review_index + 1
    reviewable_count = reviewable_todo_count(socket)

    {:noreply,
     assign(
       socket,
       :todo_review_index,
       clamp_review_index(next_index, reviewable_count)
     )}
  end

  def handle_event("review_keep_todo", %{"id" => todo_id}, socket) do
    socket = mark_todo_reviewed(socket, todo_id)

    {:noreply,
     socket
     |> increment_todo_review_session(:kept)
     |> clamp_todo_review_index()}
  end

  def handle_event("review_complete_todo", %{"id" => todo_id}, socket) do
    case Todos.mark_done(current_user_id(socket), todo_id,
           note: "Completed from dashboard review."
         ) do
      {:ok, _todo} ->
        {:noreply,
         socket
         |> mark_todo_reviewed(todo_id)
         |> increment_todo_review_session(:completed)
         |> refresh_dashboard()
         |> put_flash(:info, "Todo completed")}

      {:error, :not_found} ->
        {:noreply, socket |> refresh_dashboard() |> put_flash(:error, "Todo not found")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to complete todo: #{inspect(reason)}")}
    end
  end

  def handle_event("review_dismiss_todo", %{"id" => todo_id}, socket) do
    case Todos.dismiss(current_user_id(socket), todo_id, note: "Dismissed from dashboard review.") do
      {:ok, _todo} ->
        {:noreply,
         socket
         |> mark_todo_reviewed(todo_id)
         |> increment_todo_review_session(:dismissed)
         |> refresh_dashboard()
         |> put_flash(:info, "Todo dismissed")}

      {:error, :not_found} ->
        {:noreply, socket |> refresh_dashboard() |> put_flash(:error, "Todo not found")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to dismiss todo: #{inspect(reason)}")}
    end
  end

  def handle_event("review_mark_important", %{"id" => todo_id}, socket) do
    case Todos.mark_important(current_user_id(socket), todo_id, source: "dashboard_review") do
      {:ok, _todo} ->
        {:noreply,
         socket
         |> mark_todo_reviewed(todo_id)
         |> increment_todo_review_session(:important)
         |> refresh_dashboard()
         |> put_flash(:info, "Todo marked important")}

      {:error, :not_found} ->
        {:noreply, socket |> refresh_dashboard() |> put_flash(:error, "Todo not found")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to mark important: #{inspect(reason)}")}
    end
  end

  def handle_event("toggle_insight_detail", %{"id" => insight_id}, socket) do
    case insight_card(socket, insight_id) do
      %{insight: insight, detail: detail} ->
        expanded? = MapSet.member?(socket.assigns.expanded_insight_ids, insight_id)

        expanded_insight_ids =
          if expanded? do
            MapSet.delete(socket.assigns.expanded_insight_ids, insight_id)
          else
            MapSet.put(socket.assigns.expanded_insight_ids, insight_id)
          end

        detail_opened_insight_ids =
          if expanded? do
            socket.assigns.detail_opened_insight_ids
          else
            MapSet.put(socket.assigns.detail_opened_insight_ids, insight_id)
          end

        emit_insight_detail_toggle_telemetry(expanded?, insight, detail)

        {:noreply,
         assign(socket,
           expanded_insight_ids: expanded_insight_ids,
           detail_opened_insight_ids: detail_opened_insight_ids
         )}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("ack_insight", %{"id" => insight_id}, socket) do
    card = insight_card(socket, insight_id)

    case Insights.acknowledge(current_user_id(socket), insight_id) do
      {:ok, _insight} ->
        maybe_emit_insight_action_telemetry(socket, "acknowledge", card, insight_id)

        {:noreply, socket |> refresh_insights() |> put_flash(:info, "Insight acknowledged")}

      {:error, :not_found} ->
        {:noreply, socket |> refresh_insights() |> put_flash(:error, "Insight not found")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to acknowledge insight: #{inspect(reason)}")}
    end
  end

  def handle_event("dismiss_insight", %{"id" => insight_id}, socket) do
    card = insight_card(socket, insight_id)

    case Insights.dismiss(current_user_id(socket), insight_id) do
      {:ok, _insight} ->
        maybe_emit_insight_action_telemetry(socket, "dismiss", card, insight_id)

        {:noreply, socket |> refresh_insights() |> put_flash(:info, "Insight dismissed")}

      {:error, :not_found} ->
        {:noreply, socket |> refresh_insights() |> put_flash(:error, "Insight not found")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to dismiss insight: #{inspect(reason)}")}
    end
  end

  def handle_event("snooze_insight", %{"id" => insight_id}, socket) do
    snooze_until = DateTime.add(DateTime.utc_now(), 4, :hour)
    card = insight_card(socket, insight_id)

    case Insights.snooze(current_user_id(socket), insight_id, snooze_until) do
      {:ok, _insight} ->
        maybe_emit_insight_action_telemetry(socket, "snooze", card, insight_id)

        {:noreply,
         socket
         |> refresh_insights()
         |> put_flash(:info, "Insight snoozed for 4 hours")}

      {:error, :not_found} ->
        {:noreply, socket |> refresh_insights() |> put_flash(:error, "Insight not found")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to snooze insight: #{inspect(reason)}")}
    end
  end

  def handle_event("new_agent", _params, socket) do
    {:noreply,
     assign(socket,
       launch: default_launch_params(),
       launch_error: nil,
       launch_mode: :create,
       editing_agent_id: nil
     )}
  end

  def handle_event("edit_agent", %{"id" => id}, socket) do
    case Agents.get_agent_for_user(id, current_user_id(socket)) do
      nil ->
        {:noreply, socket |> refresh_dashboard() |> put_flash(:error, "Agent not found")}

      agent ->
        {:noreply,
         assign(socket,
           launch: launch_params_from_agent(agent),
           launch_error: nil,
           launch_mode: :edit,
           editing_agent_id: id
         )}
    end
  end

  def handle_event("launch_agent", %{"launch" => params}, socket) do
    launch = normalize_launch_params(params)

    with {:ok, start_params} <- build_agent_start_params(launch, current_user_id(socket)) do
      save_agent(socket, launch, start_params)
    else
      {:error, message} when is_binary(message) ->
        {:noreply, assign(socket, launch: launch, launch_error: message)}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply,
         assign(socket,
           launch: launch,
           launch_error: "Failed to save agent: #{changeset_errors(changeset)}"
         )}

      {:error, reason} ->
        {:noreply,
         assign(socket,
           launch: launch,
           launch_error: "Failed to save agent: #{inspect(reason)}"
         )}
    end
  end

  def handle_event("start_agent", %{"id" => id}, socket) do
    if agent_owned_by_current_user?(socket, id) do
      case Runtime.start_existing_agent(id) do
        {:ok, _agent} ->
          {:noreply,
           socket
           |> refresh_dashboard()
           |> refresh_if_selected(id)
           |> put_flash(:info, "Agent started")}

        {:error, :already_running} ->
          {:noreply,
           socket |> refresh_dashboard() |> put_flash(:info, "Agent is already running")}

        {:error, :not_found} ->
          {:noreply, socket |> refresh_dashboard() |> put_flash(:error, "Agent not found")}

        {:error, reason} ->
          {:noreply,
           socket
           |> refresh_dashboard()
           |> put_flash(:error, "Failed to start agent: #{inspect(reason)}")}
      end
    else
      {:noreply, socket |> refresh_dashboard() |> put_flash(:error, "Agent not found")}
    end
  end

  def handle_event("stop_agent", %{"id" => id}, socket) do
    if agent_owned_by_current_user?(socket, id) do
      case Runtime.stop_agent(id, "stopped_from_admin") do
        {:ok, _} ->
          {:noreply,
           socket
           |> refresh_dashboard()
           |> refresh_if_selected(id)
           |> put_flash(:info, "Agent stopped")}

        {:error, :not_found} ->
          {:noreply, socket |> refresh_dashboard() |> put_flash(:error, "Agent not found")}
      end
    else
      {:noreply, socket |> refresh_dashboard() |> put_flash(:error, "Agent not found")}
    end
  end

  def handle_event("delete_agent", %{"id" => id}, socket) do
    if agent_owned_by_current_user?(socket, id) do
      case Runtime.delete_agent(id) do
        :ok ->
          socket =
            socket
            |> maybe_reset_editor(id)
            |> refresh_dashboard()
            |> put_flash(:info, "Agent deleted")

          if socket.assigns.selected_agent && socket.assigns.selected_agent.id == id do
            {:noreply,
             socket
             |> assign(
               selected_agent: nil,
               events: [],
               agent_spend: nil,
               inspection: empty_inspection()
             )
             |> push_patch(to: "/dashboard")}
          else
            {:noreply, socket}
          end

        {:error, :not_found} ->
          {:noreply, socket |> refresh_dashboard() |> put_flash(:error, "Agent not found")}

        {:error, reason} ->
          {:noreply,
           socket
           |> refresh_dashboard()
           |> put_flash(:error, "Failed to delete agent: #{inspect(reason)}")}
      end
    else
      {:noreply, socket |> refresh_dashboard() |> put_flash(:error, "Agent not found")}
    end
  end

  def handle_event("send_message", %{"command" => %{"message" => raw_message}}, socket) do
    message = String.trim(raw_message || "")

    cond do
      socket.assigns.selected_agent == nil ->
        {:noreply, put_flash(socket, :error, "Select an agent first")}

      not agent_owned_by_current_user?(socket, socket.assigns.selected_agent.id) ->
        {:noreply, put_flash(socket, :error, "Agent not found")}

      message == "" ->
        {:noreply, put_flash(socket, :error, "Message cannot be empty")}

      true ->
        send_admin_message(socket, socket.assigns.selected_agent.id, message)
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_path={@current_path} current_user={@current_user}>
      <div class="space-y-10">
      <header class="flex flex-wrap items-end justify-between gap-3">
        <h1 class="text-2xl/8 font-semibold tracking-tight text-zinc-950 sm:text-xl/8">
          <%= dashboard_greeting(@current_user) %>
        </h1>
        <div class="flex flex-wrap items-center gap-2">
          <button
            type="button"
            phx-click="refresh_now"
            class="rounded-md px-2 py-1 text-xs/5 font-medium text-zinc-500 hover:bg-zinc-950/5 hover:text-zinc-950"
          >
            Refresh
          </button>
          <.button navigate={"/agents/new"}>
            New agent
          </.button>
        </div>
      </header>

      <%= if @dashboard_errors != [] do %>
        <.alert color="amber">
          <div class="space-y-2">
            <%= for error <- @dashboard_errors do %>
              <div>
                <p class="text-sm font-medium text-amber-900"><%= error.message %></p>
                <p class="mt-1 text-xs text-amber-800"><%= error.details %></p>
              </div>
            <% end %>
          </div>
        </.alert>
      <% end %>

      <.todo_review_board
        todos={@todos}
        todo_review_index={@todo_review_index}
        todo_review_session={@todo_review_session}
        todo_review_decided_ids={@todo_review_decided_ids}
      />

      <section>
        <div class="border-b border-zinc-950/10 pb-1">
          <h2 class="text-base/7 font-semibold text-zinc-950">Overview</h2>
        </div>
        <dl class="mt-6 grid grid-cols-1 gap-x-8 gap-y-6 sm:grid-cols-2 lg:grid-cols-4">
          <.overview_stat
            label="Agents"
            value={length(@agents)}
            note={
              "#{Enum.count(@agents, &(&1.status == "running"))} running · #{Enum.count(@agents, &(&1.status == "degraded"))} degraded"
            }
          />
          <.overview_stat
            label="LLM calls"
            value={@total_spend.llm_calls}
            note="last 30 days"
          />
          <.overview_stat
            label="Spend"
            value={"$#{Float.round(@total_spend.total_cost, 2)}"}
            note="last 30 days"
          />
          <.overview_stat
            label="Pending effects"
            value={@queue_metrics.effects.pending}
            note={"#{@queue_metrics.effects.failed} failed"}
          />
        </dl>
      </section>

      <section>
        <div class="flex items-end justify-between border-b border-zinc-950/10 pb-1">
          <h2 class="text-base/7 font-semibold text-zinc-950">Today</h2>
          <span :if={@open_todo_count > 0} class="text-xs/5 text-zinc-500">
            <%= @open_todo_count %> open
          </span>
        </div>

        <div class="mt-4">
          <%= if @todos == [] do %>
            <p class="text-sm/6 text-zinc-500">
              All caught up. Maraithon will surface work here as agents notice it.
            </p>
          <% else %>
            <ul role="list" class="divide-y divide-zinc-950/5">
              <li
                :for={todo <- Enum.take(@todos, 6)}
                id={"todo-#{todo.id}"}
                class="flex flex-wrap items-start justify-between gap-3 py-4"
              >
                <div class="min-w-0 flex-1">
                  <div class="flex flex-wrap items-center gap-x-2 gap-y-1 text-xs/5 text-zinc-500">
                    <span class={todo_status_class(todo.status)}>
                      <%= todo_status_label(todo.status) %>
                    </span>
                    <span><%= todo_source_label(todo.source) %></span>
                    <span aria-hidden="true">·</span>
                    <span><%= todo_priority_label(todo) %></span>
                  </div>
                  <p class="mt-1.5 text-sm/6 font-medium text-zinc-950"><%= todo.title %></p>
                  <p :if={todo.summary && todo.summary != ""} class="mt-0.5 text-sm/6 text-zinc-600">
                    <%= todo.summary %>
                  </p>
                  <p :if={todo.next_action && todo.next_action != ""} class="mt-1.5 text-sm/6 text-zinc-700">
                    <span class="font-medium text-zinc-950">Next:</span> <%= todo.next_action %>
                  </p>
                  <p class="mt-1 text-xs/5 text-zinc-500">
                    <%= todo_context_line(todo) %>
                  </p>
                </div>
                <div class="flex shrink-0 items-center gap-1">
                  <.button
                    type="button"
                    phx-click="complete_todo"
                    phx-value-id={todo.id}
                    variant="plain"
                    class="text-xs text-zinc-500 hover:text-zinc-950"
                  >
                    Mark done
                  </.button>
                  <.button
                    type="button"
                    phx-click="dismiss_todo"
                    phx-value-id={todo.id}
                    variant="plain"
                    class="text-xs text-zinc-500 hover:text-zinc-950"
                  >
                    Dismiss
                  </.button>
                </div>
              </li>
            </ul>
          <% end %>
        </div>
      </section>

      <section>
        <div class="flex items-end justify-between border-b border-zinc-950/10 pb-1">
          <h2 class="text-base/7 font-semibold text-zinc-950">Workspace</h2>
          <.link navigate="/connectors" class="text-xs/5 font-medium text-zinc-500 hover:text-zinc-950">
            Manage connectors →
          </.link>
        </div>
        <dl class="mt-4 grid grid-cols-1 gap-4 sm:grid-cols-3">
          <.workspace_summary
            label="Connected services"
            value={@connected_provider_count}
            description={
              if @connected_provider_count == 0,
                do: "No services linked yet.",
                else: "Linked accounts feed every project."
            }
            href="/connectors"
            cta="Connectors"
          />
          <.workspace_summary
            label="Memory"
            value={length(@memory_rules)}
            unit="rules"
            description={
              if @memory_profile.summary && @memory_profile.summary != "",
                do: @memory_profile.summary,
                else: "No durable preferences yet."
            }
            href="#memory-detail"
            cta="View memory"
          />
          <.workspace_summary
            label="Projects"
            value={length(@projects)}
            description={
              if length(@projects) == 0,
                do: "Projects hold notes, decisions, and grants.",
                else: "Each project carries its own context."
            }
            href="#projects"
            cta="View projects"
          />
        </dl>
      </section>

      <section id="chief-of-staff-install">
        <div class="flex items-end justify-between border-b border-zinc-950/10 pb-1">
          <h2 class="text-base/7 font-semibold text-zinc-950">Install agent</h2>
          <span class="text-xs/5 text-zinc-500">
            <%= chief_of_staff_install_state(@chief_of_staff_agent, @chief_of_staff_readiness, @projects) %>
          </span>
        </div>

        <div class="mt-4 divide-y divide-zinc-950/5 rounded-lg border border-zinc-950/10 bg-white">
          <div class="grid grid-cols-1 gap-4 px-4 py-4 sm:px-6 lg:grid-cols-[minmax(0,1fr)_auto] lg:items-center">
            <div class="min-w-0">
              <div class="flex flex-wrap items-center gap-2">
                <h3 class="text-sm/6 font-semibold text-zinc-950">Chief of Staff</h3>
                <.badge color={chief_of_staff_badge_color(@chief_of_staff_agent)}>
                  <%= chief_of_staff_badge_label(@chief_of_staff_agent) %>
                </.badge>
              </div>
              <p class="mt-1 max-w-3xl text-sm/6 text-zinc-600">
                <%= chief_of_staff_summary(@chief_of_staff_package) %>
              </p>

              <div class="mt-3 flex flex-wrap gap-2">
                <span
                  :for={item <- @chief_of_staff_readiness}
                  class={connector_chip_class(item)}
                >
                  <%= item.label %>
                </span>
              </div>

              <div :if={chief_of_staff_missing_readiness(@chief_of_staff_readiness) != []} class="mt-3 flex flex-wrap items-center gap-x-3 gap-y-1 text-xs/5">
                <%= for item <- chief_of_staff_missing_readiness(@chief_of_staff_readiness) do %>
                  <a
                    href={item.connect_path}
                    class="font-medium text-zinc-950 hover:text-zinc-700"
                  >
                    Connect <%= item.label %> →
                  </a>
                <% end %>
              </div>

              <p :if={@chief_of_staff_agent} class="mt-3 text-sm/6 text-zinc-500">
                Morning brief: <%= chief_of_staff_schedule_label(@chief_of_staff_schedule) %>
                <.link
                  navigate={"/agents?id=#{@chief_of_staff_agent.id}&panel=skills"}
                  class="ml-2 font-medium text-zinc-950 hover:text-zinc-700"
                >
                  Edit
                </.link>
              </p>
            </div>

            <div class="flex flex-wrap items-center justify-start gap-2 lg:justify-end">
              <%= cond do %>
                <% @chief_of_staff_agent -> %>
                  <.button navigate={"/agents?id=#{@chief_of_staff_agent.id}&panel=inspect"} variant="outline">
                    Open
                  </.button>
                <% @projects == [] -> %>
                  <.button type="button" disabled>
                    Create project first
                  </.button>
                <% chief_of_staff_missing_readiness(@chief_of_staff_readiness) != [] -> %>
                  <.button
                    type="button"
                    phx-click="install_chief_of_staff"
                    phx-value-project_id={first_project_id(@projects)}
                    variant="outline"
                  >
                    Setup required
                  </.button>
                <% true -> %>
                  <.button
                    type="button"
                    phx-click="install_chief_of_staff"
                    phx-value-project_id={first_project_id(@projects)}
                    phx-disable-with="Installing..."
                  >
                    Install Chief of Staff
                  </.button>
              <% end %>
            </div>
          </div>
        </div>
      </section>

      <details class="group rounded-lg border border-zinc-950/10 bg-white">
        <summary class="flex cursor-pointer list-none items-center justify-between gap-2 px-4 py-3 text-sm/6 font-medium text-zinc-950 sm:px-6">
          <span>New project</span>
          <span class="text-xs/5 text-zinc-500 group-open:hidden">Open</span>
          <span class="hidden text-xs/5 text-zinc-500 group-open:inline">Close</span>
        </summary>
        <.form
          for={@project_form}
          id="project-form"
          phx-change="update_project_form"
          phx-submit="create_project"
          class="space-y-4 border-t border-zinc-950/10 px-4 py-4 sm:px-6"
        >
          <.field label="Project name" for="project_name">
            <.c_input
              id="project_name"
              type="text"
              name="project[name]"
              value={@project_form[:name].value}
            />
          </.field>

          <.field label="Summary" for="project_summary">
            <.c_input
              id="project_summary"
              type="text"
              name="project[summary]"
              value={@project_form[:summary].value}
            />
          </.field>

          <.field label="Description" for="project_description">
            <.c_textarea
              id="project_description"
              name="project[description]"
              rows={4}
              value={@project_form[:description].value}
            />
          </.field>

          <.field label="Priority" for="project_priority">
            <.c_select
              id="project_priority"
              name="project[priority]"
            >
              <option value="low" selected={@project_form[:priority].value == "low"}>Low</option>
              <option value="normal" selected={@project_form[:priority].value == "normal"}>Normal</option>
              <option value="high" selected={@project_form[:priority].value == "high"}>High</option>
              <option value="critical" selected={@project_form[:priority].value == "critical"}>Critical</option>
            </.c_select>
          </.field>

          <div class="flex justify-end">
            <.button type="submit" phx-disable-with="Creating...">
              Create project
            </.button>
          </div>
        </.form>
      </details>

      <section
        :if={@memory_profile.summary not in [nil, ""] or @memory_rules != [] or @global_memory_summaries != []}
        id="memory-detail"
      >
        <div class="flex items-end justify-between border-b border-zinc-950/10 pb-1">
          <h2 class="text-base/7 font-semibold text-zinc-950">Memory</h2>
          <span class="text-xs/5 text-zinc-500">
            confidence <%= format_confidence(@memory_profile.confidence) %>
          </span>
        </div>
        <div class="mt-4 space-y-4">
          <p
            :if={@memory_profile.summary not in [nil, ""]}
            class="text-sm/6 text-zinc-700"
          >
            <%= @memory_profile.summary %>
          </p>

          <dl
            :if={memory_profile_fields(@memory_profile) != []}
            class="grid grid-cols-1 gap-x-8 gap-y-3 sm:grid-cols-2"
          >
            <div :for={field <- memory_profile_fields(@memory_profile)}>
              <dt class="text-xs/5 font-medium text-zinc-500"><%= field.label %></dt>
              <dd class="mt-0.5 text-sm/6 text-zinc-700"><%= field.value %></dd>
            </div>
          </dl>

          <div :if={@memory_rules != []}>
            <p class="text-sm/6 font-medium text-zinc-950">Saved preferences</p>
            <ul role="list" class="mt-2 divide-y divide-zinc-950/5">
              <li
                :for={rule <- Enum.take(@memory_rules, 3)}
                class="flex flex-wrap items-start justify-between gap-3 py-2.5"
              >
                <div class="min-w-0 flex-1">
                  <p class="text-xs/5 font-medium text-zinc-500">
                    <%= memory_rule_kind_label(rule["kind"]) %>
                  </p>
                  <p class="mt-0.5 text-sm/6 text-zinc-700"><%= rule["instruction"] || rule["label"] %></p>
                </div>
                <span class="text-xs/5 text-zinc-500">
                  <%= format_confidence(rule["confidence"]) %>
                </span>
              </li>
            </ul>
          </div>

          <div :if={@global_memory_summaries != []}>
            <p class="text-sm/6 font-medium text-zinc-950">Global state</p>
            <ul role="list" class="mt-2 divide-y divide-zinc-950/5">
              <li
                :for={summary <- Enum.take(@global_memory_summaries, 3)}
                class="flex flex-wrap items-start justify-between gap-3 py-2.5"
              >
                <div class="min-w-0 flex-1">
                  <p class="text-xs/5 font-medium text-zinc-500">
                    <%= memory_summary_label(summary.type) %>
                  </p>
                  <p class="mt-0.5 text-sm/6 text-zinc-700"><%= summary.content %></p>
                </div>
                <span class="text-xs/5 text-zinc-500">
                  <%= format_confidence(summary.confidence) %>
                </span>
              </li>
            </ul>
          </div>
        </div>
      </section>

      <details class="group rounded-lg border border-zinc-950/10 bg-white">
        <summary class="flex cursor-pointer list-none items-center justify-between gap-2 px-4 py-3 text-sm/6 font-medium text-zinc-950 sm:px-6">
          <span class="flex items-center gap-2">
            <span>Add to project memory</span>
            <span class="text-xs/5 text-zinc-500">notes · decisions · grants</span>
          </span>
          <span class="text-xs/5 text-zinc-500 group-open:hidden">Open</span>
          <span class="hidden text-xs/5 text-zinc-500 group-open:inline">Close</span>
        </summary>
        <.form
          for={@project_item_form}
          id="project-item-form"
          phx-change="update_project_item_form"
          phx-submit="create_project_item"
          class="grid grid-cols-1 gap-4 border-t border-zinc-950/10 px-4 py-4 sm:px-6 xl:grid-cols-[minmax(0,1.1fr)_minmax(0,0.9fr)_minmax(0,0.9fr)]"
        >
          <div class="space-y-4">
            <.field label="Project" for="project_item_project_id">
              <.c_select
                id="project_item_project_id"
                name="project_item[project_id]"
              >
                <option value="">Choose a project</option>
                <option
                  :for={{label, value} <- project_options(@projects)}
                  value={value}
                  selected={@project_item_form[:project_id].value == value}
                >
                  <%= label %>
                </option>
              </.c_select>
            </.field>
            <.field label="Item type" for="project_item_item_type">
              <.c_select
                id="project_item_item_type"
                name="project_item[item_type]"
              >
                <option
                  :for={{label, value} <- project_item_type_options(@project_item_types)}
                  value={value}
                  selected={@project_item_form[:item_type].value == value}
                >
                  <%= label %>
                </option>
              </.c_select>
            </.field>
          </div>

          <div class="space-y-4">
            <.field label="Title" for="project_item_title">
              <.c_input
                id="project_item_title"
                type="text"
                name="project_item[title]"
                value={@project_item_form[:title].value}
              />
            </.field>
            <p class="text-xs/5 text-zinc-500">
              Use this for concise labels like “Q2 launch goal” or “Ship project dashboard”.
            </p>
          </div>

          <div class="space-y-4">
            <.field label="Content" for="project_item_content">
              <.c_textarea
                id="project_item_content"
                name="project_item[content]"
                rows={4}
                value={@project_item_form[:content].value}
              />
            </.field>
            <div class="flex justify-end">
              <.button
                type="submit"
                phx-disable-with="Saving..."
                disabled={@projects == []}
              >
                Save
              </.button>
            </div>
          </div>
        </.form>
      </details>

      <section id="projects">
        <div class="flex items-end justify-between border-b border-zinc-950/10 pb-1">
          <h2 class="text-base/7 font-semibold text-zinc-950">Projects</h2>
          <span class="text-xs/5 text-zinc-500"><%= length(@projects) %> total</span>
        </div>
        <div class="mt-4 grid grid-cols-1 gap-4 xl:grid-cols-2">
          <%= for project_card <- @projects do %>
            <div class="rounded-lg border border-zinc-950/10 bg-zinc-50 p-5">
              <div class="flex flex-wrap items-start justify-between gap-3">
                <div>
                  <div class="flex flex-wrap items-center gap-2">
                    <h3 class="text-base/7 font-semibold text-zinc-950"><%= project_card.project.name %></h3>
                    <span class={project_status_class(project_card.project.status)}>
                      <%= project_card.project.status %>
                    </span>
                    <span class={project_priority_class(project_card.project.priority)}>
                      <%= project_card.project.priority %>
                    </span>
                  </div>
                  <p class="mt-1 text-xs/5 text-zinc-500">
                    <%= project_card.project.slug %>
                  </p>
                  <p class="mt-3 text-sm/6 text-zinc-600">
                    <%= project_summary(project_card.project) %>
                  </p>
                </div>

                <.button
                  navigate={"/agents/new?behavior=github_product_planner&project_id=#{project_card.project.id}"}
                  variant="outline"
                  class="text-xs"
                >
                  Attach Project Manager
                </.button>
              </div>

              <div class="mt-4 flex flex-wrap gap-2">
                <.badge class="bg-white">
                  <%= length(project_card.agents) %> agents
                </.badge>
                <.badge class="bg-white">
                  <%= length(project_card.items) %> recent items
                </.badge>
                <.badge class="bg-white">
                  <%= length(project_card.recommendations) %> PM recommendations
                </.badge>
              </div>

              <%= if project_card.agents != [] do %>
                <div class="mt-4">
                  <p class="text-sm/6 font-medium text-zinc-950">Attached agents</p>
                  <div class="mt-2 flex flex-wrap gap-2">
                    <.badge
                      :for={agent <- project_card.agents}
                      color="zinc"
                      class="bg-zinc-950 text-white"
                    >
                      <%= get_in(agent.config || %{}, ["name"]) || agent.behavior %>
                    </.badge>
                  </div>
                </div>
              <% end %>

              <div class="mt-5 grid grid-cols-1 gap-4 lg:grid-cols-2">
                <div class="space-y-3">
                  <div class="flex items-center justify-between gap-3">
                    <p class="text-sm/6 font-medium text-zinc-950">
                      Project memory
                    </p>
                  </div>
                  <%= if project_card.items == [] do %>
                    <p class="text-sm/6 text-zinc-500">
                      No project memory yet. Add a note, todo, or grant above so the agent has local context.
                    </p>
                  <% else %>
                    <div
                      :for={item <- project_card.items}
                      class="rounded-lg border border-zinc-950/10 bg-white px-3 py-3"
                    >
                      <div class="flex items-center justify-between gap-3">
                        <p class="text-sm/6 font-medium text-zinc-950"><%= item.title || item_type_label(item.item_type) %></p>
                        <.badge>
                          <%= item_type_label(item.item_type) %>
                        </.badge>
                      </div>
                      <p class="mt-2 text-sm/6 text-zinc-600"><%= item.content %></p>
                    </div>
                  <% end %>
                </div>

                <div class="space-y-3">
                  <p class="text-sm/6 font-medium text-zinc-950">
                    Project manager recommendations
                  </p>
                  <%= if project_card.recommendations == [] do %>
                    <p class="text-sm/6 text-zinc-500">
                      No project-manager output yet. Attach a GitHub Product Planner to this project and let it run.
                    </p>
                  <% else %>
                    <div
                      :for={recommendation <- project_card.recommendations}
                      class="rounded-lg border border-emerald-200 bg-emerald-50 px-3 py-3"
                    >
                      <div class="flex items-center justify-between gap-3">
                        <div>
                          <p class="text-sm/6 font-medium text-zinc-950"><%= recommendation.title %></p>
                          <div class="mt-2 flex flex-wrap gap-2">
                            <span class="text-xs font-semibold text-emerald-700">
                              p<%= recommendation.priority %>
                            </span>
                            <%= if recommendation.decision do %>
                              <.badge class="bg-white">
                                <%= recommendation_decision_label(recommendation.decision.decision) %>
                              </.badge>
                            <% end %>
                            <%= if recommendation.repo_grant do %>
                              <.badge class="bg-white">
                                <%= repo_scope_label(recommendation.repo_grant.scope) %>
                              </.badge>
                            <% end %>
                            <%= if recommendation.latest_run do %>
                              <.badge class="bg-white">
                                <%= implementation_run_status_label(recommendation.latest_run.status) %>
                              </.badge>
                            <% end %>
                          </div>
                        </div>
                      </div>
                      <p class="mt-2 text-sm/6 text-zinc-600"><%= recommendation.summary %></p>
                      <p class="mt-2 text-sm/6 text-emerald-900">
                        <span class="font-medium">Next step:</span> <%= recommendation.recommended_action %>
                      </p>
                      <%= if recommendation.why_now do %>
                        <p class="mt-2 text-xs/5 text-emerald-800"><%= recommendation.why_now %></p>
                      <% end %>
                      <%= if recommendation.latest_run do %>
                        <p class="mt-2 text-xs/5 text-zinc-600"><%= recommendation.latest_run.result_summary %></p>
                        <div class="mt-2 flex flex-wrap items-center gap-3 text-xs/5 text-zinc-500">
                          <%= if recommendation.latest_run.branch_name do %>
                            <span>Branch: <code><%= recommendation.latest_run.branch_name %></code></span>
                          <% end %>
                          <%= if recommendation.latest_run.pull_request_url do %>
                            <a
                              href={recommendation.latest_run.pull_request_url}
                              target="_blank"
                              rel="noreferrer"
                              class="font-medium text-emerald-700 hover:text-emerald-800"
                            >
                              Open PR
                            </a>
                          <% end %>
                        </div>
                      <% end %>
                      <div class="mt-3 flex flex-wrap gap-2">
                        <.button
                          type="button"
                          phx-click="decide_project_recommendation"
                          phx-value-project_id={project_card.project.id}
                          phx-value-recommendation_id={recommendation.id}
                          phx-value-decision="accepted"
                          variant="outline"
                          class="text-xs text-emerald-800"
                        >
                          Accept
                        </.button>
                        <.button
                          type="button"
                          phx-click="decide_project_recommendation"
                          phx-value-project_id={project_card.project.id}
                          phx-value-recommendation_id={recommendation.id}
                          phx-value-decision="deferred"
                          variant="outline"
                          class="text-xs"
                        >
                          Defer
                        </.button>
                        <.button
                          type="button"
                          phx-click="decide_project_recommendation"
                          phx-value-project_id={project_card.project.id}
                          phx-value-recommendation_id={recommendation.id}
                          phx-value-decision="rejected"
                          variant="outline"
                          class="text-xs"
                        >
                          Reject
                        </.button>
                        <%= if recommendation.repo_full_name do %>
                          <.button
                            type="button"
                            phx-click="grant_project_repo_access"
                            phx-value-project_id={project_card.project.id}
                            phx-value-repo_full_name={recommendation.repo_full_name}
                            phx-value-scope="read_only"
                            variant="outline"
                            class="text-xs"
                          >
                            Grant Read Access
                          </.button>
                          <.button
                            type="button"
                            phx-click="grant_project_repo_access"
                            phx-value-project_id={project_card.project.id}
                            phx-value-repo_full_name={recommendation.repo_full_name}
                            phx-value-scope="branch_write"
                            variant="outline"
                            class="text-xs"
                          >
                            Grant Branch Access
                          </.button>
                        <% end %>
                        <.button
                          type="button"
                          phx-click="start_project_implementation_run"
                          phx-value-project_id={project_card.project.id}
                          phx-value-recommendation_id={recommendation.id}
                          class="text-xs"
                        >
                          Start Delivery
                        </.button>
                      </div>
                    </div>
                  <% end %>

                  <div class="rounded-lg border border-zinc-950/10 bg-white px-3 py-3">
                    <p class="text-sm/6 font-medium text-zinc-950">
                      Repo Access
                    </p>
                    <%= if project_card.repo_grants == [] do %>
                      <p class="mt-2 text-sm/6 text-zinc-500">
                        No explicit repo grants yet.
                      </p>
                    <% else %>
                      <div :for={grant <- project_card.repo_grants} class="mt-2 flex items-center justify-between gap-3 rounded-lg border border-zinc-950/10 px-3 py-2">
                        <div class="min-w-0">
                          <p class="truncate text-sm/6 font-medium text-zinc-950"><%= grant.repo_full_name %></p>
                          <p class="text-xs/5 text-zinc-500"><%= repo_scope_label(grant.scope) %></p>
                        </div>
                        <.badge>
                          <%= String.capitalize(grant.status) %>
                        </.badge>
                      </div>
                    <% end %>
                  </div>

                  <div class="rounded-lg border border-zinc-950/10 bg-white px-3 py-3">
                    <p class="text-sm/6 font-medium text-zinc-950">
                      Delivery Runs
                    </p>
                    <%= if project_card.implementation_runs == [] do %>
                      <p class="mt-2 text-sm/6 text-zinc-500">
                        No implementation runs yet.
                      </p>
                    <% else %>
                      <div :for={run <- project_card.implementation_runs} class="mt-2 rounded-lg border border-zinc-950/10 px-3 py-2">
                        <div class="flex items-center justify-between gap-3">
                          <p class="text-sm/6 font-medium text-zinc-950"><%= implementation_run_status_label(run.status) %></p>
                          <span class="text-xs/5 text-zinc-500"><%= run.repo_full_name || "repo pending" %></span>
                        </div>
                        <p class="mt-2 text-sm/6 text-zinc-600"><%= run.result_summary %></p>
                        <div class="mt-2 flex flex-wrap items-center gap-3 text-xs/5 text-zinc-500">
                          <%= if run.branch_name do %>
                            <span>Branch: <code><%= run.branch_name %></code></span>
                          <% end %>
                          <%= if run.pull_request_url do %>
                            <a
                              href={run.pull_request_url}
                              target="_blank"
                              rel="noreferrer"
                              class="font-medium text-emerald-700 hover:text-emerald-800"
                            >
                              Open PR
                            </a>
                          <% end %>
                          <%= if plan_file_path = get_in(run.metadata || %{}, ["plan_file_path"]) do %>
                            <span>Plan: <%= plan_file_path %></span>
                          <% end %>
                        </div>
                      </div>
                    <% end %>
                  </div>
                </div>
              </div>
            </div>
          <% end %>

          <%= if @projects == [] do %>
            <p class="text-sm/6 text-zinc-500 xl:col-span-2">
              No projects yet. Use “New project” above and attach a specialist agent to start building project-local state.
            </p>
          <% end %>
        </div>
      </section>

      <%= if show_onboarding_preview?(@onboarding_preview_eligible?, @agents) do %>
        <.panel id="proof-of-value" body_class="p-0">
          <:header>
            <div class="flex flex-wrap items-center justify-between gap-3">
              <div>
                <div class="flex flex-wrap items-center gap-2">
                  <.heading level={2} class="text-base/7">3 things Maraithon would have caught this week</.heading>
                  <.badge color="emerald" class="bg-white">
                    Preview
                  </.badge>
                </div>
                <.text class="mt-1">
                  Real examples from your connected accounts. This is a lightweight proof-of-value scan, not a full always-on agent run.
                </.text>
              </div>
              <.button
                type="button"
                phx-click="refresh_onboarding_preview"
                variant="outline"
                class="text-emerald-800"
              >
                Refresh preview
              </.button>
            </div>
          </:header>

          <div class="divide-y divide-zinc-950/5">
            <%= case @onboarding_preview.status do %>
              <% :loading -> %>
                <div class="px-4 py-6 sm:px-6">
                  <p class="text-sm/6 font-medium text-zinc-950">Scanning your connected data...</p>
                  <p class="mt-1 text-sm/6 text-zinc-600">
                    Maraithon is pulling a small recent slice from your linked accounts and selecting the highest-signal examples.
                  </p>
                </div>
              <% :ready when @onboarding_preview.items == [] -> %>
                <div class="px-4 py-6 sm:px-6">
                  <p class="text-sm/6 font-medium text-zinc-950">Nothing high-signal surfaced in the recent sample.</p>
                  <p class="mt-1 text-sm/6 text-zinc-600">
                    That is a good sign. Once you start an agent, Maraithon keeps watching continuously and only escalates concrete follow-through risk.
                  </p>
                </div>
              <% :ready -> %>
                <%= for item <- @onboarding_preview.items do %>
                  <div class="px-4 py-4 sm:px-6">
                    <div class="flex flex-wrap items-start justify-between gap-4">
                      <div class="min-w-0 flex-1">
                        <div class="flex flex-wrap items-center gap-2">
                          <span class={preview_source_class(item.source)}>
                            <%= preview_source_label(item.source) %>
                          </span>
                          <span class="text-xs/5 text-zinc-500">
                            <%= item.account_label %>
                          </span>
                          <span class="text-xs/5 text-zinc-500">
                            confidence <%= format_confidence(item.confidence) %>
                          </span>
                        </div>
                        <p class="mt-2 text-base/7 font-semibold text-zinc-950"><%= item.title %></p>
                        <p class="mt-1 text-sm/6 text-zinc-600"><%= item.summary %></p>
                        <p class="mt-2 text-xs/5 font-medium text-zinc-500">
                          Why this matters
                        </p>
                        <p class="mt-1 text-sm/6 text-zinc-600"><%= item.rationale %></p>
                        <p class="mt-2 text-sm/6 text-indigo-700">
                          <span class="font-medium">What Maraithon would do:</span> <%= item.recommended_action %>
                        </p>
                      </div>
                      <div class="w-full max-w-xs rounded-lg border border-zinc-950/10 bg-zinc-50 p-4">
                        <p class="text-xs/5 font-medium text-zinc-500">
                          Best next step
                        </p>
                        <p class="mt-2 text-sm/6 font-medium text-zinc-950">
                          Start <%= onboarding_behavior_label(item.suggested_behavior) %>
                        </p>
                        <p class="mt-1 text-sm/6 text-zinc-600">
                          This agent is the best fit to catch this kind of loop continuously and escalate only when it matters.
                        </p>
                        <.button
                          navigate={"/agents/new?behavior=#{item.suggested_behavior}"}
                          class="mt-3"
                        >
                          Use this setup
                        </.button>
                      </div>
                    </div>
                  </div>
                <% end %>
              <% :error -> %>
                <div class="px-4 py-6 sm:px-6">
                  <p class="text-sm/6 font-medium text-zinc-950">Preview temporarily unavailable.</p>
                  <p class="mt-1 text-sm/6 text-zinc-600">
                    Maraithon could not build the onboarding proof just now. You can refresh this preview or go straight to the agent builder.
                  </p>
                </div>
              <% _ -> %>
                <div class="px-4 py-6 sm:px-6">
                  <p class="text-sm/6 text-zinc-600">Connect Gmail, Calendar, or Slack to see a proof-of-value preview.</p>
                </div>
            <% end %>
          </div>
        </.panel>
      <% end %>

      <section class="space-y-6">
        <div class="flex items-end justify-between border-b border-zinc-950/10 pb-1">
          <h2 class="text-base/7 font-semibold text-zinc-950">Actionable insights</h2>
          <span class="text-xs/5 text-zinc-500"><%= length(@insights) %> open</span>
        </div>

          <.insight_group
            title="Needs Action"
            subtitle="Threads that currently look like direct founder debt."
            cards={@act_now_insights}
            expanded_insight_ids={@expanded_insight_ids}
          />
          <.insight_group
            title="Watching"
            subtitle="Important threads Maraithon is tracking without asking you to act right now."
            cards={@monitor_insights}
            expanded_insight_ids={@expanded_insight_ids}
          />

          <%= if @insights == [] do %>
            <p class="text-sm/6 text-zinc-500">
              No actionable insights yet. Start an <code class="font-mono">ai_chief_of_staff</code>, <code class="font-mono">inbox_calendar_advisor</code>, or <code class="font-mono">slack_followthrough_agent</code> agent.
            </p>
          <% end %>
      </section>

      <section>
        <div class="flex items-end justify-between border-b border-zinc-950/10 pb-1">
          <h2 class="text-base/7 font-semibold text-zinc-950">Agent activity</h2>
          <.link navigate="/agents" class="text-xs/5 font-medium text-zinc-500 hover:text-zinc-950">
            All agents →
          </.link>
        </div>

        <div class="mt-4 grid grid-cols-1 gap-4 xl:grid-cols-2">
          <%= for overview <- @agent_overviews do %>
            <div class="rounded-lg border border-zinc-950/10 bg-zinc-50 p-5">
              <div class="flex flex-wrap items-start justify-between gap-3">
                <div>
                  <div class="flex flex-wrap items-center gap-2">
                    <h3 class="text-base/7 font-semibold text-zinc-950">
                      <%= agent_display_name(overview.agent) %>
                    </h3>
                    <span class={agent_status_class(overview.agent.status)}>
                      <%= overview.agent.status %>
                    </span>
                  </div>
                  <p class="mt-1 text-xs/5 text-zinc-500">
                    <%= humanize_text_token(overview.agent.behavior) %>
                  </p>
                  <p :if={overview.project_name} class="mt-2 text-sm/6 text-zinc-600">
                    Project: <span class="font-medium text-zinc-950"><%= overview.project_name %></span>
                  </p>
                </div>

                <.button
                  navigate={"/agents?id=#{overview.agent.id}"}
                  variant="outline"
                  class="text-xs"
                >
                  Open
                </.button>
              </div>

              <div class="mt-4 grid grid-cols-3 gap-3">
                <div class="rounded-lg border border-zinc-950/10 bg-white px-3 py-3">
                  <p class="text-xs/5 font-medium text-zinc-500">
                    Events
                  </p>
                  <p class="mt-2 text-lg/7 font-semibold text-zinc-950">
                    <%= overview.inspection.event_count %>
                  </p>
                </div>
                <div class="rounded-lg border border-zinc-950/10 bg-white px-3 py-3">
                  <p class="text-xs/5 font-medium text-zinc-500">
                    Effects
                  </p>
                  <p class="mt-2 text-lg/7 font-semibold text-zinc-950">
                    <%= overview.inspection.effect_counts.pending %>
                  </p>
                </div>
                <div class="rounded-lg border border-zinc-950/10 bg-white px-3 py-3">
                  <p class="text-xs/5 font-medium text-zinc-500">
                    Jobs
                  </p>
                  <p class="mt-2 text-lg/7 font-semibold text-zinc-950">
                    <%= overview.inspection.job_counts.pending %>
                  </p>
                </div>
              </div>

              <div class="mt-4 grid grid-cols-1 gap-4 lg:grid-cols-2">
                <div>
                  <p class="text-sm/6 font-medium text-zinc-950">
                    Recent events
                  </p>
                  <%= if overview.recent_activity == [] do %>
                    <p class="mt-2 text-sm/6 text-zinc-500">No recent events recorded.</p>
                  <% else %>
                    <div class="mt-2 space-y-2">
                      <div
                        :for={activity <- overview.recent_activity}
                        class="rounded-lg border border-zinc-950/10 bg-white px-3 py-3"
                      >
                        <div class="flex items-center justify-between gap-3">
                          <p class="text-sm/6 font-medium text-zinc-950"><%= activity.event_type %></p>
                          <span class="text-xs/5 text-zinc-500"><%= format_time(activity.inserted_at) %></span>
                        </div>
                        <p class="mt-2 text-xs/5 text-zinc-500"><%= payload_preview(activity.payload) %></p>
                      </div>
                    </div>
                  <% end %>
                </div>

                <div>
                  <p class="text-sm/6 font-medium text-zinc-950">
                    Recent logs
                  </p>
                  <%= if overview.inspection.recent_logs == [] do %>
                    <p class="mt-2 text-sm/6 text-zinc-500">No recent logs captured.</p>
                  <% else %>
                    <div class="mt-2 space-y-2">
                      <div
                        :for={log <- overview.inspection.recent_logs}
                        class="rounded-lg border border-zinc-950 bg-zinc-950 px-3 py-3"
                      >
                        <div class="flex items-center justify-between gap-3">
                          <span class={["text-xs/5 font-semibold", log_level_class(log.level)]}>
                            <%= log.level %>
                          </span>
                          <span class="text-xs/5 text-zinc-500">
                            <%= format_log_timestamp(log.timestamp) %>
                          </span>
                        </div>
                        <p class="mt-2 text-xs/5 text-zinc-100"><%= log.message %></p>
                      </div>
                    </div>
                  <% end %>
                </div>
              </div>

              <%= if overview.errors != [] do %>
                <.alert color="amber" class="mt-4">
                  <p class="text-sm/6 font-medium"><%= List.first(overview.errors).message %></p>
                  <p class="mt-1 text-xs/5"><%= List.first(overview.errors).details %></p>
                </.alert>
              <% end %>
            </div>
          <% end %>

          <%= if @agent_overviews == [] do %>
            <p class="text-sm/6 text-zinc-500 xl:col-span-2">
              No agents yet. Install a chief of staff, project manager, or coding agent to start building the operator system.
            </p>
          <% end %>
        </div>
      </section>

      <section>
        <div class="flex items-end justify-between border-b border-zinc-950/10 pb-1">
          <h2 class="text-base/7 font-semibold text-zinc-950">Health</h2>
          <span class={[health_badge_class(@health.status), "whitespace-nowrap"]}>
            <%= @health.status %>
          </span>
        </div>

        <div class="mt-4 grid grid-cols-1 gap-x-8 gap-y-6 lg:grid-cols-2">
          <dl class="space-y-2 text-sm/6">
            <.health_row
              label="Database"
              value={to_string(@health.checks.database)}
              value_class={
                if @health.checks.database == :ok,
                  do: "text-emerald-700 font-medium",
                  else: "text-red-600 font-medium"
              }
            />
            <.health_row label="Memory" value={"#{@health.checks.memory_mb} MB"} />
            <.health_row label="Uptime" value={format_uptime(@health.checks.uptime_seconds)} />
            <.health_row
              label="Version"
              value={@health.version || "n/a"}
              value_class="font-mono text-xs/5 text-zinc-950"
            />
          </dl>

          <div class="space-y-5">
            <.queue_strip
              title="Effects queue"
              metrics={[
                %{label: "pending", value: @queue_metrics.effects.pending},
                %{label: "claimed", value: @queue_metrics.effects.claimed},
                %{label: "completed", value: @queue_metrics.effects.completed},
                %{
                  label: "failed",
                  value: @queue_metrics.effects.failed,
                  emphasis:
                    if(@queue_metrics.effects.failed > 0, do: "text-red-700", else: nil)
                }
              ]}
            />
            <.queue_strip
              title="Scheduled jobs"
              metrics={[
                %{label: "pending", value: @queue_metrics.jobs.pending},
                %{
                  label: "dispatched",
                  value: @queue_metrics.jobs.dispatched,
                  emphasis:
                    if(@queue_metrics.jobs.dispatched > 0, do: "text-amber-700", else: nil)
                },
                %{label: "delivered", value: @queue_metrics.jobs.delivered},
                %{label: "cancelled", value: @queue_metrics.jobs.cancelled}
              ]}
            />
          </div>
        </div>
      </section>

      <details class="group rounded-lg border border-zinc-950/10 bg-white">
        <summary class="flex cursor-pointer list-none items-center justify-between gap-2 px-4 py-3 text-sm/6 font-medium text-zinc-950 sm:px-6">
          <span class="flex items-center gap-2">
            <span>Operational activity</span>
            <span class="text-xs/5 text-zinc-500">
              <%= length(@recent_activity) %> events · <%= length(@recent_failures) %> failures
            </span>
          </span>
          <span class="text-xs/5 text-zinc-500 group-open:hidden">Show</span>
          <span class="hidden text-xs/5 text-zinc-500 group-open:inline">Hide</span>
        </summary>
        <div class="grid grid-cols-1 gap-0 border-t border-zinc-950/10 lg:grid-cols-2 lg:divide-x lg:divide-zinc-950/5">
          <div class="px-4 py-4 sm:px-6">
            <p class="text-xs/5 font-medium text-zinc-500">Recent events</p>
            <div class="mt-2 max-h-80 space-y-2 overflow-y-auto">
              <div
                :for={activity <- @recent_activity}
                class="rounded-lg border border-zinc-950/10 p-3"
              >
                <div class="flex items-center justify-between gap-3">
                  <div class="truncate text-sm/6 font-medium text-zinc-950">
                    <%= activity.event_type %>
                  </div>
                  <div class="text-xs/5 text-zinc-500">
                    <%= format_time(activity.inserted_at) %>
                  </div>
                </div>
                <div class="mt-1 text-xs/5 text-zinc-500">
                  <span class="font-medium"><%= activity.behavior %></span>
                  <span class="mx-1">·</span>
                  <span class="font-mono"><%= short_id(activity.agent_id) %></span>
                </div>
                <div class="mt-2 break-all rounded-md bg-zinc-50 px-2 py-1 font-mono text-xs/5 text-zinc-600">
                  <%= payload_preview(activity.payload) %>
                </div>
              </div>
              <%= if @recent_activity == [] do %>
                <p class="text-sm/6 text-zinc-500">No activity yet.</p>
              <% end %>
            </div>
          </div>

          <div class="px-4 py-4 sm:px-6">
            <p class="text-xs/5 font-medium text-zinc-500">Failures &amp; stale work</p>
            <div class="mt-2 max-h-80 space-y-2 overflow-y-auto">
              <div
                :for={failure <- @recent_failures}
                class="rounded-lg border border-red-200 bg-red-50/40 p-3"
              >
                <div class="flex items-center justify-between gap-3">
                  <div class="truncate text-sm/6 font-medium text-red-700">
                    <%= failure.type %> (<%= failure.source %>)
                  </div>
                  <div class="text-xs/5 text-zinc-500">
                    <%= format_time(failure.inserted_at) %>
                  </div>
                </div>
                <div class="mt-1 text-xs/5 text-zinc-500">
                  <span class="font-medium"><%= failure.behavior %></span>
                  <span class="mx-1">·</span>
                  <span class="font-mono"><%= short_id(failure.agent_id) %></span>
                  <span class="mx-1">·</span>
                  <span class="font-medium"><%= failure.status %></span>
                  <span class="mx-1">·</span>
                  <span>attempts <%= failure.attempts %></span>
                </div>
                <div class="mt-2 break-all rounded-md bg-white px-2 py-1 font-mono text-xs/5 text-zinc-700">
                  <%= failure.details %>
                </div>
              </div>
              <%= if @recent_failures == [] do %>
                <p class="text-sm/6 text-zinc-500">No failures detected.</p>
              <% end %>
            </div>
          </div>
        </div>
      </details>

      <details class="group rounded-lg border border-zinc-950/10 bg-white">
        <summary class="flex cursor-pointer list-none items-center justify-between gap-2 px-4 py-3 text-sm/6 font-medium text-zinc-950 sm:px-6">
          <span class="flex items-center gap-2">
            <span>Raw logs</span>
            <span class="text-xs/5 text-zinc-500">runtime · in-app</span>
          </span>
          <span class="text-xs/5 text-zinc-500 group-open:hidden">Show</span>
          <span class="hidden text-xs/5 text-zinc-500 group-open:inline">Hide</span>
        </summary>
        <div class="max-h-[28rem] overflow-y-auto border-t border-zinc-950/10 px-4 py-3 font-mono text-[11px] leading-5 sm:px-6">
          <%= for log <- @recent_logs do %>
            <div class="grid grid-cols-[auto_auto_1fr] gap-3 border-b border-zinc-950/5 py-1.5 last:border-0">
              <span class="text-zinc-500"><%= format_log_timestamp(log.timestamp) %></span>
              <span class={["font-semibold", log_level_text_class(log.level)]}>
                <%= log.level %>
              </span>
              <div class="min-w-0">
                <%= if metadata = log_metadata_preview(log.metadata) do %>
                  <span class="mr-2 text-zinc-500"><%= metadata %></span>
                <% end %>
                <span class="break-words whitespace-pre-wrap text-zinc-700"><%= log.message %></span>
              </div>
            </div>
          <% end %>
          <%= if @recent_logs == [] do %>
            <p class="font-sans text-sm/6 text-zinc-500">No logs captured yet.</p>
          <% end %>
        </div>
      </details>

      <details class="group rounded-lg border border-zinc-950/10 bg-white">
        <summary class="flex cursor-pointer list-none items-center justify-between gap-2 px-4 py-3 text-sm/6 font-medium text-zinc-950 sm:px-6">
          <span class="flex items-center gap-2">
            <span>Fly.io platform logs</span>
            <span class="text-xs/5 text-zinc-500">app · machine · runner</span>
          </span>
          <span class="flex items-center gap-3">
            <button
              type="button"
              phx-click="refresh_fly_logs"
              class="rounded-md border border-zinc-950/10 px-2 py-0.5 text-xs/5 font-medium text-zinc-700 hover:bg-zinc-950/5"
            >
              Refresh
            </button>
            <span class="text-xs/5 text-zinc-500 group-open:hidden">Show</span>
            <span class="hidden text-xs/5 text-zinc-500 group-open:inline">Hide</span>
          </span>
        </summary>
        <div class="border-t border-zinc-950/10">
          <div :if={@fly_logs.apps != []} class="flex flex-wrap gap-1.5 px-4 pt-3 sm:px-6">
            <span
              :for={app <- @fly_logs.apps}
              class="rounded-md border border-zinc-950/10 bg-zinc-50 px-1.5 py-0.5 text-xs/5 font-medium text-zinc-700"
            >
              <%= app %>
            </span>
          </div>

          <div class="max-h-[28rem] overflow-y-auto px-4 py-3 font-mono text-[11px] leading-5 sm:px-6">
            <%= for error <- @fly_logs.errors do %>
              <div class="mb-2 rounded-md border border-red-200 bg-red-50 px-3 py-2 text-red-800">
                <%= if error[:app] do %>
                  <span class="mr-2 font-semibold"><%= error.app %></span>
                <% end %>
                <span><%= error.message %></span>
              </div>
            <% end %>

            <%= if not @fly_logs.available and @fly_logs.apps == [] do %>
              <p class="font-sans text-sm/6 text-zinc-500">
                Configure <code class="font-mono">FLY_API_TOKEN</code> and <code class="font-mono">FLY_LOG_APPS</code> to load Fly logs in-app.
              </p>
            <% else %>
              <%= if @fly_logs.logs == [] do %>
                <p class="font-sans text-sm/6 text-zinc-500">No Fly logs returned yet.</p>
              <% else %>
                <%= for log <- @fly_logs.logs do %>
                  <div class="grid grid-cols-[auto_auto_1fr] gap-3 border-b border-zinc-950/5 py-1.5 last:border-0">
                    <span class="text-zinc-500"><%= format_log_timestamp(log.timestamp) %></span>
                    <span class={["font-semibold", log_level_text_class(log.level)]}>
                      <%= log.level %>
                    </span>
                    <div class="min-w-0">
                      <%= if metadata = fly_log_metadata_preview(log) do %>
                        <span class="mr-2 text-zinc-500"><%= metadata %></span>
                      <% end %>
                      <span class="break-words whitespace-pre-wrap text-zinc-700"><%= log.message %></span>
                    </div>
                  </div>
                <% end %>
              <% end %>
            <% end %>
          </div>
        </div>
      </details>
      </div>
    </Layouts.app>
    """
  end

  defp save_agent(socket, launch, start_params) do
    case socket.assigns.editing_agent_id do
      nil ->
        case Runtime.start_agent(start_params) do
          {:ok, agent} ->
            {:noreply,
             socket
             |> assign(
               launch: default_launch_params(),
               launch_error: nil,
               launch_mode: :create,
               editing_agent_id: nil
             )
             |> refresh_dashboard()
             |> put_flash(:info, "Agent #{String.slice(agent.id, 0, 8)} created")
             |> push_patch(to: "/dashboard?id=#{agent.id}")}

          {:error, message} when is_binary(message) ->
            {:noreply, assign(socket, launch: launch, launch_error: message)}

          {:error, %Ecto.Changeset{} = changeset} ->
            {:noreply,
             assign(socket,
               launch: launch,
               launch_error: "Failed to create agent: #{changeset_errors(changeset)}"
             )}

          {:error, reason} ->
            {:noreply,
             assign(socket,
               launch: launch,
               launch_error: "Failed to create agent: #{inspect(reason)}"
             )}
        end

      id ->
        case Runtime.update_agent(id, start_params) do
          {:ok, agent} ->
            {:noreply,
             socket
             |> assign(
               launch: default_launch_params(),
               launch_error: nil,
               launch_mode: :create,
               editing_agent_id: nil
             )
             |> refresh_dashboard()
             |> refresh_if_selected(id)
             |> put_flash(:info, "Agent #{String.slice(agent.id, 0, 8)} updated")
             |> push_patch(to: "/dashboard?id=#{agent.id}")}

          {:error, message} when is_binary(message) ->
            {:noreply, assign(socket, launch: launch, launch_error: message)}

          {:error, %Ecto.Changeset{} = changeset} ->
            {:noreply,
             assign(socket,
               launch: launch,
               launch_error: "Failed to update agent: #{changeset_errors(changeset)}"
             )}

          {:error, reason} ->
            {:noreply,
             assign(socket,
               launch: launch,
               launch_error: "Failed to update agent: #{inspect(reason)}"
             )}
        end
    end
  end

  defp send_admin_message(socket, agent_id, message) do
    case Runtime.send_message(agent_id, message, %{"source" => "admin_console"}) do
      {:ok, _result} ->
        {:noreply,
         socket
         |> assign(command: %{"message" => ""})
         |> refresh_if_selected(agent_id)
         |> put_flash(:info, "Message accepted by agent")}

      {:error, :not_found} ->
        {:noreply, socket |> refresh_dashboard() |> put_flash(:error, "Agent not found")}

      {:error, :agent_stopped} ->
        {:noreply, put_flash(socket, :error, "Agent is not running")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to send message: #{inspect(reason)}")}
    end
  end

  defp refresh_dashboard(socket, opts \\ []) do
    socket = refresh_insights(socket)
    socket = refresh_connections(socket)
    socket = refresh_projects(socket)
    socket = refresh_global_memory(socket)
    socket = refresh_todos(socket)
    socket = refresh_chief_of_staff_install(socket)

    user_id = current_user_id(socket)

    socket =
      case Admin.safe_control_center_snapshot(
             user_id: user_id,
             activity_limit: @activity_limit,
             failure_limit: @failure_limit
           ) do
        {:ok, snapshot} ->
          assign(socket,
            agents: snapshot.agents,
            total_spend: snapshot.total_spend,
            health: snapshot.health,
            queue_metrics: snapshot.queue_metrics,
            recent_activity: snapshot.recent_activity,
            recent_failures: snapshot.recent_failures,
            recent_logs: snapshot.recent_logs,
            dashboard_errors: snapshot.errors
          )

        {:degraded, snapshot} ->
          assign(socket,
            health: snapshot.health,
            recent_logs: snapshot.recent_logs,
            dashboard_errors: snapshot.errors
          )
      end

    socket =
      if Keyword.get(opts, :include_fly_logs, false) do
        refresh_fly_logs(socket)
      else
        socket
      end

    socket =
      if socket.assigns.selected_agent do
        case refresh_selected_agent(socket, socket.assigns.selected_agent.id,
               health: socket.assigns.health
             ) do
          {:ok, socket} -> socket
          {:not_found, socket} -> socket
        end
      else
        socket
      end

    socket = refresh_agent_overviews(socket)

    maybe_start_onboarding_preview(socket, opts)
  end

  defp refresh_insights(socket) do
    act_now_cards =
      Insights.list_open_act_now_with_details_for_user(current_user_id(socket), limit: 20)

    monitor_cards =
      Insights.list_open_monitor_with_details_for_user(current_user_id(socket), limit: 20)

    cards = act_now_cards ++ monitor_cards
    visible_ids = MapSet.new(Enum.map(cards, & &1.insight.id))

    emit_insight_detail_coverage_telemetry(cards)

    assign(socket,
      insights: cards,
      act_now_insights: act_now_cards,
      monitor_insights: monitor_cards,
      expanded_insight_ids: MapSet.intersection(socket.assigns.expanded_insight_ids, visible_ids),
      detail_opened_insight_ids:
        MapSet.intersection(socket.assigns.detail_opened_insight_ids, visible_ids)
    )
  end

  defp insight_card(socket, insight_id) when is_binary(insight_id) do
    Enum.find(socket.assigns.insights, fn
      %{insight: %{id: ^insight_id}} -> true
      _ -> false
    end)
  end

  defp insight_card(_socket, _insight_id), do: nil

  defp emit_insight_detail_toggle_telemetry(expanded?, insight, detail) do
    event =
      if expanded? do
        [:maraithon, :dashboard, :insight_detail, :collapsed]
      else
        [:maraithon, :dashboard, :insight_detail, :expanded]
      end

    :telemetry.execute(event, %{count: 1}, Detail.telemetry_metadata(insight, detail))
  end

  defp maybe_emit_insight_action_telemetry(
         socket,
         action,
         %{insight: insight, detail: detail},
         insight_id
       )
       when is_binary(action) do
    metadata =
      Detail.telemetry_metadata(insight, detail)
      |> Map.put(:action, action)
      |> Map.put(
        :detail_opened_before_action,
        MapSet.member?(socket.assigns.detail_opened_insight_ids, insight_id)
      )

    :telemetry.execute([:maraithon, :dashboard, :insight_detail, :action], %{count: 1}, metadata)
  end

  defp maybe_emit_insight_action_telemetry(_socket, _action, _card, _insight_id), do: :ok

  defp emit_insight_detail_coverage_telemetry(cards) when is_list(cards) do
    :telemetry.execute(
      [:maraithon, :dashboard, :insight_detail, :coverage],
      Detail.coverage_measurements(cards),
      %{source: :dashboard_refresh}
    )
  end

  defp refresh_selected_agent(socket, id, opts \\ []) do
    case Admin.safe_agent_snapshot(
           id,
           user_id: current_user_id(socket),
           event_limit: @event_limit,
           log_limit: 80,
           health: Keyword.get(opts, :health, socket.assigns.health)
         ) do
      {:ok, snapshot} ->
        {:ok,
         assign(socket,
           selected_agent: snapshot.agent,
           events: snapshot.events,
           agent_spend: snapshot.spend,
           inspection: snapshot.inspection,
           inspection_errors: snapshot.errors
         )}

      {:degraded, snapshot} ->
        inspection =
          if socket.assigns.selected_agent && socket.assigns.selected_agent.id == id do
            merge_degraded_inspection(socket.assigns.inspection, snapshot.inspection)
          else
            snapshot.inspection
          end

        {:ok,
         assign(socket,
           selected_agent: socket.assigns.selected_agent,
           inspection: inspection,
           inspection_errors: snapshot.errors
         )}

      {:error, :not_found} ->
        {:not_found,
         assign(socket,
           selected_agent: nil,
           events: [],
           agent_spend: nil,
           inspection: empty_inspection(),
           inspection_errors: [],
           page_title: "Control Center"
         )}
    end
  end

  defp refresh_if_selected(socket, id) do
    if socket.assigns.selected_agent && socket.assigns.selected_agent.id == id do
      case refresh_selected_agent(socket, id) do
        {:ok, socket} -> socket
        {:not_found, socket} -> socket
      end
    else
      socket
    end
  end

  defp maybe_reset_editor(socket, id) do
    if socket.assigns.editing_agent_id == id do
      assign(socket,
        launch: default_launch_params(),
        launch_error: nil,
        launch_mode: :create,
        editing_agent_id: nil
      )
    else
      socket
    end
  end

  defp default_launch_params do
    AgentBuilder.default_launch_params()
  end

  defp default_project_form_params do
    %{"name" => "", "summary" => "", "description" => "", "priority" => "normal"}
  end

  defp default_project_item_form_params do
    %{"project_id" => "", "item_type" => "note", "title" => "", "content" => ""}
  end

  defp launch_params_from_agent(agent), do: AgentBuilder.launch_params_from_agent(agent)

  defp normalize_launch_params(params), do: AgentBuilder.normalize_launch_params(params)

  defp build_agent_start_params(launch, user_id),
    do: AgentBuilder.build_start_params(launch, user_id)

  defp changeset_errors(changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
    |> Enum.map(fn {field, errors} -> "#{field} #{Enum.join(errors, ", ")}" end)
    |> Enum.join("; ")
  end

  defp empty_spend do
    %{
      total_cost: 0.0,
      input_tokens: 0,
      output_tokens: 0,
      llm_calls: 0
    }
  end

  defp empty_inspection do
    %{
      event_count: 0,
      effect_counts: %{pending: 0, claimed: 0, completed: 0, failed: 0, cancelled: 0},
      recent_effects: [],
      job_counts: %{pending: 0, dispatched: 0, delivered: 0, cancelled: 0},
      recent_jobs: [],
      recent_logs: []
    }
  end

  defp merge_degraded_inspection(current, degraded) do
    %{current | recent_logs: degraded.recent_logs}
  end

  defp empty_onboarding_preview do
    %{
      status: :idle,
      items: [],
      sources: [],
      generated_at: nil,
      error: nil
    }
  end

  defp empty_memory_profile do
    %{
      summary: "Maraithon is still learning how this user prefers to work.",
      profile: %{},
      confidence: 0.0,
      source_window_start: nil,
      source_window_end: nil,
      updated_at: nil
    }
  end

  defp empty_fly_logs do
    %{
      available: false,
      apps: [],
      logs: [],
      next_tokens: %{},
      errors: []
    }
  end

  defp refresh_fly_logs(socket) do
    case Admin.fly_logs(limit: 120) do
      {:ok, snapshot} ->
        assign(socket, fly_logs: snapshot)

      {:error, reason} ->
        assign(socket,
          fly_logs: %{
            available: false,
            apps: [],
            logs: [],
            next_tokens: %{},
            errors: [%{app: nil, message: "Failed to fetch Fly logs: #{inspect(reason)}"}]
          }
        )
    end
  end

  defp refresh_connections(socket) do
    case Connections.safe_dashboard_snapshot(
           socket.assigns.connection_user_id,
           return_to: connection_return_to(socket)
         ) do
      {:ok, snapshot} ->
        assign(socket,
          connected_provider_count: snapshot.connected_count,
          connections: snapshot.providers,
          raw_connections: snapshot.raw_tokens,
          connection_errors: snapshot.errors
        )

      {:degraded, snapshot} ->
        assign(socket,
          connected_provider_count: snapshot.connected_count,
          connections: snapshot.providers,
          raw_connections: snapshot.raw_tokens,
          connection_errors: snapshot.errors
        )
    end
  end

  defp refresh_chief_of_staff_install(socket) do
    user_id = current_user_id(socket)
    package = chief_of_staff_package()
    required_connectors = AgentMarketplace.required_connectors_for("ai_chief_of_staff")

    readiness =
      Connections.connector_readiness(user_id, required_connectors, return_to: "/dashboard")

    assign(socket,
      chief_of_staff_package: package,
      chief_of_staff_readiness: readiness,
      chief_of_staff_agent:
        Agents.get_package_installation(user_id, "ai_chief_of_staff", preload: [:project]),
      chief_of_staff_schedule: BriefingSchedules.summarize_for_prompt(user_id)
    )
  end

  defp chief_of_staff_package do
    case Agents.get_agent_package_by_slug("ai_chief_of_staff", preload: [:latest_version]) do
      nil ->
        _ = AgentMarketplace.sync_builtin_packages()
        Agents.get_agent_package_by_slug("ai_chief_of_staff", preload: [:latest_version])

      package ->
        package
    end
  end

  defp refresh_projects(socket) do
    user_id = current_user_id(socket)

    projects =
      Projects.list_projects(user_id: user_id, preload: [:agents])
      |> Enum.map(fn project ->
        %{
          project: project,
          agents: project.agents,
          items: Projects.list_project_items(user_id: user_id, project_id: project.id, limit: 4),
          recommendations: Projects.list_project_recommendations(project.id, user_id, limit: 3),
          repo_grants:
            Projects.list_repo_grants(project_id: project.id, user_id: user_id, limit: 3),
          implementation_runs:
            Projects.list_implementation_runs(project_id: project.id, user_id: user_id, limit: 3)
        }
      end)

    assign(socket, :projects, projects)
  end

  defp refresh_global_memory(socket) do
    user_id = current_user_id(socket)

    assign(
      socket,
      global_memory_summaries: OperatorMemory.summaries_for_prompt(user_id),
      memory_profile: UserMemory.prompt_context(user_id),
      memory_rules: PreferenceMemory.active_rules(user_id)
    )
  end

  defp refresh_todos(socket) do
    user_id = current_user_id(socket)
    todos = Todos.list_for_user(user_id, limit: 50, statuses: ["open", "snoozed"])
    decided_ids = prune_todo_review_decided_ids(socket.assigns.todo_review_decided_ids, todos)
    reviewable_count = length(reviewable_todos(todos, decided_ids))

    assign(socket,
      todos: todos,
      open_todo_count: length(todos),
      todo_review_decided_ids: decided_ids,
      todo_review_index:
        clamp_review_index(Map.get(socket.assigns, :todo_review_index, 0), reviewable_count)
    )
  end

  defp increment_todo_review_session(socket, key)
       when key in [:completed, :dismissed, :kept, :important] do
    session =
      socket.assigns
      |> Map.get(:todo_review_session, %{})
      |> Map.update(key, 1, &(&1 + 1))

    assign(socket, :todo_review_session, session)
  end

  defp mark_todo_reviewed(socket, todo_id) when is_binary(todo_id) do
    decided_ids =
      socket.assigns
      |> Map.get(:todo_review_decided_ids, MapSet.new())
      |> MapSet.put(todo_id)

    assign(socket, :todo_review_decided_ids, decided_ids)
  end

  defp mark_todo_reviewed(socket, _todo_id), do: socket

  defp clamp_todo_review_index(socket) do
    reviewable_count = reviewable_todo_count(socket)

    assign(
      socket,
      :todo_review_index,
      clamp_review_index(socket.assigns.todo_review_index, reviewable_count)
    )
  end

  defp reviewable_todo_count(socket) do
    socket.assigns.todos
    |> reviewable_todos(Map.get(socket.assigns, :todo_review_decided_ids, MapSet.new()))
    |> length()
  end

  defp refresh_agent_overviews(socket) do
    projects_by_id =
      Map.new(socket.assigns.projects, fn %{project: project} -> {project.id, project.name} end)

    recent_activity_by_agent = Enum.group_by(socket.assigns.recent_activity, & &1.agent_id)
    user_id = current_user_id(socket)
    max_concurrency = max(1, min(length(socket.assigns.agents), 4))

    overviews =
      socket.assigns.agents
      |> Task.async_stream(
        fn agent ->
          snapshot =
            case Admin.safe_agent_snapshot(
                   agent.id,
                   user_id: user_id,
                   event_limit: 4,
                   effect_limit: 3,
                   job_limit: 3,
                   log_limit: 4,
                   health: socket.assigns.health
                 ) do
              {:ok, snapshot} ->
                %{inspection: snapshot.inspection, errors: []}

              {:degraded, snapshot} ->
                %{inspection: snapshot.inspection, errors: snapshot.errors}

              {:error, :not_found} ->
                %{inspection: empty_inspection(), errors: []}
            end

          %{
            agent: agent,
            project_name: Map.get(projects_by_id, agent.project_id),
            recent_activity: Map.get(recent_activity_by_agent, agent.id, []) |> Enum.take(3),
            inspection: snapshot.inspection,
            errors: snapshot.errors
          }
        end,
        ordered: true,
        timeout: :infinity,
        max_concurrency: max_concurrency
      )
      |> Enum.map(fn {:ok, overview} -> overview end)

    assign(socket, :agent_overviews, overviews)
  end

  defp maybe_start_onboarding_preview(socket, opts) do
    preview = socket.assigns.onboarding_preview
    force? = Keyword.get(opts, :force, false)
    user_id = current_user_id(socket)

    cond do
      not show_onboarding_preview?(
        socket.assigns.onboarding_preview_eligible?,
        socket.assigns.agents
      ) ->
        assign(socket, :onboarding_preview, %{empty_onboarding_preview() | status: :hidden})

      preview.status == :loading and not force? ->
        socket

      preview.status == :ready and not force? ->
        socket

      preview.status == :error and not force? ->
        socket

      true ->
        socket
        |> assign(:onboarding_preview, %{empty_onboarding_preview() | status: :loading})
        |> start_async(:onboarding_preview, fn ->
          onboarding_proof_module().preview(user_id)
        end)
    end
  end

  defp onboarding_proof_module do
    Application.get_env(:maraithon, :onboarding_proof_module, OnboardingProof)
  end

  defp apply_dashboard_params(socket, params, uri) do
    user_id = current_user_id(socket)

    socket =
      assign(socket,
        connection_user_id: user_id,
        connection_return_to: connection_return_to_from_uri(uri),
        onboarding_preview_eligible?: OnboardingProof.eligible?(user_id)
      )

    maybe_put_oauth_flash(socket, params)
  end

  defp maybe_put_oauth_flash(socket, %{"oauth_status" => "connected", "oauth_message" => message})
       when is_binary(message) do
    put_flash(socket, :info, message)
  end

  defp maybe_put_oauth_flash(socket, %{"oauth_status" => "error", "oauth_message" => message})
       when is_binary(message) do
    put_flash(socket, :error, message)
  end

  defp maybe_put_oauth_flash(socket, _params), do: socket

  defp connection_return_to(socket) do
    socket.assigns.connection_return_to || "/dashboard"
  end

  defp connection_return_to_from_uri(uri) do
    uri = URI.parse(uri)

    query =
      (uri.query || "")
      |> URI.decode_query()
      |> Map.drop(["oauth_message", "oauth_provider", "oauth_status"])
      |> URI.encode_query()

    %URI{path: uri.path || "/", query: query}
    |> URI.to_string()
  rescue
    _ -> "/dashboard"
  end

  defp current_path_from_uri(uri) when is_binary(uri) do
    uri
    |> URI.parse()
    |> Map.get(:path)
    |> case do
      nil -> "/dashboard"
      "" -> "/dashboard"
      path -> path
    end
  rescue
    _ -> "/dashboard"
  end

  defp legacy_agents_path(%{"id" => _id} = params) do
    query =
      params
      |> Map.take(["id", "panel", "status", "q"])
      |> Enum.reject(fn
        {"panel", value} -> value not in ["inspect", "edit"]
        {"status", value} -> value in [nil, "", "all"]
        {"q", value} -> value in [nil, ""]
        {_key, value} -> is_nil(value) or value == ""
      end)
      |> URI.encode_query()

    case query do
      "" -> "/agents"
      encoded -> "/agents?" <> encoded
    end
  end

  defp legacy_agents_path(_params), do: nil

  defp current_user_id(socket), do: socket.assigns.current_user.id

  defp first_project_id([%{project: %{id: id}} | _]) when is_binary(id), do: id
  defp first_project_id(_projects), do: nil

  defp chief_of_staff_summary(%{summary: summary}) when is_binary(summary) and summary != "",
    do: summary

  defp chief_of_staff_summary(_package) do
    "Daily briefing, follow-through, commitment tracking, and Telegram delivery for one project."
  end

  defp chief_of_staff_install_state(%{install_status: install_status}, _readiness, _projects),
    do: install_status_label(install_status)

  defp chief_of_staff_install_state(_agent, _readiness, []), do: "project required"

  defp chief_of_staff_install_state(_agent, readiness, _projects) do
    if chief_of_staff_missing_readiness(readiness) == [] do
      "ready"
    else
      "setup required"
    end
  end

  defp chief_of_staff_badge_label(nil), do: "Not installed"
  defp chief_of_staff_badge_label(%{install_status: status}), do: install_status_label(status)

  defp chief_of_staff_badge_color(nil), do: "zinc"
  defp chief_of_staff_badge_color(%{install_status: "enabled"}), do: "emerald"
  defp chief_of_staff_badge_color(%{install_status: "setup_required"}), do: "amber"
  defp chief_of_staff_badge_color(_agent), do: "zinc"

  defp chief_of_staff_missing_readiness(readiness) when is_list(readiness) do
    Enum.reject(readiness, & &1.connected?)
  end

  defp chief_of_staff_missing_readiness(_readiness), do: []

  defp connector_chip_class(%{connected?: true}) do
    "inline-flex rounded-md bg-emerald-500/15 px-1.5 py-0.5 text-xs/5 font-medium text-emerald-700"
  end

  defp connector_chip_class(_item) do
    "inline-flex rounded-md bg-amber-400/20 px-1.5 py-0.5 text-xs/5 font-medium text-amber-700"
  end

  defp chief_of_staff_schedule_label(%{
         morning: %{display_time_local: time},
         local_timezone: timezone
       })
       when is_binary(time) and is_binary(timezone) do
    "#{time} #{timezone}"
  end

  defp chief_of_staff_schedule_label(_schedule), do: "8:00 AM UTC-05:00"

  defp install_status_label("enabled"), do: "enabled"
  defp install_status_label("setup_required"), do: "setup required"
  defp install_status_label("paused"), do: "paused"
  defp install_status_label("error"), do: "error"
  defp install_status_label("removed"), do: "removed"
  defp install_status_label(status) when is_binary(status), do: status
  defp install_status_label(_status), do: "unknown"

  defp show_onboarding_preview?(eligible?, agents), do: eligible? and agents == []

  defp agent_owned_by_current_user?(socket, agent_id) when is_binary(agent_id) do
    not is_nil(Agents.get_agent_for_user(agent_id, current_user_id(socket)))
  end

  defp agent_owned_by_current_user?(_socket, _agent_id), do: false

  defp provider_label("google"), do: "Google"
  defp provider_label("github"), do: "GitHub"
  defp provider_label("slack"), do: "Slack"
  defp provider_label("telegram"), do: "Telegram"
  defp provider_label("calendar"), do: "Calendar"
  defp provider_label("linear"), do: "Linear"
  defp provider_label("notion"), do: "Notion"
  defp provider_label(provider), do: provider

  defp memory_summary_label("content_preferences"), do: "Content Preferences"
  defp memory_summary_label("telegram_behavior"), do: "Conversation Style"
  defp memory_summary_label("action_style"), do: "Action Style"
  defp memory_summary_label("interrupt_policy"), do: "Interrupt Policy"
  defp memory_summary_label(label), do: label

  defp memory_profile_fields(memory_profile) when is_map(memory_profile) do
    profile = Map.get(memory_profile, :profile, %{})

    [
      {"Current Focus", Map.get(profile, "current_focus")},
      {"Working Style", Map.get(profile, "working_style")},
      {"Communication", Map.get(profile, "communication_style")},
      {"Decision Style", Map.get(profile, "decision_style")},
      {"Important Context", Map.get(profile, "important_context")}
    ]
    |> Enum.map(fn {label, value} -> %{label: label, value: value} end)
    |> Enum.reject(fn field -> is_nil(normalized_text(field.value)) end)
    |> Enum.take(3)
  end

  defp memory_profile_fields(_memory_profile), do: []

  defp memory_rule_kind_label("content_filter"), do: "Filter"
  defp memory_rule_kind_label("urgency_boost"), do: "Urgency"
  defp memory_rule_kind_label("quiet_hours"), do: "Quiet Hours"
  defp memory_rule_kind_label("routing_preference"), do: "Routing"
  defp memory_rule_kind_label("action_preference"), do: "Action"
  defp memory_rule_kind_label("style_preference"), do: "Style"
  defp memory_rule_kind_label(kind), do: humanize_text_token(kind) || "Preference"

  defp project_options(projects) when is_list(projects) do
    Enum.map(projects, fn %{project: project} -> {project.name, project.id} end)
  end

  defp project_options(_projects), do: []

  defp project_item_type_options(item_types) when is_list(item_types) do
    Enum.map(item_types, fn item_type -> {item_type_label(item_type), item_type} end)
  end

  defp project_item_type_options(_item_types), do: []

  defp project_status_class("active"),
    do:
      "inline-flex rounded-md bg-emerald-500/15 px-1.5 py-0.5 text-xs/5 font-medium text-emerald-700"

  defp project_status_class("paused"),
    do:
      "inline-flex rounded-md bg-amber-400/20 px-1.5 py-0.5 text-xs/5 font-medium text-amber-700"

  defp project_status_class(_status),
    do: "inline-flex rounded-md bg-zinc-600/10 px-1.5 py-0.5 text-xs/5 font-medium text-zinc-700"

  defp project_priority_class("critical"),
    do: "inline-flex rounded-md bg-rose-400/15 px-1.5 py-0.5 text-xs/5 font-medium text-rose-700"

  defp project_priority_class("high"),
    do:
      "inline-flex rounded-md bg-orange-400/15 px-1.5 py-0.5 text-xs/5 font-medium text-orange-700"

  defp project_priority_class("normal"),
    do: "inline-flex rounded-md bg-sky-500/15 px-1.5 py-0.5 text-xs/5 font-medium text-sky-700"

  defp project_priority_class(_priority),
    do: "inline-flex rounded-md bg-zinc-600/10 px-1.5 py-0.5 text-xs/5 font-medium text-zinc-700"

  defp project_summary(project) do
    project.summary || project.description || "No project summary yet."
  end

  defp item_type_label("todo"), do: "Todo"
  defp item_type_label("note"), do: "Note"
  defp item_type_label("decision"), do: "Decision"
  defp item_type_label("resource"), do: "Resource"
  defp item_type_label("grant"), do: "Grant"
  defp item_type_label(value), do: value

  defp recommendation_decision_label("accepted"), do: "Accepted"
  defp recommendation_decision_label("deferred"), do: "Deferred"
  defp recommendation_decision_label("rejected"), do: "Rejected"
  defp recommendation_decision_label(value), do: humanize_text_token(value) || "Decision"

  defp decision_label("accepted"), do: "accepted"
  defp decision_label("deferred"), do: "deferred"
  defp decision_label("rejected"), do: "rejected"
  defp decision_label(value), do: humanize_text_token(value) || "saved"

  defp repo_scope_label("read_only"), do: "Read only"
  defp repo_scope_label("branch_write"), do: "Branch write"
  defp repo_scope_label("pr_open"), do: "PR open"
  defp repo_scope_label(value), do: humanize_text_token(value) || "Repo scope"

  defp implementation_run_status_label("pending_plan"), do: "Planning"
  defp implementation_run_status_label("awaiting_repo_access"), do: "Awaiting Repo Access"
  defp implementation_run_status_label("queued"), do: "Queued"
  defp implementation_run_status_label("running"), do: "Running"
  defp implementation_run_status_label("blocked"), do: "Blocked"
  defp implementation_run_status_label("awaiting_review"), do: "Awaiting Review"
  defp implementation_run_status_label("completed"), do: "Completed"
  defp implementation_run_status_label("failed"), do: "Failed"
  defp implementation_run_status_label(value), do: humanize_text_token(value) || "Run"

  defp preview_source_label(source), do: provider_label(source)

  defp todo_status_label("open"), do: "Open"
  defp todo_status_label("snoozed"), do: "Snoozed"
  defp todo_status_label("done"), do: "Done"
  defp todo_status_label("dismissed"), do: "Dismissed"
  defp todo_status_label(value), do: humanize_text_token(value) || "Todo"

  defp todo_status_class("open"),
    do:
      "inline-flex rounded-md bg-emerald-500/15 px-1.5 py-0.5 text-xs/5 font-medium text-emerald-700"

  defp todo_status_class("snoozed"),
    do:
      "inline-flex rounded-md bg-amber-400/20 px-1.5 py-0.5 text-xs/5 font-medium text-amber-700"

  defp todo_status_class("done"),
    do: "inline-flex rounded-md bg-sky-500/15 px-1.5 py-0.5 text-xs/5 font-medium text-sky-700"

  defp todo_status_class(_status),
    do: "inline-flex rounded-md bg-zinc-600/10 px-1.5 py-0.5 text-xs/5 font-medium text-zinc-700"

  defp todo_source_label(source), do: insight_source_label(source)

  defp todo_context_line(todo) do
    [
      todo_source_account_label(todo),
      todo.snoozed_until && "snoozed until #{format_datetime(todo.snoozed_until)}",
      "updated #{format_datetime(todo.updated_at)}"
    ]
    |> Enum.reject(&blank_metadata?/1)
    |> Enum.join(" · ")
  end

  defp todo_source_account_label(todo) do
    metadata = todo.metadata || %{}

    metadata_account =
      fetch_map_value(metadata, "account") ||
        fetch_map_value(metadata, "account_email") ||
        fetch_map_value(metadata, "mailbox") ||
        fetch_map_value(metadata, "workspace_name")

    case normalized_text(metadata_account) do
      nil -> nil
      value -> "account #{value}"
    end
  end

  defp agent_display_name(agent) do
    get_in(agent.config || %{}, ["name"]) ||
      get_in(agent.config || %{}, [:name]) ||
      humanize_text_token(agent.behavior) ||
      "Agent"
  end

  defp agent_status_class("running"),
    do:
      "inline-flex rounded-md bg-emerald-500/15 px-1.5 py-0.5 text-xs/5 font-medium text-emerald-700"

  defp agent_status_class("degraded"),
    do:
      "inline-flex rounded-md bg-amber-400/20 px-1.5 py-0.5 text-xs/5 font-medium text-amber-700"

  defp agent_status_class("stopped"),
    do: "inline-flex rounded-md bg-zinc-600/10 px-1.5 py-0.5 text-xs/5 font-medium text-zinc-700"

  defp agent_status_class(_status),
    do: "inline-flex rounded-md bg-sky-500/15 px-1.5 py-0.5 text-xs/5 font-medium text-sky-700"

  defp preview_source_class("gmail"),
    do: "inline-flex rounded-md bg-rose-400/15 px-1.5 py-0.5 text-xs/5 font-medium text-rose-700"

  defp preview_source_class("calendar"),
    do:
      "inline-flex rounded-md bg-amber-400/20 px-1.5 py-0.5 text-xs/5 font-medium text-amber-700"

  defp preview_source_class("slack"),
    do:
      "inline-flex rounded-md bg-violet-500/15 px-1.5 py-0.5 text-xs/5 font-medium text-violet-700"

  defp preview_source_class(_),
    do: "inline-flex rounded-md bg-zinc-600/10 px-1.5 py-0.5 text-xs/5 font-medium text-zinc-700"

  defp onboarding_behavior_label("founder_followthrough_agent"), do: "Chief of Staff"
  defp onboarding_behavior_label("inbox_calendar_advisor"), do: "Chief of Staff"
  defp onboarding_behavior_label("slack_followthrough_agent"), do: "Slack Followthrough"
  defp onboarding_behavior_label(other), do: other

  defp insight_category_label("reply_urgent"), do: "Reply Needed"
  defp insight_category_label("tone_risk"), do: "Tone Risk"
  defp insight_category_label("event_important"), do: "Important Event"
  defp insight_category_label("event_prep_needed"), do: "Prep Needed"
  defp insight_category_label("commitment_unresolved"), do: "Commitment Due"
  defp insight_category_label("meeting_follow_up"), do: "Meeting Follow-Up"
  defp insight_category_label("product_opportunity"), do: "Roadmap"
  defp insight_category_label(_), do: "Insight"

  defp insight_source_label("gmail"), do: "Gmail"
  defp insight_source_label("calendar"), do: "Google Calendar"
  defp insight_source_label("google_calendar"), do: "Google Calendar"
  defp insight_source_label("slack"), do: "Slack"
  defp insight_source_label("github"), do: "GitHub"
  defp insight_source_label("telegram"), do: "Telegram"
  defp insight_source_label(source) when is_binary(source) and source != "", do: source
  defp insight_source_label(_), do: "system"

  defp attention_mode_label("monitor"), do: "Watching"
  defp attention_mode_label(_), do: "Needs Action"

  defp attention_mode_class("monitor"),
    do: "inline-flex rounded-md bg-sky-500/15 px-1.5 py-0.5 text-xs/5 font-medium text-sky-700"

  defp attention_mode_class(_),
    do:
      "inline-flex rounded-md bg-emerald-500/15 px-1.5 py-0.5 text-xs/5 font-medium text-emerald-700"

  defp insight_category_class("reply_urgent"),
    do:
      "inline-flex rounded-md bg-emerald-500/15 px-1.5 py-0.5 text-xs/5 font-medium text-emerald-700"

  defp insight_category_class("tone_risk"),
    do: "inline-flex rounded-md bg-rose-400/15 px-1.5 py-0.5 text-xs/5 font-medium text-rose-700"

  defp insight_category_class("event_important"),
    do:
      "inline-flex rounded-md bg-indigo-500/15 px-1.5 py-0.5 text-xs/5 font-medium text-indigo-700"

  defp insight_category_class("event_prep_needed"),
    do:
      "inline-flex rounded-md bg-amber-400/20 px-1.5 py-0.5 text-xs/5 font-medium text-amber-700"

  defp insight_category_class("commitment_unresolved"),
    do: "inline-flex rounded-md bg-rose-400/15 px-1.5 py-0.5 text-xs/5 font-medium text-rose-700"

  defp insight_category_class("meeting_follow_up"),
    do: "inline-flex rounded-md bg-sky-500/15 px-1.5 py-0.5 text-xs/5 font-medium text-sky-700"

  defp insight_category_class("product_opportunity"),
    do: "inline-flex rounded-md bg-cyan-400/20 px-1.5 py-0.5 text-xs/5 font-medium text-cyan-800"

  defp insight_category_class(_),
    do: "inline-flex rounded-md bg-zinc-600/10 px-1.5 py-0.5 text-xs/5 font-medium text-zinc-700"

  defp insight_priority_class(priority) when is_integer(priority) and priority >= 80,
    do: "inline-flex rounded-md bg-red-500/15 px-1.5 py-0.5 text-xs/5 font-medium text-red-700"

  defp insight_priority_class(priority) when is_integer(priority) and priority >= 60,
    do:
      "inline-flex rounded-md bg-amber-400/20 px-1.5 py-0.5 text-xs/5 font-medium text-amber-700"

  defp insight_priority_class(_),
    do: "inline-flex rounded-md bg-zinc-600/10 px-1.5 py-0.5 text-xs/5 font-medium text-zinc-700"

  defp format_confidence(value) when is_float(value), do: "#{Float.round(value * 100, 0)}%"
  defp format_confidence(value) when is_integer(value), do: "#{value}%"
  defp format_confidence(_), do: "n/a"

  defp insight_account_label(insight) do
    metadata_account =
      insight_metadata_value(insight, "account") ||
        insight_metadata_value(insight, "account_email") ||
        insight_metadata_value(insight, "mailbox") ||
        insight_metadata_value(insight, "workspace_name") ||
        insight_metadata_value(insight, "team_name")

    case normalized_text(metadata_account) do
      nil ->
        insight_source_account_fallback(insight) || "unknown"

      value ->
        value
    end
  end

  defp insight_source_account_fallback(insight) do
    source = normalized_text(Map.get(insight, :source))

    case source do
      "slack" ->
        normalized_text(insight_metadata_value(insight, "team_id"))

      _ ->
        nil
    end
  end

  defp insight_why_now(insight) do
    case insight_metadata_value(insight, "why_now") do
      value when is_binary(value) ->
        value = String.trim(value)
        if value == "", do: nil, else: value

      _ ->
        nil
    end
  end

  defp insight_follow_up_ideas(insight) do
    case insight_metadata_value(insight, "follow_up_ideas") do
      values when is_list(values) ->
        values
        |> Enum.map(fn
          value when is_binary(value) ->
            value = String.trim(value)
            if value == "", do: nil, else: value

          _ ->
            nil
        end)
        |> Enum.reject(&is_nil/1)

      _ ->
        []
    end
  end

  defp insight_metadata_value(%{metadata: metadata}, key)
       when is_map(metadata) and is_binary(key) do
    case Map.fetch(metadata, key) do
      {:ok, value} ->
        value

      :error ->
        Enum.find_value(metadata, fn
          {map_key, value} when is_atom(map_key) -> if Atom.to_string(map_key) == key, do: value
          _ -> nil
        end)
    end
  end

  defp insight_metadata_value(_insight, _key), do: nil

  defp fetch_map_value(map, key) when is_map(map) and is_binary(key) do
    case Map.fetch(map, key) do
      {:ok, value} ->
        value

      :error ->
        Enum.find_value(map, fn
          {map_key, value} when is_atom(map_key) ->
            if Atom.to_string(map_key) == key, do: value

          _ ->
            nil
        end)
    end
  end

  defp fetch_map_value(_map, _key), do: nil

  defp normalized_text(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      text -> text
    end
  end

  defp normalized_text(_value), do: nil

  defp detail_text(%{text: text}) when is_binary(text), do: text
  defp detail_text(_value), do: nil

  defp detail_origin_label(%{origin: :stored}), do: "Stored"
  defp detail_origin_label(%{origin: :reconstructed}), do: "Reconstructed"
  defp detail_origin_label(%{origin: :derived}), do: "Derived"
  defp detail_origin_label(_value), do: nil

  defp reason_origin_label(%{origin: :stored}), do: "Stored rationale"
  defp reason_origin_label(%{origin: :derived}), do: "Derived from persisted evidence"
  defp reason_origin_label(_value), do: nil

  defp evidence_metadata(item) when is_map(item) do
    [
      humanize_text_token(item.kind),
      format_datetime(item.occurred_at),
      item.source_ref
    ]
    |> Enum.reject(&blank_metadata?/1)
    |> Enum.join(" · ")
  end

  defp evidence_metadata(_item), do: nil

  defp delivery_metadata(delivery) when is_map(delivery) do
    [
      format_datetime(delivery.sent_at),
      delivery.feedback && "feedback #{humanize_text_token(delivery.feedback)}",
      delivery.feedback_at && format_datetime(delivery.feedback_at),
      delivery.error_message && "error #{delivery.error_message}"
    ]
    |> Enum.reject(&blank_metadata?/1)
    |> Enum.join(" · ")
  end

  defp delivery_metadata(_delivery), do: nil

  defp humanize_text_token(value) when is_atom(value),
    do: value |> Atom.to_string() |> humanize_text_token()

  defp humanize_text_token(value) when is_binary(value) do
    value
    |> String.replace("_", " ")
    |> String.trim()
    |> case do
      "" -> nil
      text -> String.capitalize(text)
    end
  end

  defp humanize_text_token(_value), do: nil

  defp blank_metadata?(nil), do: true
  defp blank_metadata?(""), do: true
  defp blank_metadata?("N/A"), do: true
  defp blank_metadata?(_value), do: false

  defp reviewable_todos(todos, decided_ids) when is_list(todos) do
    decided_ids = normalize_todo_review_decided_ids(decided_ids)

    Enum.reject(todos, fn todo ->
      MapSet.member?(decided_ids, todo.id)
    end)
  end

  defp reviewable_todos(_todos, _decided_ids), do: []

  defp prune_todo_review_decided_ids(decided_ids, todos) when is_list(todos) do
    current_ids = MapSet.new(Enum.map(todos, & &1.id))

    decided_ids
    |> normalize_todo_review_decided_ids()
    |> MapSet.intersection(current_ids)
  end

  defp prune_todo_review_decided_ids(_decided_ids, _todos), do: MapSet.new()

  defp normalize_todo_review_decided_ids(%MapSet{} = decided_ids), do: decided_ids
  defp normalize_todo_review_decided_ids(_decided_ids), do: MapSet.new()

  defp review_todo(todos, index) when is_list(todos) do
    Enum.at(todos, clamp_review_index(index, length(todos)))
  end

  defp review_todo(_todos, _index), do: nil

  defp review_queue_preview(todos, index) when is_list(todos) do
    todos
    |> Enum.drop(clamp_review_index(index, length(todos)) + 1)
    |> Enum.take(4)
  end

  defp review_queue_preview(_todos, _index), do: []

  defp todo_review_position(todos, index) when is_list(todos) do
    case length(todos) do
      0 -> "0 of 0"
      count -> "#{clamp_review_index(index, count) + 1} of #{count}"
    end
  end

  defp todo_review_position(_todos, _index), do: "0 of 0"

  defp todo_review_progress_width(todos, index) when is_list(todos) do
    case length(todos) do
      0 -> 0
      count -> round((clamp_review_index(index, count) + 1) * 100 / count)
    end
  end

  defp todo_review_progress_width(_todos, _index), do: 0

  defp todo_review_session_label(session) when is_map(session) do
    reviewed =
      [:completed, :dismissed, :kept, :important]
      |> Enum.map(&Map.get(session, &1, 0))
      |> Enum.sum()

    if reviewed == 0 do
      "No review actions yet"
    else
      "#{reviewed} reviewed this session"
    end
  end

  defp todo_review_session_label(_session), do: "No review actions yet"

  defp clamp_review_index(_index, count) when not is_integer(count) or count <= 0, do: 0

  defp clamp_review_index(index, count) when is_integer(index) do
    index
    |> max(0)
    |> min(count - 1)
  end

  defp clamp_review_index(_index, count), do: clamp_review_index(0, count)

  defp todo_context_items(todo) do
    metadata = todo.metadata || %{}

    [
      %{
        label: "Person",
        value:
          todo_metadata_text(
            metadata,
            ~w(person contact requested_by requester sender sender_name)
          )
      },
      %{
        label: "Company",
        value:
          todo_metadata_text(metadata, ~w(company organization account_name customer partner))
      },
      %{
        label: "Relationship",
        value: todo_metadata_text(metadata, ~w(relationship relationship_context context_brief))
      },
      %{
        label: "Project",
        value: todo_metadata_text(metadata, ~w(project project_name omni_project topic))
      },
      %{label: "Account", value: todo_source_account_label(todo)},
      %{label: "Due", value: todo.due_at && format_datetime(todo.due_at)}
    ]
    |> Enum.reject(fn item -> blank_metadata?(item.value) end)
    |> Enum.take(6)
  end

  defp todo_why_important(todo) do
    metadata = todo.metadata || %{}

    todo_metadata_text(metadata, ~w(why_now why_it_matters why rationale urgency_reason))
    |> case do
      nil when not is_nil(todo.due_at) ->
        "Due #{format_datetime(todo.due_at)}."

      nil ->
        "#{attention_mode_label(todo.attention_mode)} item from #{todo_source_label(todo.source)}. Last updated #{format_datetime(todo.updated_at)}."

      value ->
        value
    end
  end

  defp todo_source_excerpt(todo) do
    todo.metadata
    |> todo_metadata_text(
      ~w(source_quote quote source_excerpt body_excerpt excerpt evidence source_body source_evidence checked_evidence)
    )
    |> case do
      nil -> nil
      value -> truncate(value, 280)
    end
  end

  defp todo_action_hint(todo) do
    next_action = String.downcase(todo.next_action || "")

    cond do
      todo_action_draft_present?(todo) ->
        "Draft material is ready for approval."

      todo.source == "gmail" and String.contains?(next_action, ["reply", "email"]) ->
        "Maraithon can draft the reply for approval."

      todo.source == "slack" and String.contains?(next_action, ["reply", "respond", "message"]) ->
        "Maraithon can draft the Slack response for approval."

      true ->
        nil
    end
  end

  defp todo_priority_label(%{attention_mode: "monitor"}), do: "watching"

  defp todo_priority_label(%{priority: priority}) when is_integer(priority) and priority >= 85,
    do: "high priority"

  defp todo_priority_label(%{priority: priority}) when is_integer(priority) and priority >= 70,
    do: "priority"

  defp todo_priority_label(_todo), do: "normal priority"

  defp todo_metadata_text(metadata, keys) when is_map(metadata) and is_list(keys) do
    Enum.find_value(keys, fn key ->
      metadata
      |> fetch_map_value(key)
      |> display_metadata_value()
    end)
  end

  defp todo_metadata_text(_metadata, _keys), do: nil

  defp display_metadata_value(value) when is_binary(value), do: normalized_text(value)

  defp display_metadata_value(value) when is_atom(value),
    do: value |> Atom.to_string() |> normalized_text()

  defp display_metadata_value(value) when is_integer(value), do: Integer.to_string(value)
  defp display_metadata_value(value) when is_float(value), do: Float.to_string(value)
  defp display_metadata_value(%DateTime{} = value), do: format_datetime(value)
  defp display_metadata_value(%NaiveDateTime{} = value), do: format_datetime(value)

  defp display_metadata_value(values) when is_list(values) do
    values
    |> Enum.map(&display_metadata_value/1)
    |> Enum.reject(&blank_metadata?/1)
    |> case do
      [] -> nil
      parts -> Enum.join(parts, "; ")
    end
  end

  defp display_metadata_value(value) when is_map(value) do
    Enum.find_value(
      ~w(display_name name title email company organization relationship summary text body value),
      fn key ->
        value
        |> fetch_map_value(key)
        |> display_metadata_value()
      end
    )
  end

  defp display_metadata_value(_value), do: nil

  defp todo_action_draft_present?(%{action_draft: draft}) when is_map(draft) do
    draft
    |> Map.values()
    |> Enum.any?(&present_action_draft_value?/1)
  end

  defp todo_action_draft_present?(_todo), do: false

  defp present_action_draft_value?(value) when is_binary(value), do: String.trim(value) != ""

  defp present_action_draft_value?(values) when is_list(values),
    do: Enum.any?(values, &present_action_draft_value?/1)

  defp present_action_draft_value?(value) when is_map(value) do
    value
    |> Map.values()
    |> Enum.any?(&present_action_draft_value?/1)
  end

  defp present_action_draft_value?(value), do: not is_nil(value)

  attr :todos, :list, required: true
  attr :todo_review_index, :integer, required: true
  attr :todo_review_session, :map, required: true
  attr :todo_review_decided_ids, :any, required: true

  defp todo_review_board(assigns) do
    review_todos = reviewable_todos(assigns.todos, assigns.todo_review_decided_ids)
    current_todo = review_todo(review_todos, assigns.todo_review_index)

    assigns =
      assigns
      |> assign(:current_todo, current_todo)
      |> assign(:queue_preview, review_queue_preview(review_todos, assigns.todo_review_index))
      |> assign(:review_position, todo_review_position(review_todos, assigns.todo_review_index))
      |> assign(
        :progress_width,
        todo_review_progress_width(review_todos, assigns.todo_review_index)
      )
      |> assign(:can_go_previous, assigns.todo_review_index > 0)
      |> assign(:can_go_next, assigns.todo_review_index + 1 < length(review_todos))

    ~H"""
    <section id="todo-review" class="overflow-hidden rounded-lg border border-zinc-950/10 bg-white shadow-sm">
      <div class="border-b border-zinc-950/10 px-4 py-4 sm:px-6">
        <div class="flex flex-wrap items-start justify-between gap-4">
          <div>
            <div class="flex flex-wrap items-center gap-2">
              <h2 class="text-base/7 font-semibold text-zinc-950">Today's cards</h2>
              <.badge color="emerald" class="bg-white">
                Review queue
              </.badge>
            </div>
            <p class="mt-1 text-sm/6 text-zinc-600">
              Decide open loops one at a time.
            </p>
          </div>
          <div class="text-right">
            <p class="text-sm/6 font-medium text-zinc-950"><%= @review_position %></p>
            <p class="text-xs/5 text-zinc-500">
              <%= todo_review_session_label(@todo_review_session) %>
            </p>
          </div>
        </div>
      </div>

      <%= if @current_todo do %>
        <div class="grid grid-cols-1 lg:grid-cols-[minmax(0,1fr)_18rem] lg:divide-x lg:divide-zinc-950/10">
          <article id={"todo-review-card-#{@current_todo.id}"} class="px-4 py-5 sm:px-6">
            <div class="flex flex-wrap items-center gap-2">
              <span class={todo_status_class(@current_todo.status)}>
                <%= todo_status_label(@current_todo.status) %>
              </span>
              <span class={attention_mode_class(@current_todo.attention_mode)}>
                <%= attention_mode_label(@current_todo.attention_mode) %>
              </span>
              <span class="inline-flex rounded-md bg-zinc-600/10 px-1.5 py-0.5 text-xs/5 font-medium text-zinc-700">
                <%= todo_source_label(@current_todo.source) %>
              </span>
              <span :if={@current_todo.due_at} class="text-xs/5 font-medium text-amber-700">
                due <%= format_datetime(@current_todo.due_at) %>
              </span>
            </div>

            <h3 class="mt-3 text-xl/7 font-semibold tracking-tight text-zinc-950 sm:text-lg/7">
              <%= @current_todo.title %>
            </h3>
            <p :if={@current_todo.summary not in [nil, ""]} class="mt-2 text-sm/6 text-zinc-600">
              <%= @current_todo.summary %>
            </p>

            <dl :if={todo_context_items(@current_todo) != []} class="mt-5 grid grid-cols-1 gap-x-6 gap-y-3 sm:grid-cols-2">
              <div :for={item <- todo_context_items(@current_todo)} class="border-l border-zinc-950/10 pl-3">
                <dt class="text-xs/5 font-medium text-zinc-500"><%= item.label %></dt>
                <dd class="mt-0.5 text-sm/6 text-zinc-800"><%= item.value %></dd>
              </div>
            </dl>

            <div class="mt-5 grid grid-cols-1 gap-x-6 gap-y-4 lg:grid-cols-2">
              <div class="border-l border-zinc-950/10 pl-3">
                <p class="text-xs/5 font-medium text-zinc-500">Why important</p>
                <p class="mt-1 text-sm/6 text-zinc-700"><%= todo_why_important(@current_todo) %></p>
              </div>
              <div class="border-l border-zinc-950/10 pl-3">
                <p class="text-xs/5 font-medium text-zinc-500">Suggested next step</p>
                <p class="mt-1 text-sm/6 text-zinc-700"><%= @current_todo.next_action %></p>
                <p :if={todo_action_hint(@current_todo)} class="mt-2 text-sm/6 font-medium text-indigo-700">
                  <%= todo_action_hint(@current_todo) %>
                </p>
              </div>
            </div>

            <div :if={todo_source_excerpt(@current_todo)} class="mt-5 border-l border-zinc-950/10 pl-3">
              <p class="text-xs/5 font-medium text-zinc-500">Source context</p>
              <p class="mt-1 text-sm/6 text-zinc-700"><%= todo_source_excerpt(@current_todo) %></p>
            </div>

            <div class="mt-6 flex flex-wrap items-center gap-2">
              <.button
                type="button"
                phx-click="review_complete_todo"
                phx-value-id={@current_todo.id}
              >
                Mark done
              </.button>
              <.button
                type="button"
                phx-click="review_mark_important"
                phx-value-id={@current_todo.id}
                variant="outline"
                class="text-amber-800"
              >
                Important
              </.button>
              <.button
                type="button"
                phx-click="review_keep_todo"
                phx-value-id={@current_todo.id}
                variant="outline"
              >
                Keep open
              </.button>
              <.button
                type="button"
                phx-click="review_dismiss_todo"
                phx-value-id={@current_todo.id}
                variant="outline"
                class="text-rose-700"
              >
                Dismiss
              </.button>

              <div class="ml-auto flex items-center gap-1">
                <.button
                  type="button"
                  phx-click="review_previous_todo"
                  variant="plain"
                  disabled={not @can_go_previous}
                  class="text-xs text-zinc-500"
                >
                  Previous
                </.button>
                <.button
                  type="button"
                  phx-click="review_next_todo"
                  variant="plain"
                  disabled={not @can_go_next}
                  class="text-xs text-zinc-500"
                >
                  Next
                </.button>
              </div>
            </div>
          </article>

          <aside class="bg-zinc-50 px-4 py-5 sm:px-6">
            <div class="h-1.5 overflow-hidden rounded-full bg-zinc-200">
              <div class="h-full rounded-full bg-zinc-950" style={"width: #{@progress_width}%"} />
            </div>

            <dl class="mt-4 grid grid-cols-2 gap-3 text-sm/6">
              <div>
                <dt class="text-xs/5 font-medium text-zinc-500">Done</dt>
                <dd class="mt-0.5 font-semibold text-zinc-950">
                  <%= Map.get(@todo_review_session, :completed, 0) %>
                </dd>
              </div>
              <div>
                <dt class="text-xs/5 font-medium text-zinc-500">Dismissed</dt>
                <dd class="mt-0.5 font-semibold text-zinc-950">
                  <%= Map.get(@todo_review_session, :dismissed, 0) %>
                </dd>
              </div>
              <div>
                <dt class="text-xs/5 font-medium text-zinc-500">Kept</dt>
                <dd class="mt-0.5 font-semibold text-zinc-950">
                  <%= Map.get(@todo_review_session, :kept, 0) %>
                </dd>
              </div>
              <div>
                <dt class="text-xs/5 font-medium text-zinc-500">Important</dt>
                <dd class="mt-0.5 font-semibold text-zinc-950">
                  <%= Map.get(@todo_review_session, :important, 0) %>
                </dd>
              </div>
            </dl>

            <div :if={@queue_preview != []} class="mt-6">
              <p class="text-xs/5 font-medium text-zinc-500">Up next</p>
              <ul role="list" class="mt-2 divide-y divide-zinc-950/5">
                <li :for={todo <- @queue_preview} class="py-2">
                  <p class="line-clamp-2 text-sm/6 font-medium text-zinc-950"><%= todo.title %></p>
                  <p class="mt-0.5 text-xs/5 text-zinc-500">
                    <%= todo_source_label(todo.source) %> · <%= todo_priority_label(todo) %>
                  </p>
                </li>
              </ul>
            </div>
            <p :if={@queue_preview == []} class="mt-6 text-sm/6 text-zinc-500">
              No more cards in this queue.
            </p>
          </aside>
        </div>
      <% else %>
        <div class="px-4 py-8 sm:px-6">
          <%= if @todos == [] do %>
            <p class="text-sm/6 font-medium text-zinc-950">No open cards.</p>
            <p class="mt-1 text-sm/6 text-zinc-500">
              Maraithon will add cards here as it turns connected activity into durable todos.
            </p>
          <% else %>
            <p class="text-sm/6 font-medium text-zinc-950">Review complete for this session.</p>
            <p class="mt-1 text-sm/6 text-zinc-500">
              <%= length(@todos) %> open <%= if length(@todos) == 1, do: "card remains", else: "cards remain" %> in Today.
            </p>
          <% end %>
        </div>
      <% end %>
    </section>
    """
  end

  attr :title, :string, required: true
  attr :subtitle, :string, default: nil
  attr :cards, :list, required: true
  attr :expanded_insight_ids, :any, required: true

  defp insight_group(assigns) do
    ~H"""
    <section :if={@cards != []} class="overflow-hidden rounded-lg border border-zinc-950/10">
      <div class="border-b border-zinc-950/10 bg-zinc-50 px-4 py-4">
        <div class="flex items-center justify-between gap-3">
          <div>
            <h3 class="text-sm/6 font-semibold text-zinc-950"><%= @title %></h3>
            <p :if={@subtitle} class="mt-1 text-sm/6 text-zinc-600"><%= @subtitle %></p>
          </div>
          <.badge class="bg-white">
            <%= length(@cards) %>
          </.badge>
        </div>
      </div>

      <div class="divide-y divide-zinc-950/5">
        <%= for card <- @cards do %>
          <% insight = card.insight %>
          <% detail = card.detail %>
          <% expanded? = MapSet.member?(@expanded_insight_ids, insight.id) %>
          <div class="px-4 py-4">
            <div class="flex flex-wrap items-start justify-between gap-3">
              <div class="min-w-0 flex-1">
                <div class="flex flex-wrap items-center gap-2">
                  <span class={attention_mode_class(insight.attention_mode)}>
                    <%= attention_mode_label(insight.attention_mode) %>
                  </span>
                  <span class={insight_category_class(insight.category)}>
                    <%= insight_category_label(insight.category) %>
                  </span>
                  <span class={insight_priority_class(insight.priority)}>
                    P<%= insight.priority %>
                  </span>
                  <span class="text-xs/5 text-zinc-500">
                    confidence <%= format_confidence(insight.confidence) %>
                  </span>
                  <span :if={insight.due_at} class="text-xs/5 text-amber-700">
                    due <%= format_datetime(insight.due_at) %>
                  </span>
                </div>
                <p class="mt-2 text-sm/6 font-semibold text-zinc-950"><%= insight.title %></p>
                <p class="mt-1 text-xs/5 text-zinc-500">
                  from <%= insight_source_label(insight.source) %> · account <%= insight_account_label(insight) %>
                </p>
                <p class="mt-1 text-sm/6 text-zinc-600"><%= insight.summary %></p>
                <p class="mt-2 text-sm/6 text-indigo-700">
                  <span class="font-medium">
                    <%= if insight.attention_mode == "monitor", do: "Watch:", else: "Action:" %>
                  </span>
                  <%= insight.recommended_action %>
                </p>
                <% why_now = insight_why_now(insight) %>
                <%= if why_now do %>
                  <p class="mt-2 text-xs/5 font-medium text-zinc-500">
                    Why now
                  </p>
                  <p class="mt-1 text-sm/6 text-zinc-600"><%= why_now %></p>
                <% end %>
                <% ideas = insight_follow_up_ideas(insight) %>
                <%= if ideas != [] do %>
                  <p class="mt-2 text-xs/5 font-medium text-zinc-500">
                    Ideas
                  </p>
                  <ul class="mt-1 space-y-1 text-sm/6 text-zinc-600">
                    <%= for idea <- ideas do %>
                      <li>- <%= idea %></li>
                    <% end %>
                  </ul>
                <% end %>
                <.button
                  type="button"
                  phx-click="toggle_insight_detail"
                  phx-value-id={insight.id}
                  aria-expanded={to_string(expanded?)}
                  aria-controls={"insight-detail-#{insight.id}"}
                  variant="outline"
                  class="mt-3 text-xs"
                >
                  <%= if expanded?, do: "Hide evidence", else: "Show evidence" %>
                </.button>

                <%= if expanded? do %>
                  <div
                    id={"insight-detail-#{insight.id}"}
                    class="mt-4 space-y-4 rounded-lg border border-zinc-950/10 bg-zinc-50 p-4"
                  >
                    <.insight_detail_section
                      title="Exact promise"
                      value={detail_text(detail.promise_text) || "Exact promise not captured for this insight."}
                      origin={detail_origin_label(detail.promise_text)}
                    />
                    <.insight_detail_section
                      title="Who asked"
                      value={detail_text(detail.requested_by) || "Requester not captured for this insight."}
                      origin={detail_origin_label(detail.requested_by)}
                    />
                    <div class="space-y-2">
                      <div class="flex items-center gap-2">
                        <p class="text-xs/5 font-medium text-zinc-500">
                          Evidence checked
                        </p>
                      </div>
                      <%= if detail.evidence_checked == [] do %>
                        <p class="text-sm/6 text-zinc-600">
                          No persisted evidence bullets were captured for this insight.
                        </p>
                      <% else %>
                        <ul class="space-y-2 text-sm/6 text-zinc-700">
                          <%= for item <- detail.evidence_checked do %>
                            <li class="rounded-lg border border-zinc-950/10 bg-white px-3 py-2">
                              <p class="font-medium text-zinc-950"><%= item.label %></p>
                              <p :if={item.detail} class="mt-1 text-zinc-600"><%= item.detail %></p>
                              <p class="mt-1 text-xs/5 text-zinc-500">
                                <%= evidence_metadata(item) %>
                              </p>
                            </li>
                          <% end %>
                        </ul>
                      <% end %>
                    </div>
                    <div class="space-y-2">
                      <div class="flex items-center gap-2">
                        <p class="text-xs/5 font-medium text-zinc-500">
                          Delivery evidence checked
                        </p>
                      </div>
                      <%= if detail.delivery_evidence == [] do %>
                        <p class="text-sm/6 text-zinc-600">No delivery attempts recorded.</p>
                      <% else %>
                        <ul class="space-y-2 text-sm/6 text-zinc-700">
                          <%= for delivery <- detail.delivery_evidence do %>
                            <li class="rounded-lg border border-zinc-950/10 bg-white px-3 py-2">
                              <div class="flex flex-wrap items-center gap-2">
                                <span class="font-medium text-zinc-950">
                                  <%= humanize_text_token(delivery.channel) %>
                                </span>
                                <.badge>
                                  <%= humanize_text_token(delivery.status) %>
                                </.badge>
                              </div>
                              <p class="mt-1 text-zinc-600"><%= delivery.destination_label %></p>
                              <p class="mt-1 text-xs/5 text-zinc-500">
                                <%= delivery_metadata(delivery) %>
                              </p>
                            </li>
                          <% end %>
                        </ul>
                      <% end %>
                    </div>
                    <div class="space-y-2">
                      <div class="flex items-center gap-2">
                        <p class="text-xs/5 font-medium text-zinc-500">
                          Why Maraithon still thinks this is open
                        </p>
                        <.badge
                          :if={detail.open_loop_reason}
                          class="bg-white"
                        >
                          <%= reason_origin_label(detail.open_loop_reason) %>
                        </.badge>
                      </div>
                      <%= if detail.open_loop_reason do %>
                        <p class="text-sm/6 text-zinc-700"><%= detail.open_loop_reason.text %></p>
                        <ul
                          :if={detail.open_loop_reason.origin == :derived and detail.open_loop_reason.factors != []}
                          class="space-y-1 text-sm/6 text-zinc-600"
                        >
                          <%= for factor <- detail.open_loop_reason.factors do %>
                            <li>- <%= factor %></li>
                          <% end %>
                        </ul>
                      <% else %>
                        <p class="text-sm/6 text-zinc-600">
                          Open-loop reason could not be reconstructed from persisted data.
                        </p>
                      <% end %>
                    </div>
                    <div :if={detail.data_gaps != []} class="space-y-2">
                      <p class="text-xs/5 font-medium text-zinc-500">
                        Data gaps
                      </p>
                      <ul class="space-y-1 text-sm/6 text-zinc-600">
                        <%= for gap <- detail.data_gaps do %>
                          <li>- <%= gap %></li>
                        <% end %>
                      </ul>
                    </div>
                  </div>
                <% end %>
              </div>
              <div class="flex flex-wrap gap-2">
                <.button
                  type="button"
                  phx-click="ack_insight"
                  phx-value-id={insight.id}
                  variant="outline"
                  class="text-xs text-emerald-800"
                >
                  Acknowledge
                </.button>
                <.button
                  type="button"
                  phx-click="snooze_insight"
                  phx-value-id={insight.id}
                  variant="outline"
                  class="text-xs text-amber-800"
                >
                  Snooze 4h
                </.button>
                <.button
                  type="button"
                  phx-click="dismiss_insight"
                  phx-value-id={insight.id}
                  variant="outline"
                  class="text-xs text-rose-700"
                >
                  Dismiss
                </.button>
              </div>
            </div>
          </div>
        <% end %>
      </div>
    </section>
    """
  end

  attr :title, :string, required: true
  attr :value, :string, default: nil
  attr :origin, :string, default: nil

  defp insight_detail_section(assigns) do
    ~H"""
    <div class="space-y-2">
      <div class="flex items-center gap-2">
        <p class="text-xs/5 font-medium text-zinc-500">
          <%= @title %>
        </p>
        <span
          :if={@origin}
          class="rounded-md bg-white px-1.5 py-0.5 text-xs/5 font-medium text-zinc-600 ring-1 ring-zinc-950/10"
        >
          <%= @origin %>
        </span>
      </div>
      <p class="text-sm/6 text-zinc-700"><%= @value %></p>
    </div>
    """
  end

  defp health_badge_class(:healthy),
    do:
      "inline-flex rounded-md bg-emerald-500/15 px-1.5 py-0.5 text-xs/5 font-medium text-emerald-700"

  defp health_badge_class(:unhealthy),
    do: "inline-flex rounded-md bg-red-500/15 px-1.5 py-0.5 text-xs/5 font-medium text-red-700"

  defp health_badge_class(_),
    do: "inline-flex rounded-md bg-zinc-600/10 px-1.5 py-0.5 text-xs/5 font-medium text-zinc-700"

  attr :title, :string, required: true
  attr :value, :any, required: true
  attr :value_class, :string, default: "text-zinc-950"

  defp stat_card(assigns) do
    ~H"""
    <div class="overflow-hidden rounded-lg border border-zinc-950/10 bg-white px-4 py-5 shadow-sm sm:p-6">
      <dt class="truncate text-sm/6 font-medium text-zinc-500"><%= @title %></dt>
      <dd class={"mt-1 text-3xl/9 font-semibold tracking-tight #{@value_class}"}><%= @value %></dd>
    </div>
    """
  end

  attr :label, :string, required: true
  attr :value, :any, required: true
  attr :unit, :string, default: nil
  attr :description, :string, default: nil
  attr :href, :string, default: nil
  attr :cta, :string, default: nil

  defp workspace_summary(assigns) do
    ~H"""
    <div class="border-l border-zinc-950/10 pl-4">
      <dt class="text-xs/5 font-medium text-zinc-500"><%= @label %></dt>
      <dd class="mt-1 flex items-baseline gap-1.5">
        <span class="text-xl/7 font-semibold tracking-tight text-zinc-950"><%= @value %></span>
        <span :if={@unit} class="text-xs/5 text-zinc-500"><%= @unit %></span>
      </dd>
      <dd :if={@description} class="mt-1.5 text-sm/6 text-zinc-600 line-clamp-2">
        <%= @description %>
      </dd>
      <dd :if={@href && @cta} class="mt-2">
        <.link href={@href} class="text-xs/5 font-medium text-zinc-950 hover:text-zinc-700">
          <%= @cta %> →
        </.link>
      </dd>
    </div>
    """
  end

  attr :label, :string, required: true
  attr :value, :any, required: true
  attr :note, :string, default: nil

  defp overview_stat(assigns) do
    ~H"""
    <div class="border-l border-zinc-950/10 pl-4">
      <dt class="text-sm/6 font-medium text-zinc-500"><%= @label %></dt>
      <dd class="mt-1 text-2xl/8 font-semibold tracking-tight text-zinc-950">
        <%= @value %>
      </dd>
      <dd :if={@note} class="mt-1 text-xs/5 text-zinc-500"><%= @note %></dd>
    </div>
    """
  end

  defp dashboard_greeting(user) do
    name =
      user
      |> case do
        %{name: name} when is_binary(name) and name != "" -> name
        %{email: email} when is_binary(email) -> email |> String.split("@") |> List.first()
        _ -> nil
      end
      |> case do
        nil -> nil
        value -> value |> String.split([".", "_"]) |> List.first() |> String.capitalize()
      end

    period =
      case Time.utc_now().hour do
        h when h < 12 -> "morning"
        h when h < 17 -> "afternoon"
        _ -> "evening"
      end

    if name, do: "Good #{period}, #{name}", else: "Good #{period}"
  end

  attr :title, :string, required: true
  attr :metrics, :list, required: true

  defp queue_strip(assigns) do
    ~H"""
    <div>
      <p class="text-xs/5 font-medium text-zinc-500"><%= @title %></p>
      <dl class="mt-1.5 grid grid-cols-4 divide-x divide-zinc-950/5 rounded-lg border border-zinc-950/10">
        <div :for={m <- @metrics} class="flex flex-col items-baseline px-3 py-2">
          <dt class="text-xs/5 text-zinc-500"><%= m.label %></dt>
          <dd class={["text-sm/6 font-semibold", Map.get(m, :emphasis) || "text-zinc-950"]}>
            <%= m.value %>
          </dd>
        </div>
      </dl>
    </div>
    """
  end

  attr :title, :string, required: true
  attr :value, :any, required: true
  attr :value_class, :string, default: "text-zinc-950"

  defp queue_metric(assigns) do
    ~H"""
    <div class="rounded-lg border border-zinc-950/10 bg-zinc-50 p-2">
      <div class="text-zinc-500"><%= @title %></div>
      <div class={"text-sm font-semibold #{@value_class}"}><%= @value %></div>
    </div>
    """
  end

  attr :label, :string, required: true
  attr :value, :string, required: true
  attr :value_class, :string, default: "font-medium text-zinc-950"

  defp health_row(assigns) do
    ~H"""
    <div class="flex items-center justify-between">
      <dt class="text-zinc-500"><%= @label %></dt>
      <dd class={@value_class}><%= @value %></dd>
    </div>
    """
  end

  defp payload_preview(payload) when is_map(payload) do
    payload
    |> Jason.encode!()
    |> truncate(220)
  rescue
    _ -> inspect(payload, limit: 8)
  end

  defp payload_preview(payload), do: payload |> inspect(limit: 8) |> truncate(220)

  defp truncate(value, max) when is_binary(value) do
    if String.length(value) > max do
      String.slice(value, 0, max) <> "..."
    else
      value
    end
  end

  defp short_id(nil), do: "n/a"
  defp short_id(id) when is_binary(id), do: String.slice(id, 0, 8) <> "..."

  defp format_log_timestamp(timestamp) when is_binary(timestamp) do
    case DateTime.from_iso8601(timestamp) do
      {:ok, datetime, _offset} ->
        Calendar.strftime(datetime, "%H:%M:%S")

      _ ->
        timestamp
    end
  end

  defp format_log_timestamp(_), do: "n/a"

  defp log_level_class(level) when level in [:error, :critical, :alert, :emergency],
    do: "text-red-300"

  defp log_level_class(level) when level in [:warning, :notice], do: "text-amber-300"
  defp log_level_class(:info), do: "text-emerald-300"
  defp log_level_class(:debug), do: "text-sky-300"

  defp log_level_class(level) when is_binary(level) do
    case level do
      "error" -> log_level_class(:error)
      "critical" -> log_level_class(:critical)
      "alert" -> log_level_class(:alert)
      "emergency" -> log_level_class(:emergency)
      "warning" -> log_level_class(:warning)
      "notice" -> log_level_class(:notice)
      "info" -> log_level_class(:info)
      "debug" -> log_level_class(:debug)
      _ -> "text-zinc-300"
    end
  end

  defp log_level_class(_), do: "text-zinc-300"

  defp log_level_text_class(level) when level in [:error, :critical, :alert, :emergency],
    do: "text-red-700"

  defp log_level_text_class(level) when level in [:warning, :notice], do: "text-amber-700"
  defp log_level_text_class(:info), do: "text-emerald-700"
  defp log_level_text_class(:debug), do: "text-sky-700"

  defp log_level_text_class(level) when is_binary(level) do
    case level do
      "error" -> log_level_text_class(:error)
      "critical" -> log_level_text_class(:critical)
      "alert" -> log_level_text_class(:alert)
      "emergency" -> log_level_text_class(:emergency)
      "warning" -> log_level_text_class(:warning)
      "notice" -> log_level_text_class(:notice)
      "info" -> log_level_text_class(:info)
      "debug" -> log_level_text_class(:debug)
      _ -> "text-zinc-600"
    end
  end

  defp log_level_text_class(_), do: "text-zinc-600"

  defp log_metadata_preview(metadata) when metadata in [%{}, nil], do: nil

  defp log_metadata_preview(metadata) when is_map(metadata) do
    metadata
    |> Enum.reject(fn {_key, value} -> is_nil(value) or value == "" end)
    |> Enum.sort_by(fn {key, _value} -> key end)
    |> Enum.map_join(" ", fn {key, value} -> "#{key}=#{value}" end)
    |> truncate(120)
  end

  defp log_metadata_preview(_), do: nil

  defp fly_log_metadata_preview(%{app: app, metadata: metadata}) when is_map(metadata) do
    metadata
    |> Map.put_new("app", app)
    |> Enum.reject(fn {_key, value} -> is_nil(value) or value == "" end)
    |> Enum.sort_by(fn {key, _value} -> key end)
    |> Enum.map_join(" ", fn {key, value} -> "#{key}=#{value}" end)
    |> truncate(140)
  end

  defp fly_log_metadata_preview(_), do: nil

  defp format_uptime(seconds) when is_integer(seconds) and seconds >= 0 do
    hours = div(seconds, 3600)
    minutes = div(rem(seconds, 3600), 60)
    secs = rem(seconds, 60)

    cond do
      hours > 0 -> "#{hours}h #{minutes}m #{secs}s"
      minutes > 0 -> "#{minutes}m #{secs}s"
      true -> "#{secs}s"
    end
  end

  defp format_uptime(_), do: "n/a"

  defp format_time(nil), do: "N/A"

  defp format_time(datetime) when is_binary(datetime) do
    case DateTime.from_iso8601(datetime) do
      {:ok, dt, _} -> format_time(dt)
      _ -> datetime
    end
  end

  defp format_time(%DateTime{} = dt), do: Calendar.strftime(dt, "%H:%M:%S")
  defp format_time(%NaiveDateTime{} = dt), do: Calendar.strftime(dt, "%H:%M:%S")

  defp format_datetime(nil), do: "N/A"

  defp format_datetime(datetime) when is_binary(datetime) do
    case DateTime.from_iso8601(datetime) do
      {:ok, dt, _} -> format_datetime(dt)
      _ -> datetime
    end
  end

  defp format_datetime(%DateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S UTC")
  defp format_datetime(%NaiveDateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S")
end
