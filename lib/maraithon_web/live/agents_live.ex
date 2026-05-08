defmodule MaraithonWeb.AgentsLive do
  use MaraithonWeb, :live_view

  alias Maraithon.Admin
  alias Maraithon.AgentArchitecture
  alias Maraithon.AgentBuilder
  alias Maraithon.Agents
  alias Maraithon.BriefingSchedules
  alias Maraithon.ChiefOfStaff.Skills, as: ChiefOfStaffSkills
  alias Maraithon.Connections
  alias Maraithon.Runtime

  @refresh_interval 5_000
  @event_limit 50
  @status_options ~w(all running degraded stopped)

  @impl true
  def mount(_params, _session, socket) do
    socket =
      assign(socket,
        page_title: "Agents",
        current_path: "/agents",
        status_options: @status_options,
        filters: default_filters(),
        all_agents: [],
        agents: [],
        selected_agent_id: nil,
        selected_agent: nil,
        selected_architecture: nil,
        selected_panel: nil,
        events: [],
        inspection: empty_inspection(),
        agent_spend: empty_spend(),
        inspection_errors: [],
        launch: default_launch_params(),
        launch_error: nil,
        route_state: nil
      )

    if connected?(socket) do
      :timer.send_interval(@refresh_interval, self(), :refresh)
    end

    {:ok, socket}
  end

  @impl true
  def handle_params(params, uri, socket) do
    filters = %{
      status: normalize_status(Map.get(params, "status")),
      q: normalize_query(Map.get(params, "q"))
    }

    requested_id = normalize_id(Map.get(params, "id"))
    requested_panel = normalize_panel(Map.get(params, "panel"))
    raw_panel = Map.get(params, "panel")

    socket =
      socket
      |> assign(:current_path, current_path_from_uri(uri))
      |> assign(:filters, filters)
      |> refresh_registry()

    case apply_selection(socket, requested_id, requested_panel, raw_panel) do
      {:ok, socket} ->
        route_state = %{
          id: socket.assigns.selected_agent_id,
          panel: socket.assigns.selected_panel,
          status: filters.status,
          q: filters.q
        }

        {:noreply, maybe_emit_route_telemetry(socket, route_state)}

      {:sanitize, socket, to, flash} ->
        {:noreply, socket |> maybe_put_flash(flash) |> push_patch(to: to)}
    end
  end

  @impl true
  def handle_info(:refresh, socket) do
    socket = refresh_registry(socket)

    socket =
      case refresh_selected_workspace(socket) do
        {:ok, socket} -> socket
        {:sanitize, socket, to, flash} -> socket |> maybe_put_flash(flash) |> push_patch(to: to)
      end

    {:noreply, socket}
  end

  @impl true
  def handle_event("update_filters", %{"filters" => filters}, socket) do
    next_filters = %{
      status: normalize_status(Map.get(filters, "status")),
      q: normalize_query(Map.get(filters, "q"))
    }

    {:noreply, push_patch(socket, to: agents_path_for_socket(socket, next_filters))}
  end

  def handle_event("clear_filters", _params, socket) do
    {:noreply, push_patch(socket, to: agents_path_for_socket(socket, default_filters()))}
  end

  def handle_event("select_agent", %{"id" => id}, socket) do
    if agent_owned_by_current_user?(socket, id) do
      {:noreply,
       push_patch(socket, to: agents_path(socket.assigns.filters, %{id: id, panel: :inspect}))}
    else
      {:noreply, socket |> clear_missing_selection(id) |> put_flash(:error, "Agent not found")}
    end
  end

  def handle_event("start_agent", %{"id" => id} = params, socket) do
    surface = action_surface(Map.get(params, "surface"))

    if agent_owned_by_current_user?(socket, id) do
      case Runtime.start_existing_agent(id) do
        {:ok, _agent} ->
          emit_action_telemetry("start", surface, id, :ok)

          {:noreply,
           socket
           |> refresh_registry()
           |> refresh_selected_workspace_or_clear()
           |> put_flash(:info, "Agent started")}

        {:error, :already_running} ->
          emit_action_telemetry("start", surface, id, :ok)

          {:noreply,
           socket
           |> refresh_registry()
           |> refresh_selected_workspace_or_clear()
           |> put_flash(:info, "Agent is already running")}

        {:error, :not_found} ->
          emit_action_telemetry("start", surface, id, :error)

          {:noreply,
           socket
           |> refresh_registry()
           |> clear_missing_selection(id)
           |> put_flash(:error, "Agent not found")}

        {:error, reason} ->
          emit_action_telemetry("start", surface, id, :error)

          {:noreply,
           socket
           |> refresh_registry()
           |> refresh_selected_workspace_or_clear()
           |> put_flash(:error, "Failed to start agent: #{inspect(reason)}")}
      end
    else
      emit_action_telemetry("start", surface, id, :error)

      {:noreply,
       socket
       |> refresh_registry()
       |> clear_missing_selection(id)
       |> put_flash(:error, "Agent not found")}
    end
  end

  def handle_event("stop_agent", %{"id" => id} = params, socket) do
    surface = action_surface(Map.get(params, "surface"))

    if agent_owned_by_current_user?(socket, id) do
      case Runtime.stop_agent(id, "stopped_from_agents_tab") do
        {:ok, _result} ->
          emit_action_telemetry("stop", surface, id, :ok)

          {:noreply,
           socket
           |> refresh_registry()
           |> refresh_selected_workspace_or_clear()
           |> put_flash(:info, "Agent stopped")}

        {:error, :not_found} ->
          emit_action_telemetry("stop", surface, id, :error)

          {:noreply,
           socket
           |> refresh_registry()
           |> clear_missing_selection(id)
           |> put_flash(:error, "Agent not found")}

        {:error, reason} ->
          emit_action_telemetry("stop", surface, id, :error)

          {:noreply,
           socket
           |> refresh_registry()
           |> refresh_selected_workspace_or_clear()
           |> put_flash(:error, "Failed to stop agent: #{inspect(reason)}")}
      end
    else
      emit_action_telemetry("stop", surface, id, :error)

      {:noreply,
       socket
       |> refresh_registry()
       |> clear_missing_selection(id)
       |> put_flash(:error, "Agent not found")}
    end
  end

  def handle_event("delete_agent", %{"id" => id} = params, socket) do
    surface = action_surface(Map.get(params, "surface"))

    if agent_owned_by_current_user?(socket, id) do
      case Runtime.delete_agent(id) do
        :ok ->
          emit_action_telemetry("delete", surface, id, :ok)

          socket =
            socket
            |> refresh_registry()
            |> assign(launch_error: nil)
            |> put_flash(:info, "Agent deleted")

          {:noreply, clear_missing_selection(socket, id)}

        {:error, :not_found} ->
          emit_action_telemetry("delete", surface, id, :error)

          {:noreply,
           socket
           |> refresh_registry()
           |> clear_missing_selection(id)
           |> put_flash(:error, "Agent not found")}

        {:error, reason} ->
          emit_action_telemetry("delete", surface, id, :error)

          {:noreply,
           socket
           |> refresh_registry()
           |> refresh_selected_workspace_or_clear()
           |> put_flash(:error, "Failed to delete agent: #{inspect(reason)}")}
      end
    else
      emit_action_telemetry("delete", surface, id, :error)

      {:noreply,
       socket
       |> refresh_registry()
       |> clear_missing_selection(id)
       |> put_flash(:error, "Agent not found")}
    end
  end

  def handle_event("save_agent", %{"launch" => params}, socket) do
    launch = normalize_launch_params(params)
    id = socket.assigns.selected_agent_id

    with true <- is_binary(id),
         true <- agent_owned_by_current_user?(socket, id),
         {:ok, start_params} <- build_agent_start_params(launch, current_user_id(socket)),
         {:ok, agent} <- Runtime.update_agent(id, start_params) do
      emit_action_telemetry("update", :workspace, agent.id, :ok)

      {:noreply,
       socket
       |> assign(launch: default_launch_params(), launch_error: nil)
       |> refresh_registry()
       |> refresh_selected_workspace_or_clear()
       |> put_flash(:info, "Agent #{String.slice(agent.id, 0, 8)} updated")
       |> push_patch(to: agents_path(socket.assigns.filters, %{id: agent.id, panel: :inspect}))}
    else
      false ->
        emit_action_telemetry("update", :workspace, id || "unknown", :error)
        {:noreply, socket |> clear_missing_selection(id) |> put_flash(:error, "Agent not found")}

      {:error, message} when is_binary(message) ->
        emit_action_telemetry("update", :workspace, id, :error)
        {:noreply, assign(socket, launch: launch, launch_error: message)}

      {:error, %Ecto.Changeset{} = changeset} ->
        emit_action_telemetry("update", :workspace, id, :error)

        {:noreply,
         assign(
           socket,
           launch: launch,
           launch_error: "Failed to update agent: #{changeset_errors(changeset)}"
         )}

      {:error, reason} ->
        emit_action_telemetry("update", :workspace, id, :error)

        {:noreply,
         assign(socket,
           launch: launch,
           launch_error: "Failed to update agent: #{inspect(reason)}"
         )}
    end
  end

  def handle_event("update_morning_brief_time", %{"schedule" => params}, socket) do
    id = socket.assigns.selected_agent_id

    with true <- is_binary(id),
         true <- agent_owned_by_current_user?(socket, id),
         {:ok, result} <-
           BriefingSchedules.update_schedule(
             current_user_id(socket),
             Map.merge(params, %{"agent_id" => id, "briefing_kind" => "morning"})
           ) do
      {:noreply,
       socket
       |> refresh_registry()
       |> refresh_selected_workspace_or_clear()
       |> put_flash(
         :info,
         "Morning briefing set for #{result.display_time_local} #{result.local_timezone}"
       )}
    else
      false ->
        {:noreply, socket |> clear_missing_selection(id) |> put_flash(:error, "Agent not found")}

      {:error, reason} ->
        {:noreply,
         socket
         |> refresh_registry()
         |> refresh_selected_workspace_or_clear()
         |> put_flash(
           :error,
           "Failed to update morning briefing: #{schedule_error_message(reason)}"
         )}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_path={@current_path} current_user={@current_user}>
      <div class="space-y-6">
        <.panel body_class="px-6 py-6">
          <div class="flex flex-wrap items-start justify-between gap-4">
            <div class="max-w-3xl">
              <p class="text-xs font-semibold uppercase tracking-[0.2em] text-zinc-500">
                Agents Workspace
              </p>
              <.heading class="mt-2 text-3xl sm:text-4xl">
                Your agents
              </.heading>
              <.text class="mt-3 max-w-2xl sm:text-base">
                Choose an assistant, review what it does, and adjust the settings that affect your day.
              </.text>
            </div>

            <div class="flex flex-wrap items-center gap-3">
              <.badge color="zinc" class="px-3 py-1 text-sm">
                <%= length(@all_agents) %> total
              </.badge>
              <.button href={~p"/agents/new"} class="min-h-11 px-5">
                New Agent
              </.button>
            </div>
          </div>
        </.panel>

        <.panel body_class="p-0">
          <:header>
            <div class="flex flex-wrap items-start justify-between gap-4">
              <div>
                <.heading level={2} class="text-lg/7">Choose an agent</.heading>
                <.text class="mt-1">
                  Open an agent to see its overview, connected apps, skills, and delivery settings.
                </.text>
              </div>
              <form id="agent-filters" phx-change="update_filters" class="flex flex-wrap items-center gap-3">
                <label class="sr-only" for="agent-search">Search agents</label>
                <input
                  id="agent-search"
                  type="search"
                  name="filters[q]"
                  value={@filters.q}
                  placeholder="Search agents"
                  class="min-h-11 w-72 rounded-lg border border-zinc-950/10 bg-white px-3 text-sm/6 text-zinc-950 shadow-sm placeholder:text-zinc-400 focus:border-blue-500 focus:outline-none focus:ring-2 focus:ring-blue-500/20"
                />
                <label class="sr-only" for="agent-status">Filter by status</label>
                <select
                  id="agent-status"
                  name="filters[status]"
                  class="min-h-11 rounded-lg border border-zinc-950/10 bg-white px-3 text-sm/6 text-zinc-950 shadow-sm focus:border-blue-500 focus:outline-none focus:ring-2 focus:ring-blue-500/20"
                >
                  <option
                    :for={status <- @status_options}
                    value={status}
                    selected={status == @filters.status}
                  >
                    <%= humanize_status(status) %>
                  </option>
                </select>
                <button
                  :if={@filters.status != "all" or @filters.q != ""}
                  type="button"
                  phx-click="clear_filters"
                  class="group relative isolate inline-flex min-h-11 items-center justify-center rounded-lg border border-zinc-950/10 bg-white px-4 text-sm/6 font-semibold text-zinc-950 shadow-sm hover:bg-zinc-950/[0.025] focus:outline-none focus:ring-2 focus:ring-blue-500 focus:ring-offset-2"
                >
                  Reset
                </button>
              </form>
            </div>
          </:header>

          <.table>
              <.table_head>
                <.table_row>
                  <.table_header>Agent</.table_header>
                  <.table_header>Status</.table_header>
                  <.table_header>Last updated</.table_header>
                  <.table_header class="text-right">Actions</.table_header>
                </.table_row>
              </.table_head>
              <.table_body>
                <%= for agent <- @agents do %>
                  <.table_row
                    class={row_class(@selected_agent_id, agent.id)}
                    phx-click="select_agent"
                    phx-value-id={agent.id}
                    phx-keydown="select_agent"
                    phx-key="Enter"
                    role="link"
                    tabindex="0"
                    title={"Open #{agent_display_name(agent)}"}
                  >
                    <.table_cell class="align-top">
                      <.link
                        patch={agents_path(@filters, %{id: agent.id, panel: :inspect})}
                        class="text-base font-semibold text-zinc-950 hover:text-blue-700"
                      >
                        <%= agent_display_name(agent) %>
                      </.link>
                      <div class="mt-1 text-xs text-zinc-500"><%= agent_kind_label(agent) %></div>
                      <p class="mt-2 max-w-2xl text-sm leading-6 text-zinc-600">
                        <%= agent_row_summary(agent) %>
                      </p>
                      <%= if agent.project do %>
                        <div class="mt-1 text-xs font-medium text-emerald-700">
                          Project: <%= agent.project.name %>
                        </div>
                      <% end %>
                      <div class="mt-3 flex flex-wrap items-center gap-2">
                        <%= for connector <- agent_connector_logo_items(agent) do %>
                          <span
                            title={connector.label}
                            class="inline-flex h-8 w-8 items-center justify-center rounded-lg border border-zinc-950/10 bg-white shadow-sm"
                          >
                            <img
                              src={connector_logo_src(connector.provider)}
                              alt={connector.label}
                              class="h-5 w-5 object-contain"
                            />
                          </span>
                        <% end %>
                      </div>
                    </.table_cell>
                    <.table_cell class="align-top">
                      <.status_badge status={agent.status} />
                    </.table_cell>
                    <.table_cell class="align-top text-xs text-zinc-500">
                      <%= format_datetime(agent.updated_at) %>
                    </.table_cell>
                    <.table_cell class="align-top">
                      <div class="flex flex-wrap justify-end gap-2">
                        <.button patch={agents_path(@filters, %{id: agent.id, panel: :inspect})} class="min-h-8 px-3 text-xs">
                          Open
                        </.button>
                      </div>
                    </.table_cell>
                  </.table_row>
                <% end %>

                <%= if @all_agents == [] do %>
                  <.table_row>
                    <.table_cell colspan="4" class="py-12">
                      <div class="rounded-xl border border-dashed border-zinc-950/10 bg-zinc-50 px-6 py-8 text-center">
                        <p class="text-base font-semibold text-zinc-950">No agents exist yet.</p>
                        <p class="mt-2 text-sm text-zinc-600">
                          Start with the builder, then come back here to inspect, edit, or control the runtime.
                        </p>
                        <.button href={~p"/agents/new"} class="mt-4">
                          Create your first agent
                        </.button>
                      </div>
                    </.table_cell>
                  </.table_row>
                <% end %>

                <%= if @all_agents != [] and @agents == [] do %>
                  <.table_row>
                    <.table_cell colspan="4" class="py-12">
                      <div class="rounded-xl border border-dashed border-zinc-950/10 bg-zinc-50 px-6 py-8 text-center">
                        <p class="text-base font-semibold text-zinc-950">No agents match the current filters.</p>
                        <p class="mt-2 text-sm text-zinc-600">
                          Clear the current search or status filter to see the full registry again.
                        </p>
                        <.button
                          type="button"
                          phx-click="clear_filters"
                          variant="outline"
                          class="mt-4"
                        >
                          Reset filters
                        </.button>
                      </div>
                    </.table_cell>
                  </.table_row>
                <% end %>
              </.table_body>
            </.table>
        </.panel>

        <section class="overflow-hidden rounded-2xl border border-slate-200 bg-white shadow-sm">
          <div class="border-b border-slate-200 px-5 py-5">
            <div class="flex flex-wrap items-start justify-between gap-4">
              <div>
                <h2 class="text-lg font-semibold text-slate-950">Agent details</h2>
                <p class="mt-1 text-sm text-slate-500">Review this agent and adjust its day-to-day behavior.</p>
              </div>

              <%= if @selected_agent do %>
                <div class="flex flex-wrap items-center gap-2">
                  <.link
                    patch={agents_path(@filters, %{id: @selected_agent.id, panel: :inspect})}
                    class={workspace_tab_class(@selected_panel == :inspect)}
                  >
                    Overview
                  </.link>
                  <.link
                    patch={agents_path(@filters, %{id: @selected_agent.id, panel: :edit})}
                    class={workspace_tab_class(@selected_panel == :edit)}
                  >
                    Settings
                  </.link>
                </div>
              <% end %>
            </div>
          </div>

          <%= if @inspection_errors != [] do %>
            <div class="border-b border-amber-200 bg-amber-50 px-5 py-4">
              <%= for error <- @inspection_errors do %>
                <div class="text-sm text-amber-900">
                  <p class="font-medium"><%= error.message %></p>
                  <p class="mt-1 text-xs text-amber-800"><%= error.details %></p>
                </div>
              <% end %>
            </div>
          <% end %>

          <%= if @selected_agent do %>
            <div class="space-y-6 px-5 py-5">
              <div class="flex flex-wrap items-start justify-between gap-4">
                <div>
                  <div class="flex flex-wrap items-center gap-3">
                    <h3 class="text-2xl font-semibold text-slate-900"><%= agent_name(@selected_agent.config) %></h3>
                    <.status_badge status={@selected_agent.status} />
                  </div>
                  <p class="mt-1 text-sm text-slate-500"><%= agent_kind_label(@selected_agent) %></p>
                </div>

                <div class="flex flex-wrap gap-2">
                  <%= if @selected_panel == :inspect do %>
                    <.link
                      patch={agents_path(@filters, %{id: @selected_agent.id, panel: :edit})}
                      class="inline-flex min-h-10 items-center rounded-full border border-slate-300 px-4 text-xs font-medium text-slate-700 hover:bg-slate-50"
                    >
                      Edit Settings
                    </.link>
                  <% else %>
                    <.link
                      patch={agents_path(@filters, %{id: @selected_agent.id, panel: :inspect})}
                      class="inline-flex min-h-10 items-center rounded-full border border-slate-300 px-4 text-xs font-medium text-slate-700 hover:bg-slate-50"
                    >
                      Back to Overview
                    </.link>
                  <% end %>

                  <%= if @selected_agent.status in ["running", "degraded"] do %>
                    <button
                      type="button"
                      phx-click="stop_agent"
                      phx-value-id={@selected_agent.id}
                      phx-value-surface="workspace"
                      phx-disable-with="Stopping..."
                      class="inline-flex min-h-10 items-center rounded-full border border-amber-200 bg-amber-50 px-4 text-xs font-medium text-amber-800 hover:bg-amber-100"
                    >
                      Stop Agent
                    </button>
                  <% else %>
                    <button
                      type="button"
                      phx-click="start_agent"
                      phx-value-id={@selected_agent.id}
                      phx-value-surface="workspace"
                      phx-disable-with="Starting..."
                      class="inline-flex min-h-10 items-center rounded-full border border-emerald-200 bg-emerald-50 px-4 text-xs font-medium text-emerald-800 hover:bg-emerald-100"
                    >
                      Start Agent
                    </button>
                  <% end %>

                  <button
                    type="button"
                    phx-click="delete_agent"
                    phx-value-id={@selected_agent.id}
                    phx-value-surface="workspace"
                    phx-disable-with="Deleting..."
                    data-confirm="Delete this agent and all dependent records?"
                    class="inline-flex min-h-10 items-center rounded-full border border-rose-200 bg-rose-50 px-4 text-xs font-medium text-rose-700 hover:bg-rose-100"
                  >
                    Delete Agent
                  </button>
                </div>
              </div>

              <%= if @selected_panel == :edit do %>
                <div class="rounded-2xl border border-slate-200 bg-slate-50 p-5">
                  <div class="mb-4">
                    <h3 class="text-lg font-semibold text-slate-900">Edit Agent</h3>
                    <p class="mt-1 text-sm text-slate-600">
                      Save a new definition for this agent. Running agents restart with the updated config.
                    </p>
                  </div>

                  <%= if @launch_error do %>
                    <div class="mb-4 rounded-xl border border-rose-200 bg-rose-50 px-4 py-3 text-sm text-rose-800">
                      <%= @launch_error %>
                    </div>
                  <% end %>

                  <form id="agent-edit-form" phx-submit="save_agent" class="space-y-4">
                    <input
                      type="hidden"
                      name="launch[builder_mode]"
                      value={Map.get(@launch, "builder_mode", "advanced")}
                    />

                    <div class="grid grid-cols-1 gap-4 md:grid-cols-2">
                      <div>
                        <label for="launch_behavior" class="block text-sm font-medium text-slate-700">
                          Behavior
                        </label>
                        <select
                          id="launch_behavior"
                          name="launch[behavior]"
                          class="mt-1 block w-full rounded-xl border border-slate-300 px-3 py-2 text-sm text-slate-900 shadow-sm"
                        >
                          <%= for behavior <- behaviors() do %>
                            <option value={behavior} selected={behavior == @launch["behavior"]}>
                              <%= behavior %>
                            </option>
                          <% end %>
                        </select>
                      </div>

                      <div>
                        <label for="launch_name" class="block text-sm font-medium text-slate-700">
                          Name
                        </label>
                        <input
                          id="launch_name"
                          type="text"
                          name="launch[name]"
                          value={@launch["name"]}
                          placeholder="optional display name"
                          class="mt-1 block w-full rounded-xl border border-slate-300 px-3 py-2 text-sm text-slate-900 shadow-sm"
                        />
                      </div>
                    </div>

                    <div>
                      <label for="launch_prompt" class="block text-sm font-medium text-slate-700">
                        Prompt
                      </label>
                      <textarea
                        id="launch_prompt"
                        name="launch[prompt]"
                        rows="4"
                        class="mt-1 block w-full rounded-xl border border-slate-300 px-3 py-2 text-sm text-slate-900 shadow-sm"
                      ><%= @launch["prompt"] %></textarea>
                    </div>

                    <div class="grid grid-cols-1 gap-4 md:grid-cols-2">
                      <div>
                        <label for="launch_subscriptions" class="block text-sm font-medium text-slate-700">
                          Subscriptions
                        </label>
                        <input
                          id="launch_subscriptions"
                          type="text"
                          name="launch[subscriptions]"
                          value={@launch["subscriptions"]}
                          placeholder="github:owner/repo,email:kent"
                          class="mt-1 block w-full rounded-xl border border-slate-300 px-3 py-2 text-sm text-slate-900 shadow-sm"
                        />
                      </div>

                      <div>
                        <label for="launch_tools" class="block text-sm font-medium text-slate-700">
                          Tools
                        </label>
                        <input
                          id="launch_tools"
                          type="text"
                          name="launch[tools]"
                          value={@launch["tools"]}
                          placeholder="read_file,search_files,http_get"
                          class="mt-1 block w-full rounded-xl border border-slate-300 px-3 py-2 text-sm text-slate-900 shadow-sm"
                        />
                      </div>
                    </div>

                    <div class="grid grid-cols-1 gap-4 md:grid-cols-3">
                      <div>
                        <label for="launch_memory_limit" class="block text-sm font-medium text-slate-700">
                          Memory Limit
                        </label>
                        <input
                          id="launch_memory_limit"
                          type="number"
                          min="1"
                          name="launch[memory_limit]"
                          value={@launch["memory_limit"]}
                          class="mt-1 block w-full rounded-xl border border-slate-300 px-3 py-2 text-sm text-slate-900 shadow-sm"
                        />
                      </div>

                      <div>
                        <label for="launch_budget_llm_calls" class="block text-sm font-medium text-slate-700">
                          LLM Call Budget
                        </label>
                        <input
                          id="launch_budget_llm_calls"
                          type="number"
                          min="1"
                          name="launch[budget_llm_calls]"
                          value={@launch["budget_llm_calls"]}
                          class="mt-1 block w-full rounded-xl border border-slate-300 px-3 py-2 text-sm text-slate-900 shadow-sm"
                        />
                      </div>

                      <div>
                        <label for="launch_budget_tool_calls" class="block text-sm font-medium text-slate-700">
                          Tool Call Budget
                        </label>
                        <input
                          id="launch_budget_tool_calls"
                          type="number"
                          min="1"
                          name="launch[budget_tool_calls]"
                          value={@launch["budget_tool_calls"]}
                          class="mt-1 block w-full rounded-xl border border-slate-300 px-3 py-2 text-sm text-slate-900 shadow-sm"
                        />
                      </div>
                    </div>

                    <div>
                      <label for="launch_config_json" class="block text-sm font-medium text-slate-700">
                        Additional Config JSON
                      </label>
                      <textarea
                        id="launch_config_json"
                        name="launch[config_json]"
                        rows="5"
                        class="mt-1 block w-full rounded-xl border border-slate-300 px-3 py-2 font-mono text-sm text-slate-900 shadow-sm"
                        placeholder={"{\"custom_key\":\"value\"}"}
                      ><%= @launch["config_json"] %></textarea>
                    </div>

                    <div class="flex justify-end">
                      <button
                        type="submit"
                        phx-disable-with="Saving..."
                        class="inline-flex items-center rounded-full bg-slate-900 px-4 py-2 text-sm font-medium text-white hover:bg-slate-800"
                      >
                        Save Changes
                      </button>
                    </div>
                  </form>
                </div>
              <% else %>
                <div class={inspect_layout_class(@selected_agent)}>
                  <div class="space-y-6">
                    <%= if chief_of_staff_agent?(@selected_agent) do %>
                      <% schedule = morning_brief_schedule(@selected_agent) %>
                      <% skills = chief_skill_rows(@selected_agent) %>

                      <section class="overflow-hidden rounded-2xl border border-slate-200 bg-white shadow-sm">
                        <div class="px-5 py-5">
                          <div class="flex flex-wrap items-start justify-between gap-4">
                            <div>
                              <h3 class="text-xl font-semibold tracking-tight text-slate-950">Overview</h3>
                              <p class="mt-2 max-w-2xl text-sm leading-6 text-slate-600">
                                A daily operating assistant for commitments, schedule changes, travel, projects, and personal reminders.
                              </p>
                            </div>
                            <div class="rounded-full bg-emerald-50 px-3 py-1 text-xs font-semibold text-emerald-700">
                              Active skills: <%= length(skills) %>
                            </div>
                          </div>
                        </div>
                        <div class="grid grid-cols-1 border-t border-slate-200 text-sm sm:grid-cols-3">
                          <div class="border-b border-slate-200 px-5 py-4 sm:border-b-0 sm:border-r">
                            <div class="text-xs font-semibold uppercase tracking-[0.14em] text-slate-400">
                              Morning briefing
                            </div>
                            <div class="mt-2 text-2xl font-semibold text-slate-950">
                              <%= schedule.display_time_local %>
                            </div>
                            <div class="mt-1 text-xs text-slate-500"><%= schedule.local_timezone %></div>
                          </div>
                          <div class="border-b border-slate-200 px-5 py-4 sm:border-b-0 sm:border-r">
                            <div class="text-xs font-semibold uppercase tracking-[0.14em] text-slate-400">
                              Delivered by
                            </div>
                            <div class="mt-2 text-2xl font-semibold text-slate-950">Telegram</div>
                            <div class="mt-1 text-xs text-slate-500">sent from the Maraithon server</div>
                          </div>
                          <div class="px-5 py-4">
                            <div class="text-xs font-semibold uppercase tracking-[0.14em] text-slate-400">
                              Sources
                            </div>
                            <div class="mt-2 flex flex-wrap gap-2">
                              <%= for source <- chief_source_labels() do %>
                                <span class="rounded-full bg-slate-100 px-2.5 py-1 text-xs font-medium text-slate-700">
                                  <%= source %>
                                </span>
                              <% end %>
                            </div>
                          </div>
                        </div>
                      </section>

                      <.panel body_class="p-0">
                        <:header>
                          <.heading level={3}>Connected apps</.heading>
                          <.text class="mt-1">Actual accounts this agent can read from or deliver to.</.text>
                        </:header>
                        <% connected_rows = connected_app_account_rows(@current_user.id, @selected_agent) %>
                        <.table>
                            <.table_head>
                              <.table_row>
                                <.table_header>App</.table_header>
                                <.table_header>Account</.table_header>
                                <.table_header>Access</.table_header>
                                <.table_header>Status</.table_header>
                                <.table_header>Updated</.table_header>
                              </.table_row>
                            </.table_head>
                            <.table_body>
                              <%= for row <- connected_rows do %>
                                <.table_row>
                                  <.table_cell class="align-top">
                                    <div class="flex items-center gap-2 font-semibold text-zinc-950">
                                      <img
                                        src={connector_logo_src(row.logo_provider)}
                                        alt={row.app}
                                        class="h-5 w-5 object-contain"
                                      />
                                      <%= row.app %>
                                    </div>
                                  </.table_cell>
                                  <.table_cell class="align-top">
                                    <div class="font-medium text-zinc-950"><%= row.account %></div>
                                    <div :if={row.note} class="mt-1 text-xs text-zinc-500">
                                      <%= row.note %>
                                    </div>
                                  </.table_cell>
                                  <.table_cell class="max-w-xl align-top text-zinc-600">
                                    <%= row.access %>
                                  </.table_cell>
                                  <.table_cell class="align-top">
                                    <.badge color={account_status_color(row.status)}>
                                      <%= account_status_label(row.status) %>
                                    </.badge>
                                  </.table_cell>
                                  <.table_cell class="align-top text-xs text-zinc-500">
                                    <%= format_datetime(row.updated_at) %>
                                  </.table_cell>
                                </.table_row>
                              <% end %>

                              <%= if connected_rows == [] do %>
                                <.table_row>
                                  <.table_cell colspan="5" class="py-8 text-sm text-zinc-500">
                                    No connected accounts found for this agent yet.
                                  </.table_cell>
                                </.table_row>
                              <% end %>
                            </.table_body>
                          </.table>
                      </.panel>

                      <section class="overflow-hidden rounded-2xl border border-slate-200 bg-white shadow-sm">
                        <div class="border-b border-slate-200 px-5 py-5">
                          <h3 class="text-xl font-semibold tracking-tight text-slate-950">Attached Skills</h3>
                          <p class="mt-1 text-sm text-slate-500">Each skill owns one clear job. Adjust the settings where the work happens.</p>
                        </div>
                        <div class="divide-y divide-slate-200">
                          <%= for skill <- skills do %>
                            <div id={"chief-skill-#{skill.id}"} class="px-5 py-5">
                              <div class="flex flex-wrap items-start justify-between gap-4">
                                <div class="min-w-0">
                                  <div class="flex flex-wrap items-center gap-2">
                                    <h4 class="text-base font-semibold text-slate-950"><%= skill.label %></h4>
                                    <span class="rounded-full bg-slate-100 px-2 py-0.5 text-xs font-medium text-slate-600">
                                      On
                                    </span>
                                  </div>
                                  <p class="mt-2 max-w-2xl text-sm leading-6 text-slate-600"><%= skill.description %></p>
                                </div>

                                <%= if skill.id == "morning_briefing" do %>
                                  <form
                                    id="morning-brief-time-form"
                                    phx-submit="update_morning_brief_time"
                                    class="flex w-full flex-wrap items-end gap-3 rounded-2xl bg-slate-50 px-4 py-4 sm:w-auto"
                                  >
                                    <div>
                                      <label
                                        for="morning-brief-hour"
                                        class="block text-xs font-semibold uppercase tracking-[0.14em] text-slate-500"
                                      >
                                        Send each morning at
                                      </label>
                                      <select
                                        id="morning-brief-hour"
                                        name="schedule[local_hour]"
                                        class="mt-1 min-h-11 min-w-44 rounded-xl border border-slate-300 bg-white px-3 text-sm font-medium text-slate-950 shadow-sm focus:border-cyan-500 focus:outline-none focus:ring-2 focus:ring-cyan-200"
                                      >
                                        <option
                                          :for={option <- morning_brief_hour_options()}
                                          value={option.value}
                                          selected={option.value == schedule.hour}
                                        >
                                          <%= option.label %>
                                        </option>
                                      </select>
                                    </div>
                                    <button
                                      type="submit"
                                      phx-disable-with="Saving..."
                                      class="inline-flex min-h-11 items-center rounded-xl bg-slate-950 px-5 text-sm font-semibold text-white hover:bg-slate-800"
                                    >
                                      Update time
                                    </button>
                                    <div class="w-full text-xs text-slate-500">
                                      Uses <%= schedule.local_timezone %>. Sent by Telegram with Gmail, Calendar, Slack, and news context.
                                    </div>
                                  </form>
                                <% end %>
                              </div>
                            </div>
                          <% end %>
                        </div>
                      </section>
                    <% end %>

                    <%= unless chief_of_staff_agent?(@selected_agent) do %>
                    <div class="grid grid-cols-1 gap-4 sm:grid-cols-2 lg:grid-cols-3">
                      <.summary_card title="Started" value={format_datetime(@selected_agent.started_at)} />
                      <.summary_card title="Stopped" value={format_datetime(@selected_agent.stopped_at)} />
                      <.summary_card title="Subscriptions" value={subscriptions_preview(@selected_agent.config)} />
                      <.summary_card title="Tools" value={tools_preview(@selected_agent.config)} />
                      <.summary_card title="Event Count" value={to_string(@inspection.event_count)} />
                      <.summary_card title="Agent Spend" value={"$#{Float.round(@agent_spend.total_cost, 4)}"} value_class="text-amber-700" />
                    </div>

                    <%= if @selected_architecture do %>
                      <.architecture_card architecture={@selected_architecture} mode="full" />
                    <% end %>

                    <div class="grid grid-cols-1 gap-4 lg:grid-cols-2">
                      <div class="rounded-2xl bg-amber-50 p-4">
                        <div class="text-xs font-semibold uppercase tracking-[0.18em] text-amber-700">
                          Spend Summary
                        </div>
                        <dl class="mt-3 space-y-2 text-sm">
                          <div class="flex items-center justify-between gap-3">
                            <dt class="text-amber-700/80">LLM Calls</dt>
                            <dd class="font-medium text-amber-950"><%= @agent_spend.llm_calls %></dd>
                          </div>
                          <div class="flex items-center justify-between gap-3">
                            <dt class="text-amber-700/80">Input Tokens</dt>
                            <dd class="font-medium text-amber-950"><%= @agent_spend.input_tokens %></dd>
                          </div>
                          <div class="flex items-center justify-between gap-3">
                            <dt class="text-amber-700/80">Output Tokens</dt>
                            <dd class="font-medium text-amber-950"><%= @agent_spend.output_tokens %></dd>
                          </div>
                          <div class="flex items-center justify-between gap-3 border-t border-amber-200 pt-2">
                            <dt class="text-amber-700/80">Total Cost</dt>
                            <dd class="font-semibold text-amber-950">
                              $<%= Float.round(@agent_spend.total_cost, 4) %>
                            </dd>
                          </div>
                        </dl>
                      </div>

                      <div class="rounded-2xl bg-slate-50 p-4">
                        <div class="text-xs font-semibold uppercase tracking-[0.18em] text-slate-500">
                          Config Snapshot
                        </div>
                        <pre class="mt-3 overflow-x-auto whitespace-pre-wrap break-all text-[11px] text-slate-700"><%= pretty_config(@selected_agent.config) %></pre>
                      </div>
                    </div>

                    <div class="rounded-2xl bg-slate-50 p-4">
                      <div class="text-xs font-semibold uppercase tracking-[0.18em] text-slate-500">Prompt</div>
                      <p class="mt-3 whitespace-pre-wrap text-sm text-slate-800"><%= agent_prompt(@selected_agent.config) %></p>
                    </div>

                    <section class="overflow-hidden rounded-2xl border border-slate-200 bg-white">
                      <div class="border-b border-slate-200 px-4 py-4">
                        <h3 class="text-lg font-semibold text-slate-900">Effect Queue</h3>
                        <p class="mt-1 text-sm text-slate-500">
                          Inspect pending and historical effects for this agent.
                        </p>
                      </div>
                      <div class="space-y-3 px-4 py-5">
                        <div class="grid grid-cols-3 gap-2 text-xs">
                          <.queue_metric title="Pending" value={@inspection.effect_counts.pending} />
                          <.queue_metric title="Claimed" value={@inspection.effect_counts.claimed} />
                          <.queue_metric
                            title="Failed"
                            value={@inspection.effect_counts.failed}
                            value_class="text-rose-600"
                          />
                        </div>

                        <div class="max-h-80 space-y-2 overflow-y-auto">
                          <%= for effect <- @inspection.recent_effects do %>
                            <div class="rounded-xl border border-slate-200 p-3">
                              <div class="flex items-center justify-between gap-3">
                                <div class="text-sm font-medium text-slate-900"><%= effect.effect_type %></div>
                                <span class={effect_status_class(effect.status)}><%= effect.status %></span>
                              </div>
                              <div class="mt-1 text-xs text-slate-500">
                                attempts <%= effect.attempts %>
                                <span class="mx-1">•</span>
                                updated <%= format_time(effect.updated_at) %>
                              </div>
                              <div class="mt-2 rounded bg-slate-50 px-2 py-1 font-mono text-[11px] text-slate-600">
                                <%= effect_preview(effect) %>
                              </div>
                            </div>
                          <% end %>

                          <%= if @inspection.recent_effects == [] do %>
                            <p class="text-sm text-slate-500">No effects recorded yet.</p>
                          <% end %>
                        </div>
                      </div>
                    </section>

                    <section class="overflow-hidden rounded-2xl border border-slate-200 bg-white">
                      <div class="border-b border-slate-200 px-4 py-4">
                        <h3 class="text-lg font-semibold text-slate-900">Scheduled Jobs</h3>
                        <p class="mt-1 text-sm text-slate-500">
                          Wakeups, heartbeats, and checkpoints queued for this agent.
                        </p>
                      </div>
                      <div class="space-y-3 px-4 py-5">
                        <div class="grid grid-cols-2 gap-2 text-xs">
                          <.queue_metric title="Pending" value={@inspection.job_counts.pending} />
                          <.queue_metric
                            title="Dispatched"
                            value={@inspection.job_counts.dispatched}
                            value_class="text-amber-600"
                          />
                          <.queue_metric title="Delivered" value={@inspection.job_counts.delivered} />
                          <.queue_metric title="Cancelled" value={@inspection.job_counts.cancelled} />
                        </div>

                        <div class="max-h-80 space-y-2 overflow-y-auto">
                          <%= for job <- @inspection.recent_jobs do %>
                            <div class="rounded-xl border border-slate-200 p-3">
                              <div class="flex items-center justify-between gap-3">
                                <div class="text-sm font-medium text-slate-900"><%= job.job_type %></div>
                                <span class={job_status_class(job.status)}><%= job.status %></span>
                              </div>
                              <div class="mt-1 text-xs text-slate-500">
                                fire at <%= format_datetime(job.fire_at) %>
                                <span class="mx-1">•</span>
                                attempts <%= job.attempts %>
                              </div>
                              <div class="mt-2 rounded bg-slate-50 px-2 py-1 font-mono text-[11px] text-slate-600">
                                <%= payload_preview(job.payload) %>
                              </div>
                            </div>
                          <% end %>

                          <%= if @inspection.recent_jobs == [] do %>
                            <p class="text-sm text-slate-500">No scheduled jobs recorded yet.</p>
                          <% end %>
                        </div>
                      </div>
                    </section>
                    <% end %>
                  </div>

                  <div :if={!chief_of_staff_agent?(@selected_agent)} class="space-y-6">
                    <section class="overflow-hidden rounded-2xl border border-slate-200 bg-white">
                      <div class="border-b border-slate-200 px-4 py-4">
                        <h3 class="text-lg font-semibold text-slate-900">Recent Events</h3>
                      </div>
                      <div class="max-h-96 space-y-2 overflow-y-auto px-4 py-4">
                        <%= for event <- Enum.reverse(@events) do %>
                          <div class="rounded-xl border border-slate-200 p-3 text-sm">
                            <div class="flex items-center justify-between gap-3">
                              <span class="font-medium text-cyan-700"><%= event.event_type %></span>
                              <span class="text-xs text-slate-400">#<%= event.sequence_num %></span>
                            </div>
                            <div class="mt-1 text-xs text-slate-500"><%= format_datetime(event.created_at) %></div>
                            <div class="mt-2 rounded bg-slate-50 px-2 py-1 font-mono text-[11px] text-slate-600">
                              <%= payload_preview(event.payload) %>
                            </div>
                          </div>
                        <% end %>

                        <%= if @events == [] do %>
                          <p class="text-sm text-slate-500">No events yet.</p>
                        <% end %>
                      </div>
                    </section>

                    <section class="overflow-hidden rounded-2xl bg-slate-950 shadow">
                      <div class="border-b border-slate-800 px-4 py-4">
                        <h3 class="text-lg font-semibold text-slate-100">Agent Logs</h3>
                        <p class="mt-1 text-sm text-slate-400">
                          Raw log lines scoped to this agent's runtime metadata.
                        </p>
                      </div>
                      <div class="max-h-[32rem] overflow-y-auto px-4 py-4 font-mono text-[11px] leading-5">
                        <%= for log <- @inspection.recent_logs do %>
                          <div class="grid grid-cols-[auto_auto_1fr] gap-3 border-b border-slate-900 py-2">
                            <span class="text-slate-500"><%= format_log_timestamp(log.timestamp) %></span>
                            <span class={["font-semibold uppercase tracking-wide", log_level_class(log.level)]}>
                              <%= log.level %>
                            </span>
                            <div class="min-w-0">
                              <%= if metadata = log_metadata_preview(log.metadata) do %>
                                <span class="mr-2 text-slate-500"><%= metadata %></span>
                              <% end %>
                              <span class="break-words whitespace-pre-wrap text-slate-100"><%= log.message %></span>
                            </div>
                          </div>
                        <% end %>

                        <%= if @inspection.recent_logs == [] do %>
                          <p class="text-sm text-slate-500">No agent-scoped logs captured yet.</p>
                        <% end %>
                      </div>
                    </section>
                  </div>

                  <details
                    :if={chief_of_staff_agent?(@selected_agent)}
                    class="rounded-2xl border border-slate-200 bg-white px-5 py-4 shadow-sm"
                  >
                    <summary class="cursor-pointer list-none">
                      <div class="flex flex-wrap items-center justify-between gap-3">
                        <div>
                          <h3 class="text-base font-semibold text-slate-950">Advanced diagnostics</h3>
                          <p class="mt-1 text-sm text-slate-500">Runtime details for debugging, billing, and support.</p>
                        </div>
                        <span class="text-sm font-medium text-slate-500">Show</span>
                      </div>
                    </summary>

                    <div class="mt-5 grid grid-cols-1 gap-4 sm:grid-cols-2 lg:grid-cols-4">
                      <.summary_card title="Started" value={format_datetime(@selected_agent.started_at)} />
                      <.summary_card title="Last Updated" value={format_datetime(agent_updated_at(@selected_agent))} />
                      <.summary_card title="Events" value={to_string(@inspection.event_count)} />
                      <.summary_card
                        title="Spend"
                        value={"$#{Float.round(@agent_spend.total_cost, 4)}"}
                        value_class="text-amber-700"
                      />
                    </div>

                    <div class="mt-4 rounded-2xl bg-slate-50 p-4">
                      <div class="text-xs font-semibold uppercase tracking-[0.14em] text-slate-500">
                        Agent id
                      </div>
                      <p class="mt-2 break-all font-mono text-xs text-slate-600"><%= @selected_agent.id %></p>
                    </div>
                  </details>
                </div>
              <% end %>
            </div>
          <% else %>
            <div class="px-5 py-12">
              <div class="rounded-2xl border border-dashed border-slate-300 bg-slate-50 px-6 py-10 text-center">
                <p class="text-base font-semibold text-slate-900">No agent selected.</p>
                <p class="mt-2 text-sm text-slate-600">
                  Pick an agent from the registry above to inspect runtime state or edit the saved definition.
                </p>
              </div>
            </div>
          <% end %>
        </section>
      </div>
    </Layouts.app>
    """
  end

  attr :title, :string, required: true
  attr :value, :string, required: true
  attr :value_class, :string, default: "text-slate-900"

  defp summary_card(assigns) do
    ~H"""
    <div class="rounded-2xl border border-slate-200 bg-slate-50 p-4">
      <dt class="text-xs font-semibold uppercase tracking-[0.18em] text-slate-500"><%= @title %></dt>
      <dd class={"mt-2 text-sm font-medium #{@value_class}"}><%= @value %></dd>
    </div>
    """
  end

  attr :title, :string, required: true
  attr :value, :any, required: true
  attr :value_class, :string, default: "text-slate-900"

  defp queue_metric(assigns) do
    ~H"""
    <div class="rounded-xl bg-slate-50 p-2">
      <div class="text-slate-500"><%= @title %></div>
      <div class={"text-sm font-semibold #{@value_class}"}><%= @value %></div>
    </div>
    """
  end

  defp apply_selection(socket, nil, _panel, raw_panel) when is_binary(raw_panel) do
    {:sanitize, clear_selection(socket), filters_path(socket), nil}
  end

  defp apply_selection(socket, nil, _panel, _raw_panel) do
    {:ok, clear_selection(socket)}
  end

  defp apply_selection(socket, id, panel, _raw_panel) do
    case Agents.get_agent_for_user(id, current_user_id(socket)) do
      nil ->
        {:sanitize, clear_selection(socket), filters_path(socket), {:error, "Agent not found"}}

      agent ->
        panel = panel || :inspect
        load_selected_snapshot(socket, agent, panel)
    end
  end

  defp load_selected_snapshot(socket, agent, panel) do
    case Admin.safe_agent_snapshot(
           agent.id,
           user_id: current_user_id(socket),
           event_limit: @event_limit,
           log_limit: 80
         ) do
      {:ok, snapshot} ->
        {:ok,
         assign(socket,
           selected_agent_id: agent.id,
           selected_agent: snapshot.agent,
           selected_architecture: architecture_for_agent(snapshot.agent),
           selected_panel: panel,
           events: snapshot.events,
           agent_spend: snapshot.spend,
           inspection: snapshot.inspection,
           inspection_errors: snapshot.errors,
           launch: launch_for_panel(socket, agent, panel),
           launch_error: nil
         )}

      {:degraded, snapshot} ->
        inspection =
          if socket.assigns.selected_agent_id == agent.id do
            merge_degraded_inspection(socket.assigns.inspection, snapshot.inspection)
          else
            snapshot.inspection
          end

        {:ok,
         assign(socket,
           selected_agent_id: agent.id,
           selected_agent:
             if(socket.assigns.selected_agent_id == agent.id,
               do: socket.assigns.selected_agent || agent,
               else: agent
             ),
           selected_architecture: architecture_for_agent(agent),
           selected_panel: panel,
           events:
             if(socket.assigns.selected_agent_id == agent.id, do: socket.assigns.events, else: []),
           agent_spend:
             if(socket.assigns.selected_agent_id == agent.id,
               do: socket.assigns.agent_spend,
               else: empty_spend()
             ),
           inspection: inspection,
           inspection_errors: snapshot.errors,
           launch: launch_for_panel(socket, agent, panel),
           launch_error: nil
         )}

      {:error, :not_found} ->
        {:sanitize, clear_selection(socket), filters_path(socket), {:error, "Agent not found"}}
    end
  end

  defp refresh_registry(socket) do
    agents = Agents.list_agents(user_id: current_user_id(socket), preload: [:project])
    filtered_agents = filter_agents(agents, socket.assigns.filters)

    assign(socket, all_agents: agents, agents: filtered_agents)
  end

  defp refresh_selected_workspace(socket) do
    case socket.assigns.selected_agent_id do
      nil ->
        {:ok, socket}

      id ->
        case Agents.get_agent_for_user(id, current_user_id(socket)) do
          nil ->
            {:sanitize, clear_selection(socket), filters_path(socket),
             {:error, "Agent not found"}}

          agent ->
            load_selected_snapshot(socket, agent, socket.assigns.selected_panel || :inspect)
        end
    end
  end

  defp refresh_selected_workspace_or_clear(socket) do
    case refresh_selected_workspace(socket) do
      {:ok, socket} ->
        socket

      {:sanitize, socket, to, flash} ->
        socket |> maybe_put_flash(flash) |> push_patch(to: to)
    end
  end

  defp clear_missing_selection(socket, id) do
    if socket.assigns.selected_agent_id == id do
      socket
      |> clear_selection()
      |> push_patch(to: filters_path(socket))
    else
      socket
    end
  end

  defp clear_selection(socket) do
    assign(socket,
      selected_agent_id: nil,
      selected_agent: nil,
      selected_architecture: nil,
      selected_panel: nil,
      events: [],
      inspection: empty_inspection(),
      agent_spend: empty_spend(),
      inspection_errors: [],
      launch: default_launch_params(),
      launch_error: nil
    )
  end

  defp maybe_emit_route_telemetry(socket, route_state) do
    previous = socket.assigns.route_state

    if is_nil(previous) do
      :telemetry.execute(
        [:maraithon, :agents, :view, :loaded],
        %{agent_count: length(socket.assigns.all_agents)},
        %{has_selection: not is_nil(route_state.id), panel: route_state.panel}
      )
    end

    if selection_changed?(previous, route_state) and route_state.id do
      :telemetry.execute(
        [:maraithon, :agents, :selection, :changed],
        %{count: 1},
        %{agent_id: route_state.id, panel: route_state.panel || :inspect}
      )
    end

    if filter_changed?(previous, route_state) do
      :telemetry.execute(
        [:maraithon, :agents, :filter, :changed],
        %{count: 1},
        %{status: route_state.status, has_query: route_state.q != ""}
      )
    end

    assign(socket, :route_state, route_state)
  end

  defp emit_action_telemetry(action, surface, agent_id, outcome) do
    :telemetry.execute(
      [:maraithon, :agents, :action],
      %{count: 1},
      %{action: action, surface: surface, agent_id: agent_id, outcome: outcome}
    )
  end

  defp selection_changed?(nil, _route_state), do: false

  defp selection_changed?(previous, current) do
    previous.id != current.id or previous.panel != current.panel
  end

  defp filter_changed?(nil, _route_state), do: false

  defp filter_changed?(previous, current) do
    previous.status != current.status or previous.q != current.q
  end

  defp default_filters do
    %{status: "all", q: ""}
  end

  defp normalize_status(status) when status in @status_options, do: status
  defp normalize_status(_status), do: "all"

  defp normalize_query(query) when is_binary(query), do: String.trim(query)
  defp normalize_query(_query), do: ""

  defp normalize_panel("inspect"), do: :inspect
  defp normalize_panel("edit"), do: :edit
  defp normalize_panel(_panel), do: nil

  defp normalize_id(id) when is_binary(id) do
    case String.trim(id) do
      "" -> nil
      value -> value
    end
  end

  defp normalize_id(_id), do: nil

  defp current_path_from_uri(uri) when is_binary(uri) do
    uri
    |> URI.parse()
    |> Map.get(:path)
    |> case do
      nil -> "/agents"
      "" -> "/agents"
      path -> path
    end
  rescue
    _ -> "/agents"
  end

  defp filters_path(socket), do: agents_path(socket.assigns.filters)

  defp agents_path_for_socket(socket, filters) do
    agents_path(filters, %{
      id: socket.assigns.selected_agent_id,
      panel: socket.assigns.selected_panel
    })
  end

  defp agents_path(filters) when is_map(filters), do: agents_path(filters, %{})

  defp agents_path(filters, extra) when is_map(filters) and is_map(extra) do
    query =
      []
      |> maybe_put_query("id", Map.get(extra, :id))
      |> maybe_put_query("panel", panel_param(Map.get(extra, :panel)))
      |> maybe_put_query("status", filters.status, filters.status != "all")
      |> maybe_put_query("q", filters.q, filters.q != "")

    case URI.encode_query(query) do
      "" -> "/agents"
      encoded -> "/agents?" <> encoded
    end
  end

  defp maybe_put_query(params, _key, _value, false), do: params
  defp maybe_put_query(params, key, value, true), do: maybe_put_query(params, key, value)
  defp maybe_put_query(params, _key, nil), do: params
  defp maybe_put_query(params, _key, ""), do: params
  defp maybe_put_query(params, key, value), do: params ++ [{key, value}]

  defp panel_param(:inspect), do: nil
  defp panel_param(:edit), do: "edit"
  defp panel_param(_panel), do: nil

  defp filter_agents(agents, %{status: status, q: query}) do
    agents
    |> Enum.filter(fn agent ->
      status == "all" or agent.status == status
    end)
    |> Enum.filter(fn agent ->
      matches_query?(agent, query)
    end)
  end

  defp matches_query?(_agent, ""), do: true

  defp matches_query?(agent, query) do
    query = String.downcase(query)

    [agent_name(agent.config), agent.behavior, agent.id]
    |> Enum.map(fn value -> value |> Kernel.||("") |> to_string() |> String.downcase() end)
    |> Enum.any?(&String.contains?(&1, query))
  end

  defp launch_for_panel(socket, agent, :edit) do
    if socket.assigns.selected_agent_id == agent.id and socket.assigns.selected_panel == :edit do
      socket.assigns.launch
    else
      launch_params_from_agent(agent)
    end
  end

  defp launch_for_panel(_socket, _agent, _panel), do: default_launch_params()

  defp action_surface("workspace"), do: :workspace
  defp action_surface(_surface), do: :row

  defp humanize_status("all"), do: "All statuses"
  defp humanize_status(status), do: status |> String.replace("_", " ") |> String.capitalize()

  defp row_class(selected_agent_id, agent_id) when selected_agent_id == agent_id,
    do:
      "cursor-pointer bg-cyan-50/70 transition hover:bg-cyan-50 focus:outline-none focus:ring-2 focus:ring-inset focus:ring-cyan-500"

  defp row_class(_selected_agent_id, _agent_id),
    do:
      "cursor-pointer transition hover:bg-slate-50 focus:outline-none focus:ring-2 focus:ring-inset focus:ring-cyan-500"

  defp inspect_layout_class(agent) do
    if chief_of_staff_agent?(agent) do
      "space-y-6"
    else
      "grid grid-cols-1 gap-6 xl:grid-cols-[minmax(0,1.1fr)_minmax(0,0.9fr)]"
    end
  end

  defp workspace_tab_class(true),
    do:
      "inline-flex items-center rounded-full bg-slate-900 px-3 py-1.5 text-xs font-semibold text-white"

  defp workspace_tab_class(false),
    do:
      "inline-flex items-center rounded-full border border-slate-300 px-3 py-1.5 text-xs font-semibold text-slate-700 hover:bg-slate-50"

  defp behaviors do
    AgentBuilder.behavior_specs()
    |> Enum.map(& &1.id)
    |> Enum.sort()
  end

  defp default_launch_params do
    AgentBuilder.default_launch_params()
  end

  defp launch_params_from_agent(agent), do: AgentBuilder.launch_params_from_agent(agent)

  defp normalize_launch_params(params), do: AgentBuilder.normalize_launch_params(params)

  defp build_agent_start_params(launch, user_id),
    do: AgentBuilder.build_start_params(launch, user_id)

  defp agent_owned_by_current_user?(socket, agent_id) when is_binary(agent_id) do
    not is_nil(Agents.get_agent_for_user(agent_id, current_user_id(socket)))
  end

  defp agent_owned_by_current_user?(_socket, _agent_id), do: false

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

  defp maybe_put_flash(socket, nil), do: socket
  defp maybe_put_flash(socket, {kind, message}), do: put_flash(socket, kind, message)

  defp current_user_id(socket), do: socket.assigns.current_user.id

  defp agent_name(config), do: config["name"] || "unnamed_agent"

  defp agent_display_name(%{config: config} = agent) when is_map(config) do
    name = agent_name(config)

    if technical_agent_name?(name) do
      agent_kind_label(agent)
    else
      name
    end
  end

  defp agent_display_name(agent), do: agent_kind_label(agent)

  defp technical_agent_name?(name) when is_binary(name) do
    String.contains?(name, "_") or Regex.match?(~r/-[0-9a-f]{4,}$/i, name)
  end

  defp technical_agent_name?(_name), do: true

  defp agent_updated_at(%{updated_at: updated_at}), do: updated_at
  defp agent_updated_at(_agent), do: nil

  defp agent_kind_label(%{behavior: "ai_chief_of_staff"}), do: "Chief of Staff"

  defp agent_kind_label(%{behavior: "founder_followthrough_agent"}),
    do: "Follow-through assistant"

  defp agent_kind_label(%{behavior: "inbox_calendar_advisor"}), do: "Inbox and calendar assistant"

  defp agent_kind_label(%{behavior: "slack_followthrough_agent"}),
    do: "Slack follow-through assistant"

  defp agent_kind_label(%{behavior: "prompt_agent"}), do: "Custom assistant"

  defp agent_kind_label(%{behavior: behavior}) when is_binary(behavior) do
    behavior
    |> String.replace("_", " ")
    |> String.split()
    |> Enum.map_join(" ", &String.capitalize/1)
  end

  defp agent_kind_label(_agent), do: "Assistant"

  defp agent_row_summary(%{behavior: "ai_chief_of_staff"}),
    do: "Daily briefings, follow-through, travel, projects, and reminders."

  defp agent_row_summary(%{behavior: "founder_followthrough_agent"}),
    do: "Tracks open loops and reminds you when a commitment needs action."

  defp agent_row_summary(%{behavior: "inbox_calendar_advisor"}),
    do: "Watches inbox and calendar context for timely follow-up."

  defp agent_row_summary(%{behavior: "slack_followthrough_agent"}),
    do: "Finds Slack threads and messages that need a reply."

  defp agent_row_summary(agent), do: agent_job_summary(agent)

  defp chief_of_staff_agent?(%{behavior: behavior}) when behavior in ["ai_chief_of_staff"],
    do: true

  defp chief_of_staff_agent?(_agent), do: false

  defp chief_skill_rows(%{config: config}) when is_map(config) do
    enabled_ids = ChiefOfStaffSkills.enabled_ids(config)

    enabled_ids
    |> Enum.map(fn id ->
      %{
        id: id,
        label: chief_skill_label(id),
        description: chief_skill_description(id)
      }
    end)
  end

  defp chief_skill_rows(_agent), do: []

  defp chief_skill_label("followthrough"), do: "Follow-through"
  defp chief_skill_label("travel_logistics"), do: "Travel logistics"
  defp chief_skill_label("morning_briefing"), do: "Morning briefing"
  defp chief_skill_label("briefing"), do: "Briefing"
  defp chief_skill_label("project_scope_alignment"), do: "Project scope alignment"
  defp chief_skill_label("holiday_radar"), do: "Holiday radar"

  defp chief_skill_label(id) when is_binary(id) do
    id
    |> String.replace("_", " ")
    |> String.split()
    |> Enum.map_join(" ", &String.capitalize/1)
  end

  defp chief_skill_description("followthrough"),
    do: "Finds commitments, unanswered threads, and replies that need action."

  defp chief_skill_description("travel_logistics"),
    do: "Tracks flights, hotels, local timing, and calendar-sensitive travel work."

  defp chief_skill_description("morning_briefing"),
    do: "Builds the daily Chief of Staff briefing and sends it through Telegram."

  defp chief_skill_description("briefing"),
    do: "Prepares scheduled operator summaries from the configured source bundle."

  defp chief_skill_description("project_scope_alignment"),
    do: "Checks whether active work is aligned with the current project scope."

  defp chief_skill_description("holiday_radar"),
    do: "Surfaces upcoming family, holiday, and gift reminders before they become urgent."

  defp chief_skill_description(_id), do: "Runs as part of the Chief of Staff cycle."

  defp chief_source_labels, do: ["Gmail", "Calendar", "Slack", "News"]

  defp morning_brief_schedule(%{config: config}) when is_map(config) do
    hour = config |> Map.get("morning_brief_hour_local") |> parse_integer(8) |> clamp_hour()
    timezone_offset = config |> Map.get("timezone_offset_hours") |> parse_integer(-5)

    %{
      hour: hour,
      display_time_local: display_hour(hour),
      local_timezone: timezone_label(timezone_offset)
    }
  end

  defp morning_brief_schedule(_agent) do
    %{hour: 8, display_time_local: "8:00 AM", local_timezone: "UTC-05:00"}
  end

  defp morning_brief_hour_options do
    Enum.map(0..23, fn hour ->
      %{value: hour, label: display_hour(hour)}
    end)
  end

  defp schedule_error_message(reason) when is_binary(reason), do: reason
  defp schedule_error_message(reason), do: reason |> inspect() |> String.replace("_", " ")

  defp parse_integer(value, _default) when is_integer(value), do: value

  defp parse_integer(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} -> integer
      _ -> default
    end
  end

  defp parse_integer(_value, default), do: default

  defp clamp_hour(hour) when hour < 0, do: 0
  defp clamp_hour(hour) when hour > 23, do: 23
  defp clamp_hour(hour), do: hour

  defp display_hour(hour) when is_integer(hour) do
    suffix = if hour < 12, do: "AM", else: "PM"
    display_hour = rem(hour, 12)
    display_hour = if display_hour == 0, do: 12, else: display_hour

    "#{display_hour}:00 #{suffix}"
  end

  defp timezone_label(offset) when is_integer(offset) do
    sign = if offset < 0, do: "-", else: "+"
    hours = offset |> abs() |> Integer.to_string() |> String.pad_leading(2, "0")

    "UTC#{sign}#{hours}:00"
  end

  defp agent_prompt(config),
    do: config["prompt"] || AgentBuilder.default_launch_params()["prompt"]

  defp pretty_config(config) when is_map(config) do
    Jason.encode!(config, pretty: true)
  rescue
    _ -> inspect(config, pretty: true, limit: :infinity)
  end

  defp pretty_config(config), do: inspect(config, pretty: true, limit: :infinity)

  defp subscriptions_preview(config) do
    case config["subscribe"] || [] do
      [] -> "No subscriptions"
      values -> values |> Enum.take(3) |> Enum.join(", ") |> truncate(70)
    end
  end

  defp tools_preview(config) do
    case config["tools"] || [] do
      [] -> "No tools"
      values -> values |> Enum.join(", ") |> truncate(70)
    end
  end

  defp architecture_for_agent(agent) do
    case AgentArchitecture.for_agent(agent) do
      {:ok, architecture} -> architecture
      {:error, _reason} -> nil
    end
  end

  defp agent_job_summary(agent) do
    agent
    |> behavior_spec()
    |> Map.get(:summary, "Runs the saved agent behavior for this operator.")
  end

  defp agent_connector_requirements(agent) do
    requirements =
      agent
      |> behavior_spec()
      |> Map.get(:requirements, [])
      |> Enum.filter(&connector_requirement?/1)
      |> Enum.map(&connector_requirement_summary/1)

    case Enum.uniq_by(requirements, &{&1.provider, &1.label}) do
      [] -> inferred_subscription_connectors(agent.config)
      values -> values
    end
  end

  defp agent_connector_logo_items(agent) do
    agent
    |> agent_connector_requirements()
    |> Enum.uniq_by(& &1.provider)
  end

  defp behavior_spec(agent), do: AgentBuilder.behavior_spec(agent.behavior)

  defp connector_requirement?(%{kind: kind, provider: provider})
       when kind in [:provider, :provider_service] and is_binary(provider),
       do: true

  defp connector_requirement?(_requirement), do: false

  defp connector_requirement_summary(%{provider: provider, label: label}) do
    %{
      provider: connector_logo_provider(provider),
      label: label
    }
  end

  defp inferred_subscription_connectors(config) when is_map(config) do
    (config["subscribe"] || [])
    |> Enum.map(&subscription_provider/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.map(fn provider ->
      %{
        provider: connector_logo_provider(provider),
        label: connector_label(provider)
      }
    end)
    |> case do
      [] -> [%{provider: "generic", label: "No connector dependency"}]
      values -> values
    end
  end

  defp inferred_subscription_connectors(_config),
    do: [%{provider: "generic", label: "No connector dependency"}]

  defp connected_app_account_rows(user_id, agent) when is_binary(user_id) do
    requirements =
      agent
      |> agent_connector_requirements()
      |> Enum.reject(&(&1.provider == "generic"))
      |> Enum.group_by(& &1.provider)

    required_providers = requirements |> Map.keys() |> MapSet.new()

    user_id
    |> connection_snapshot()
    |> Map.get(:providers, [])
    |> Enum.filter(fn provider ->
      provider_key = provider_key(provider)
      MapSet.member?(required_providers, provider_key)
    end)
    |> Enum.flat_map(fn provider ->
      provider
      |> provider_account_rows(Map.get(requirements, provider_key(provider), []), user_id)
    end)
  end

  defp connected_app_account_rows(_user_id, _agent), do: []

  defp connection_snapshot(user_id) do
    case Connections.safe_dashboard_snapshot(user_id, return_to: "/agents") do
      {:ok, snapshot} -> snapshot
      {:degraded, snapshot} -> snapshot
      _ -> %{providers: []}
    end
  end

  defp provider_account_rows(%{provider: "telegram"} = provider, requirements, user_id) do
    case Maraithon.ConnectedAccounts.get(user_id, "telegram") do
      %{status: "connected"} = account ->
        [telegram_account_row(provider, account)]

      _ ->
        fallback_provider_account_rows(provider, requirements)
    end
  end

  defp provider_account_rows(provider, requirements, _user_id) do
    account_rows =
      provider
      |> Map.get(:accounts, [])
      |> Enum.map(&account_row(provider, &1, requirements))

    case account_rows do
      [] -> fallback_provider_account_rows(provider, requirements)
      rows -> rows
    end
  end

  defp telegram_account_row(provider, account) do
    metadata = account.metadata || %{}
    username = presence(metadata["username"] || metadata[:username])
    chat_id = presence(account.external_account_id || metadata["chat_id"] || metadata[:chat_id])

    %{
      logo_provider: "telegram",
      app: Map.get(provider, :label) || "Telegram",
      account: if(username, do: "@#{username}", else: chat_id || "Telegram chat"),
      note: chat_id && "Chat ID #{chat_id}",
      access: "Delivery to Telegram",
      status: account.status,
      updated_at: account.updated_at
    }
  end

  defp account_row(provider, account, requirements) do
    %{
      logo_provider: connector_logo_provider(provider_key(provider)),
      app: Map.get(provider, :label) || connector_label(provider_key(provider)),
      account: account_value(account, :account, "Connected account"),
      note: account_value(account, :status_note, nil),
      access: account_access_summary(account, requirements),
      status: Map.get(account, :status, Map.get(provider, :status)),
      updated_at: Map.get(account, :updated_at) || Map.get(provider, :updated_at)
    }
  end

  defp fallback_provider_account_rows(%{status: status} = provider, requirements) do
    details = Map.get(provider, :details, [])

    if status in [:connected, :partial, :needs_refresh] or details != [] do
      [
        %{
          logo_provider: connector_logo_provider(provider_key(provider)),
          app: Map.get(provider, :label) || connector_label(provider_key(provider)),
          account: provider_account_label(provider),
          note: nil,
          access: provider_access_summary(provider, requirements),
          status: status,
          updated_at: Map.get(provider, :updated_at)
        }
      ]
    else
      []
    end
  end

  defp fallback_provider_account_rows(_provider, _requirements), do: []

  defp provider_key(%{provider: provider}) when is_binary(provider),
    do: connector_logo_provider(provider)

  defp provider_key(%{id: id}) when is_binary(id), do: connector_logo_provider(id)
  defp provider_key(_provider), do: "generic"

  defp account_value(account, key, fallback) when is_map(account) do
    account
    |> Map.get(key)
    |> presence()
    |> case do
      nil -> fallback
      value -> value
    end
  end

  defp account_value(_account, _key, fallback), do: fallback

  defp account_access_summary(account, requirements) do
    details =
      account
      |> Map.get(:details, [])
      |> Enum.map(&to_string/1)
      |> Enum.reject(&(&1 == ""))

    cond do
      details != [] ->
        Enum.join(details, " · ")

      requirements != [] ->
        requirements |> Enum.map(& &1.label) |> Enum.join(", ")

      true ->
        "Connected"
    end
  end

  defp provider_account_label(%{provider: "telegram", details: details}) when is_list(details) do
    Enum.find(details, &String.starts_with?(to_string(&1), "@")) ||
      Enum.find(details, &String.starts_with?(to_string(&1), "Chat")) ||
      "Telegram chat"
  end

  defp provider_account_label(%{label: label}) when is_binary(label), do: label
  defp provider_account_label(_provider), do: "Connected account"

  defp provider_access_summary(%{provider: "telegram"}, _requirements), do: "Delivery to Telegram"

  defp provider_access_summary(provider, requirements) do
    details =
      provider
      |> Map.get(:details, [])
      |> Enum.map(&to_string/1)
      |> Enum.reject(&(&1 == ""))

    cond do
      details != [] -> Enum.join(details, " · ")
      requirements != [] -> requirements |> Enum.map(& &1.label) |> Enum.join(", ")
      true -> "Connected"
    end
  end

  defp account_status_label(status) when is_atom(status) do
    status |> Atom.to_string() |> account_status_label()
  end

  defp account_status_label(status) when is_binary(status) do
    status |> String.replace("_", " ") |> String.capitalize()
  end

  defp account_status_label(_status), do: "Connected"

  defp account_status_color(status) when status in [:connected, "connected"], do: "emerald"

  defp account_status_color(status)
       when status in [:partial, "partial", :needs_refresh, "needs_refresh"],
       do: "amber"

  defp account_status_color(_status), do: "zinc"

  defp presence(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp presence(nil), do: nil
  defp presence(value), do: value

  defp subscription_provider(topic) when is_binary(topic) do
    topic
    |> String.split(":", parts: 2)
    |> List.first()
    |> case do
      provider
      when provider in ["gmail", "calendar", "github", "slack", "linear", "telegram", "notion"] ->
        provider

      _ ->
        nil
    end
  end

  defp subscription_provider(_topic), do: nil

  defp connector_logo_provider(provider) when provider in ["gmail", "calendar"], do: "google"
  defp connector_logo_provider(provider) when is_binary(provider), do: provider
  defp connector_logo_provider(_provider), do: "generic"

  defp connector_label("google"), do: "Google"
  defp connector_label("gmail"), do: "Gmail"
  defp connector_label("calendar"), do: "Calendar"
  defp connector_label("github"), do: "GitHub"
  defp connector_label("slack"), do: "Slack"
  defp connector_label("linear"), do: "Linear"
  defp connector_label("telegram"), do: "Telegram"
  defp connector_label(provider), do: provider

  defp connector_logo_src("google"), do: "/images/connector-logos/google.svg"
  defp connector_logo_src("github"), do: "/images/connector-logos/github.svg"
  defp connector_logo_src("slack"), do: "/images/connector-logos/slack.svg"
  defp connector_logo_src("linear"), do: "/images/connector-logos/linear.svg"
  defp connector_logo_src("notion"), do: "/images/connector-logos/notion.png"
  defp connector_logo_src("notaui"), do: "/images/connector-logos/notaui.png"
  defp connector_logo_src("telegram"), do: "/images/connector-logos/telegram.png"
  defp connector_logo_src(_provider), do: "/favicon.ico"

  defp effect_preview(effect) do
    cond do
      is_binary(effect.error) and effect.error != "" ->
        effect.error

      is_map(effect.result) and effect.result != %{} ->
        payload_preview(effect.result)

      true ->
        payload_preview(effect.params)
    end
  end

  defp effect_status_class("failed"),
    do: "rounded-full bg-rose-100 px-2 py-0.5 text-xs font-medium text-rose-700"

  defp effect_status_class("completed"),
    do: "rounded-full bg-emerald-100 px-2 py-0.5 text-xs font-medium text-emerald-700"

  defp effect_status_class("claimed"),
    do: "rounded-full bg-amber-100 px-2 py-0.5 text-xs font-medium text-amber-700"

  defp effect_status_class(_status),
    do: "rounded-full bg-slate-100 px-2 py-0.5 text-xs font-medium text-slate-700"

  defp job_status_class("cancelled"),
    do: "rounded-full bg-rose-100 px-2 py-0.5 text-xs font-medium text-rose-700"

  defp job_status_class("delivered"),
    do: "rounded-full bg-emerald-100 px-2 py-0.5 text-xs font-medium text-emerald-700"

  defp job_status_class("dispatched"),
    do: "rounded-full bg-amber-100 px-2 py-0.5 text-xs font-medium text-amber-700"

  defp job_status_class(_status),
    do: "rounded-full bg-slate-100 px-2 py-0.5 text-xs font-medium text-slate-700"

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

  defp format_log_timestamp(timestamp) when is_binary(timestamp) do
    case DateTime.from_iso8601(timestamp) do
      {:ok, datetime, _offset} ->
        Calendar.strftime(datetime, "%H:%M:%S")

      _ ->
        timestamp
    end
  end

  defp format_log_timestamp(_timestamp), do: "n/a"

  defp log_level_class(level) when level in [:error, :critical, :alert, :emergency],
    do: "text-rose-300"

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
      _ -> "text-slate-300"
    end
  end

  defp log_level_class(_level), do: "text-slate-300"

  defp log_metadata_preview(metadata) when metadata in [%{}, nil], do: nil

  defp log_metadata_preview(metadata) when is_map(metadata) do
    metadata
    |> Enum.reject(fn {_key, value} -> is_nil(value) or value == "" end)
    |> Enum.sort_by(fn {key, _value} -> key end)
    |> Enum.map_join(" ", fn {key, value} -> "#{key}=#{value}" end)
    |> truncate(120)
  end

  defp log_metadata_preview(_metadata), do: nil

  defp format_time(nil), do: "N/A"

  defp format_time(datetime) when is_binary(datetime) do
    case DateTime.from_iso8601(datetime) do
      {:ok, dt, _offset} -> format_time(dt)
      _ -> datetime
    end
  end

  defp format_time(%DateTime{} = dt), do: Calendar.strftime(dt, "%H:%M:%S")
  defp format_time(%NaiveDateTime{} = dt), do: Calendar.strftime(dt, "%H:%M:%S")

  defp format_datetime(nil), do: "N/A"

  defp format_datetime(datetime) when is_binary(datetime) do
    case DateTime.from_iso8601(datetime) do
      {:ok, dt, _offset} -> format_datetime(dt)
      _ -> datetime
    end
  end

  defp format_datetime(%DateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S UTC")
  defp format_datetime(%NaiveDateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S")
end
