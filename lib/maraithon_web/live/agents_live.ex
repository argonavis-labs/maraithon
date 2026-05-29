defmodule MaraithonWeb.AgentsLive do
  use MaraithonWeb, :live_view

  alias Maraithon.Admin
  alias Maraithon.AgentArchitecture
  alias Maraithon.AgentBuilder
  alias Maraithon.AgentMarketplace
  alias Maraithon.Agents
  alias Maraithon.Agents.AgentPackage
  alias Maraithon.Agents.AgentPackageVersion
  alias Maraithon.BriefingSchedules
  alias Maraithon.ChiefOfStaff.Skills, as: ChiefOfStaffSkills
  alias Maraithon.Connections
  alias Maraithon.RunErrorCopy
  alias Maraithon.Runtime
  alias MaraithonWeb.AgentActionCopy
  alias MaraithonWeb.OperationFailureCopy

  @refresh_interval 5_000
  @event_limit 50
  @status_options ~w(all running degraded stopped)

  @impl true
  def mount(_params, _session, socket) do
    socket =
      assign(socket,
        page_title: "Automations",
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
        route_state: nil,
        library: [],
        marketplace_error: nil,
        provider_status: %{}
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
      {:noreply,
       socket |> clear_missing_selection(id) |> put_flash(:error, "Automation not found")}
    end
  end

  def handle_event("install_library_agent", %{"behavior" => behavior_id}, socket) do
    user_id = current_user_id(socket)

    package = ensure_marketplace_package(behavior_id)

    case package do
      %{slug: slug} ->
        case install_library_package(user_id, slug) do
          {:ok, agent} ->
            {:noreply,
             socket
             |> refresh_registry()
             |> put_flash(:info, "Installed #{agent_display_name(agent)}")
             |> push_patch(
               to: agents_path(socket.assigns.filters, %{id: agent.id, panel: :inspect})
             )}

          {:error, message} when is_binary(message) ->
            {:noreply, put_flash(socket, :error, AgentActionCopy.error(:install, message))}

          {:error, %Ecto.Changeset{} = changeset} ->
            {:noreply, put_flash(socket, :error, AgentActionCopy.error(:install, changeset))}

          {:error, reason} ->
            {:noreply, put_flash(socket, :error, AgentActionCopy.error(:install, reason))}
        end

      _ ->
        launch = Map.put(default_launch_params(), "behavior", behavior_id)

        case build_agent_start_params(launch, user_id) do
          {:ok, params} ->
            case Runtime.start_agent(params) do
              {:ok, agent} ->
                {:noreply,
                 socket
                 |> refresh_registry()
                 |> put_flash(:info, "Installed #{agent_display_name(agent)}")
                 |> push_patch(
                   to: agents_path(socket.assigns.filters, %{id: agent.id, panel: :inspect})
                 )}

              {:error, message} when is_binary(message) ->
                {:noreply, put_flash(socket, :error, AgentActionCopy.error(:install, message))}

              {:error, %Ecto.Changeset{} = changeset} ->
                {:noreply, put_flash(socket, :error, AgentActionCopy.error(:install, changeset))}

              {:error, reason} ->
                {:noreply, put_flash(socket, :error, AgentActionCopy.error(:install, reason))}
            end

          {:error, message} when is_binary(message) ->
            {:noreply, put_flash(socket, :error, message)}

          {:error, reason} ->
            {:noreply, put_flash(socket, :error, AgentActionCopy.error(:install, reason))}
        end
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
           |> put_flash(:info, "Automation started")}

        {:error, :already_running} ->
          emit_action_telemetry("start", surface, id, :ok)

          {:noreply,
           socket
           |> refresh_registry()
           |> refresh_selected_workspace_or_clear()
           |> put_flash(:info, "Automation is already active")}

        {:error, :not_found} ->
          emit_action_telemetry("start", surface, id, :error)

          {:noreply,
           socket
           |> refresh_registry()
           |> clear_missing_selection(id)
           |> put_flash(:error, "Automation not found")}

        {:error, reason} ->
          emit_action_telemetry("start", surface, id, :error)

          {:noreply,
           socket
           |> refresh_registry()
           |> refresh_selected_workspace_or_clear()
           |> put_flash(:error, AgentActionCopy.error(:start, reason))}
      end
    else
      emit_action_telemetry("start", surface, id, :error)

      {:noreply,
       socket
       |> refresh_registry()
       |> clear_missing_selection(id)
       |> put_flash(:error, "Automation not found")}
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
           |> put_flash(:info, "Automation paused")}

        {:error, :not_found} ->
          emit_action_telemetry("stop", surface, id, :error)

          {:noreply,
           socket
           |> refresh_registry()
           |> clear_missing_selection(id)
           |> put_flash(:error, "Automation not found")}

        {:error, reason} ->
          emit_action_telemetry("stop", surface, id, :error)

          {:noreply,
           socket
           |> refresh_registry()
           |> refresh_selected_workspace_or_clear()
           |> put_flash(:error, AgentActionCopy.error(:stop, reason))}
      end
    else
      emit_action_telemetry("stop", surface, id, :error)

      {:noreply,
       socket
       |> refresh_registry()
       |> clear_missing_selection(id)
       |> put_flash(:error, "Automation not found")}
    end
  end

  def handle_event("delete_agent", %{"id" => id} = params, socket) do
    surface = action_surface(Map.get(params, "surface"))

    if agent_owned_by_current_user?(socket, id) do
      agent = Agents.get_agent_for_user(id, current_user_id(socket))
      {action, success_message, result} = remove_or_delete_agent(agent, id)

      case result do
        :ok ->
          emit_action_telemetry(action, surface, id, :ok)

          socket =
            socket
            |> refresh_registry()
            |> assign(launch_error: nil)
            |> put_flash(:info, success_message)

          {:noreply, clear_missing_selection(socket, id)}

        {:error, :not_found} ->
          emit_action_telemetry(action, surface, id, :error)

          {:noreply,
           socket
           |> refresh_registry()
           |> clear_missing_selection(id)
           |> put_flash(:error, "Automation not found")}

        {:error, reason} ->
          emit_action_telemetry(action, surface, id, :error)

          {:noreply,
           socket
           |> refresh_registry()
           |> refresh_selected_workspace_or_clear()
           |> put_flash(:error, AgentActionCopy.error(:delete, reason))}
      end
    else
      emit_action_telemetry("delete", surface, id, :error)

      {:noreply,
       socket
       |> refresh_registry()
       |> clear_missing_selection(id)
       |> put_flash(:error, "Automation not found")}
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
       |> put_flash(:info, "Automation updated")
       |> push_patch(to: agents_path(socket.assigns.filters, %{id: agent.id, panel: :inspect}))}
    else
      false ->
        emit_action_telemetry("update", :workspace, id || "unknown", :error)

        {:noreply,
         socket |> clear_missing_selection(id) |> put_flash(:error, "Automation not found")}

      {:error, message} when is_binary(message) ->
        emit_action_telemetry("update", :workspace, id, :error)
        {:noreply, assign(socket, launch: launch, launch_error: message)}

      {:error, %Ecto.Changeset{} = changeset} ->
        emit_action_telemetry("update", :workspace, id, :error)

        {:noreply,
         assign(
           socket,
           launch: launch,
           launch_error: AgentActionCopy.error(:update, changeset)
         )}

      {:error, reason} ->
        emit_action_telemetry("update", :workspace, id, :error)

        {:noreply,
         assign(socket,
           launch: launch,
           launch_error: AgentActionCopy.error(:update, reason)
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
        {:noreply,
         socket |> clear_missing_selection(id) |> put_flash(:error, "Automation not found")}

      {:error, reason} ->
        {:noreply,
         socket
         |> refresh_registry()
         |> refresh_selected_workspace_or_clear()
         |> put_flash(:error, OperationFailureCopy.briefing_schedule(:morning, reason))}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_path={@current_path} current_user={@current_user}>
      <div class="space-y-6">
        <header class="flex flex-wrap items-end justify-between gap-3">
          <h1 class="text-2xl/8 font-semibold tracking-tight text-zinc-950 sm:text-xl/8">
            Automations
          </h1>
          <div class="flex items-center gap-2">
            <span class="text-xs/5 text-zinc-500"><%= length(@all_agents) %> total</span>
            <.button href={~p"/agents/new"}>
              New automation
            </.button>
          </div>
        </header>

        <form
          id="agent-filters"
          phx-change="update_filters"
          class="flex flex-wrap items-center gap-2"
        >
          <label class="sr-only" for="agent-search">Search automations</label>
          <div class="w-72">
            <.c_input
              id="agent-search"
              type="search"
              name="filters[q]"
              value={@filters.q}
              placeholder="Search automations"
            />
          </div>
          <label class="sr-only" for="agent-status">Filter by status</label>
          <div class="w-44">
            <.c_select id="agent-status" name="filters[status]">
              <option
                :for={status <- @status_options}
                value={status}
                selected={status == @filters.status}
              >
                <%= humanize_status(status) %>
              </option>
            </.c_select>
          </div>
          <button
            :if={@filters.status != "all" or @filters.q != ""}
            type="button"
            phx-click="clear_filters"
            class="text-xs/5 font-medium text-zinc-500 hover:text-zinc-950"
          >
            Reset
          </button>
        </form>

        <div>
          <.table>
              <.table_head>
                <.table_row>
                  <.table_header>Automation</.table_header>
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
                    <.table_cell colspan="4" class="py-12 text-center">
                      <p class="text-sm/6 text-zinc-700">No automations yet.</p>
                      <p class="mt-1 text-sm/6 text-zinc-500">
                        Build one from a template — connect the apps it needs and launch it from there.
                      </p>
                      <.link
                        navigate={~p"/agents/new"}
                        class="mt-4 inline-flex text-xs/5 font-medium text-zinc-950 hover:text-zinc-700"
                      >
                        Start with a template →
                      </.link>
                    </.table_cell>
                  </.table_row>
                <% end %>

                <%= if @all_agents != [] and @agents == [] do %>
                  <.table_row>
                    <.table_cell colspan="4" class="py-10 text-center text-sm/6 text-zinc-500">
                      No automations match the current filters.
                      <button
                        type="button"
                        phx-click="clear_filters"
                        class="ml-1 font-medium text-zinc-950 hover:text-zinc-700"
                      >
                        Reset filters →
                      </button>
                    </.table_cell>
                  </.table_row>
                <% end %>
              </.table_body>
            </.table>
        </div>

        <section
          :if={@marketplace_error}
          class="rounded-lg border border-amber-200 bg-amber-50 px-4 py-3 text-sm/6 text-amber-900"
        >
          <p class="font-medium">Automation library needs setup attention.</p>
          <p class="mt-1"><%= @marketplace_error %></p>
        </section>

        <section :if={@library != []}>
          <div class="flex flex-wrap items-end justify-between gap-2 border-b border-zinc-950/10 pb-1">
            <div>
              <h2 class="text-base/7 font-semibold text-zinc-950">Library</h2>
              <p class="mt-0.5 text-sm/6 text-zinc-500">
                Pre-built automations you can install. Each one ships with the right instructions, source access, and action limits.
              </p>
            </div>
            <span class="text-xs/5 text-zinc-500">
              <%= length(@library) %> templates
            </span>
          </div>

          <ul role="list" class="mt-4 grid grid-cols-1 gap-4 sm:grid-cols-2 xl:grid-cols-3">
            <li :for={spec <- @library} class="group">
              <% readiness = library_readiness(spec, @provider_status) %>
              <.link
                navigate={~p"/agents/library/#{spec.id}"}
                class="flex h-full flex-col rounded-lg border border-zinc-950/10 bg-white p-4 transition hover:border-zinc-950/20 hover:shadow-sm"
              >
                <div class="flex items-start justify-between gap-3">
                  <div class="min-w-0">
                    <h3 class="text-sm/6 font-semibold text-zinc-950">
                      <%= spec.label %>
                    </h3>
                    <p class="mt-0.5 text-xs/5 text-zinc-500"><%= spec.category %></p>
                  </div>
                  <span class="flex shrink-0 items-center gap-1">
                    <span :for={connector <- library_connector_logos(spec)} class="relative">
                      <img
                        src={connector_logo_src(connector)}
                        alt={connector}
                        title={connector}
                        class="size-5 object-contain"
                      />
                      <span
                        :if={Map.get(@provider_status, connector) == :connected}
                        class="absolute -right-0.5 -bottom-0.5 size-2 rounded-full bg-emerald-500 ring-2 ring-white"
                        aria-label="Connected"
                      />
                    </span>
                  </span>
                </div>

                <p class="mt-3 line-clamp-3 text-sm/6 text-zinc-600">
                  <%= spec.summary %>
                </p>

                <div :if={readiness.total > 0} class="mt-3 flex items-center gap-1.5">
                  <span class={[
                    "size-1.5 rounded-full",
                    cond do
                      readiness.connected == readiness.total -> "bg-emerald-500"
                      readiness.connected > 0 -> "bg-amber-500"
                      true -> "bg-zinc-300"
                    end
                  ]} aria-hidden="true" />
                  <span class={[
                    "text-xs/5 font-medium",
                    cond do
                      readiness.connected == readiness.total -> "text-emerald-700"
                      readiness.connected > 0 -> "text-amber-700"
                      true -> "text-zinc-500"
                    end
                  ]}>
                    <%= readiness.label %>
                  </span>
                </div>

                <p class="mt-3 text-xs/5 text-zinc-500">
                  <%= library_requirement_summary(spec) %>
                </p>

                <div class="mt-auto flex items-center justify-between border-t border-zinc-950/5 pt-3">
                  <span class="text-xs/5 font-medium text-zinc-500 group-hover:text-zinc-950">
                    Learn more →
                  </span>
                  <span class="text-xs/5 font-medium text-zinc-950">
                    Install
                  </span>
                </div>
              </.link>
            </li>
          </ul>
        </section>

        <.panel :if={@selected_agent} body_class="p-0">
          <:header>
            <div class="flex flex-wrap items-start justify-between gap-4">
              <div>
                <h2 class="text-base/7 font-semibold text-zinc-950">
                  <%= agent_display_name(@selected_agent) %>
                </h2>
                <p
                  :if={agent_kind_label(@selected_agent) != agent_display_name(@selected_agent)}
                  class="mt-0.5 text-sm/6 text-zinc-500"
                >
                  <%= agent_kind_label(@selected_agent) %>
                </p>
              </div>
            </div>
            <nav class="-mb-px flex flex-wrap items-end gap-6 border-b border-zinc-950/10">
              <.link
                patch={agents_path(@filters, %{id: @selected_agent.id, panel: :inspect})}
                class={workspace_tab_class(@selected_panel == :inspect)}
              >
                Overview
              </.link>
              <.link
                patch={agents_path(@filters, %{id: @selected_agent.id, panel: :apps})}
                class={workspace_tab_class(@selected_panel == :apps)}
              >
                Connected apps
              </.link>
              <.link
                patch={agents_path(@filters, %{id: @selected_agent.id, panel: :skills})}
                class={workspace_tab_class(@selected_panel == :skills)}
              >
                Skills
              </.link>
              <.link
                patch={agents_path(@filters, %{id: @selected_agent.id, panel: :edit})}
                class={workspace_tab_class(@selected_panel == :edit)}
              >
                Settings
              </.link>
            </nav>
          </:header>

          <%= if @inspection_errors != [] do %>
            <div class="border-b border-amber-200 bg-amber-50 px-5 py-4">
              <%= for error <- @inspection_errors do %>
                <div class="text-sm text-amber-900">
                  <p class="font-medium"><%= error.message %></p>
                  <p class="mt-1 text-xs text-amber-800"><%= inspection_error_detail(error) %></p>
                </div>
              <% end %>
            </div>
          <% end %>

          <%= if @selected_agent do %>
            <div class="space-y-6 px-5 py-5">
              <div class="flex flex-wrap items-center justify-between gap-3">
                <.status_badge status={@selected_agent.status} />

                <div class="flex flex-wrap items-center gap-1">
                  <%= if @selected_agent.status in ["running", "degraded"] do %>
                    <button
                      type="button"
                      phx-click="stop_agent"
                      phx-value-id={@selected_agent.id}
                      phx-value-surface="workspace"
                      phx-disable-with="Stopping..."
                      class="rounded-md px-2 py-1 text-xs/5 font-medium text-amber-800 hover:bg-amber-50"
                    >
                      Stop
                    </button>
                  <% else %>
                    <button
                      type="button"
                      phx-click="start_agent"
                      phx-value-id={@selected_agent.id}
                      phx-value-surface="workspace"
                      phx-disable-with="Starting..."
                      class="rounded-md px-2 py-1 text-xs/5 font-medium text-emerald-800 hover:bg-emerald-50"
                    >
                      Start
                    </button>
                  <% end %>

                  <button
                    type="button"
                    phx-click="delete_agent"
                    phx-value-id={@selected_agent.id}
                    phx-value-surface="workspace"
                    phx-disable-with="Deleting..."
                    data-confirm="Delete this automation and all dependent records?"
                    class="rounded-md px-2 py-1 text-xs/5 font-medium text-rose-700 hover:bg-rose-50"
                  >
                    Delete
                  </button>
                </div>
              </div>

              <%= if @selected_panel == :edit do %>
                <div class="space-y-8">
                  <%= if @launch_error do %>
                    <.alert color="rose">
                      <%= @launch_error %>
                    </.alert>
                  <% end %>

                  <form id="agent-edit-form" phx-submit="save_agent" class="space-y-8">
                    <input
                      type="hidden"
                      name="launch[builder_mode]"
                      value={Map.get(@launch, "builder_mode", "advanced")}
                    />

                    <section>
                      <div class="flex items-end justify-between border-b border-zinc-950/10 pb-1">
                        <h3 class="text-base/7 font-semibold text-zinc-950">Instructions</h3>
                        <span class="text-xs/5 text-zinc-500">
                          Updates take effect on the next wakeup
                        </span>
                      </div>
                      <p class="mt-2 text-sm/6 text-zinc-500">
                        What is this automation responsible for, how should it communicate, and what should it avoid?
                      </p>
                      <div class="mt-4">
                        <.c_textarea
                          id="launch_prompt"
                          name="launch[prompt]"
                          rows={10}
                          value={@launch["prompt"]}
                        />
                      </div>
                    </section>

                    <details class="group rounded-lg border border-zinc-950/10 bg-white">
                      <summary class="flex cursor-pointer list-none items-center justify-between gap-2 px-4 py-3 text-sm/6 font-medium text-zinc-950 sm:px-6">
                        <span class="flex items-center gap-2">
                          <span>Advanced</span>
                          <span class="text-xs/5 text-zinc-500">
                            signals · permissions · allowances · custom setup
                          </span>
                        </span>
                        <span class="text-xs/5 text-zinc-500 group-open:hidden">Open</span>
                        <span class="hidden text-xs/5 text-zinc-500 group-open:inline">Close</span>
                      </summary>
                      <div class="space-y-6 border-t border-zinc-950/10 px-4 py-5 sm:px-6">
                        <div class="grid grid-cols-1 gap-4 md:grid-cols-2">
                          <.field label="Template" for="launch_behavior">
                            <.c_select id="launch_behavior" name="launch[behavior]">
                              <%= for behavior <- behaviors() do %>
                                <option value={behavior} selected={behavior == @launch["behavior"]}>
                                  <%= behavior %>
                                </option>
                              <% end %>
                            </.c_select>
                          </.field>

                          <.field label="Name" for="launch_name">
                            <.c_input
                              id="launch_name"
                              type="text"
                              name="launch[name]"
                              value={@launch["name"]}
                              placeholder="optional display name"
                            />
                          </.field>
                        </div>

                        <div class="grid grid-cols-1 gap-4 md:grid-cols-2">
                          <.field label="Signals to watch" for="launch_subscriptions">
                            <.c_input
                              id="launch_subscriptions"
                              type="text"
                              name="launch[subscriptions]"
                              value={@launch["subscriptions"]}
                              placeholder="github:owner/repo,email:kent"
                            />
                          </.field>

                          <.field label="Allowed actions" for="launch_tools">
                            <.c_input
                              id="launch_tools"
                              type="text"
                              name="launch[tools]"
                              value={@launch["tools"]}
                              placeholder="read_file,search_files"
                            />
                          </.field>
                        </div>

                        <div class="grid grid-cols-1 gap-4 md:grid-cols-3">
                          <.field label="Recent context window" for="launch_memory_limit">
                            <.c_input
                              id="launch_memory_limit"
                              type="number"
                              min="1"
                              name="launch[memory_limit]"
                              value={@launch["memory_limit"]}
                            />
                          </.field>

                          <.field label="Reasoning allowance" for="launch_budget_llm_calls">
                            <.c_input
                              id="launch_budget_llm_calls"
                              type="number"
                              min="1"
                              name="launch[budget_llm_calls]"
                              value={@launch["budget_llm_calls"]}
                            />
                          </.field>

                          <.field label="Action allowance" for="launch_budget_tool_calls">
                            <.c_input
                              id="launch_budget_tool_calls"
                              type="number"
                              min="1"
                              name="launch[budget_tool_calls]"
                              value={@launch["budget_tool_calls"]}
                            />
                          </.field>
                        </div>

                        <.field label="Custom configuration" for="launch_config_json">
                          <.c_textarea
                            id="launch_config_json"
                            name="launch[config_json]"
                            rows={5}
                            class="font-mono"
                            placeholder={"{\"custom_key\":\"value\"}"}
                            value={@launch["config_json"]}
                          />
                        </.field>
                      </div>
                    </details>

                    <div class="flex justify-end">
                      <.button
                        type="submit"
                        phx-disable-with="Saving..."
                      >
                        Save changes
                      </.button>
                    </div>
                  </form>
                </div>
              <% else %>
                <div class={inspect_layout_class(@selected_agent)}>
                  <div class="space-y-6">
                    <%= if chief_of_staff_agent?(@selected_agent) do %>
                      <% schedule = morning_brief_schedule(@selected_agent) %>
                      <% skills = chief_skill_rows(@selected_agent) %>

                      <.panel :if={@selected_panel == :inspect} body_class="p-0">
                        <div class="px-5 py-5">
                          <div class="flex flex-wrap items-start justify-between gap-4">
                            <div>
                              <.heading level={3} class="text-base/7">Overview</.heading>
                              <.text class="mt-2 max-w-2xl">
                                A daily operating assistant for commitments, schedule changes, travel, projects, and personal reminders.
                              </.text>
                            </div>
                            <.badge color="emerald">
                              Active skills: <%= length(skills) %>
                            </.badge>
                          </div>
                        </div>
                        <div class="grid grid-cols-1 border-t border-zinc-950/10 text-sm sm:grid-cols-3">
                          <div class="border-b border-zinc-950/10 px-5 py-4 sm:border-b-0 sm:border-r">
                            <div class="text-xs/5 font-medium text-zinc-500">
                              Morning briefing
                            </div>
                            <div class="mt-2 text-2xl/8 font-semibold text-zinc-950">
                              <%= schedule.display_time_local %>
                            </div>
                            <div class="mt-1 text-xs/5 text-zinc-500"><%= schedule.local_timezone %></div>
                          </div>
                          <div class="border-b border-zinc-950/10 px-5 py-4 sm:border-b-0 sm:border-r">
                            <div class="text-xs/5 font-medium text-zinc-500">
                              Delivered by
                            </div>
                            <div class="mt-2 text-2xl/8 font-semibold text-zinc-950">Telegram</div>
                            <div class="mt-1 text-xs/5 text-zinc-500">sent from the Maraithon server</div>
                          </div>
                          <div class="px-5 py-4">
                            <div class="text-xs/5 font-medium text-zinc-500">
                              Sources
                            </div>
                            <div class="mt-2 flex flex-wrap gap-2">
                              <%= for source <- chief_source_labels() do %>
                                <.badge>
                                  <%= source %>
                                </.badge>
                              <% end %>
                            </div>
                          </div>
                        </div>
                      </.panel>

                      <%= if @selected_panel == :apps do %>
                        <% connected_rows = connected_app_account_rows(@current_user.id, @selected_agent) %>
                        <ul role="list" class="divide-y divide-zinc-950/5 overflow-hidden rounded-lg border border-zinc-950/10 bg-white">
                          <li
                            :for={row <- connected_rows}
                            class="grid grid-cols-1 gap-3 px-4 py-3 sm:px-6 lg:grid-cols-12 lg:items-start"
                          >
                            <div class="flex items-center gap-2 lg:col-span-3">
                              <img
                                src={connector_logo_src(row.logo_provider)}
                                alt={row.app}
                                class="size-5 shrink-0 object-contain"
                              />
                              <span class="truncate text-sm/6 font-semibold text-zinc-950">
                                <%= row.app %>
                              </span>
                            </div>

                            <div class="lg:col-span-3">
                              <p class="truncate text-sm/6 font-medium text-zinc-950">
                                <%= row.account %>
                              </p>
                              <p :if={row.note} class="mt-0.5 text-xs/5 text-zinc-500">
                                <%= row.note %>
                              </p>
                            </div>

                            <p class="text-sm/6 text-zinc-600 lg:col-span-4">
                              <%= row.access %>
                            </p>

                            <div class="flex flex-wrap items-center gap-3 lg:col-span-2 lg:justify-end">
                              <.badge
                                color={account_status_color(row.status)}
                                class="whitespace-nowrap"
                              >
                                <%= account_status_label(row.status) %>
                              </.badge>
                              <span class="whitespace-nowrap text-xs/5 text-zinc-500">
                                <%= format_datetime(row.updated_at) %>
                              </span>
                            </div>
                          </li>

                          <li
                            :if={connected_rows == []}
                            class="px-4 py-8 text-center text-sm/6 text-zinc-500 sm:px-6"
                          >
                            No connected accounts found for this automation yet.
                          </li>
                        </ul>
                      <% end %>

                      <.panel :if={@selected_panel == :skills} body_class="p-0">
                        <:header>
                          <.heading level={3} class="text-base/7">Attached Skills</.heading>
                          <.text class="mt-1">Each skill owns one clear job. Adjust the settings where the work happens.</.text>
                        </:header>
                        <div class="divide-y divide-zinc-950/5">
                          <%= for skill <- skills do %>
                            <div id={"chief-skill-#{skill.id}"} class="px-5 py-5">
                              <div class="flex flex-wrap items-start justify-between gap-4">
                                <div class="min-w-0">
                                  <div class="flex flex-wrap items-center gap-2">
                                    <h4 class="text-sm/6 font-medium text-zinc-950"><%= skill.label %></h4>
                                    <.badge>
                                      On
                                    </.badge>
                                  </div>
                                  <.text class="mt-2 max-w-2xl"><%= skill.description %></.text>
                                </div>

                                <%= if skill.id == "morning_briefing" do %>
                                  <form
                                    id="morning-brief-time-form"
                                    phx-submit="update_morning_brief_time"
                                    class="flex w-full flex-wrap items-end gap-3 rounded-lg border border-zinc-950/10 bg-zinc-50 px-4 py-4 sm:w-auto"
                                  >
                                    <.field label="Send each morning at" for="morning-brief-hour" class="min-w-44">
                                      <.c_select
                                        id="morning-brief-hour"
                                        name="schedule[local_hour]"
                                        class="min-w-32"
                                      >
                                        <option
                                          :for={option <- morning_brief_hour_options()}
                                          value={option.value}
                                          selected={option.value == schedule.hour}
                                        >
                                          <%= option.label %>
                                        </option>
                                      </.c_select>
                                    </.field>
                                    <.field label="Minute" for="morning-brief-minute" class="min-w-28">
                                      <.c_select
                                        id="morning-brief-minute"
                                        name="schedule[local_minute]"
                                        class="min-w-28"
                                      >
                                        <option
                                          :for={option <- morning_brief_minute_options()}
                                          value={option.value}
                                          selected={option.value == schedule.minute}
                                        >
                                          <%= option.label %>
                                        </option>
                                      </.c_select>
                                    </.field>
                                    <.button
                                      type="submit"
                                      phx-disable-with="Saving..."
                                      class="min-h-11 px-5"
                                    >
                                      Update time
                                    </.button>
                                    <div class="w-full text-xs/5 text-zinc-500">
                                      Uses <%= schedule.local_timezone %>. Sent by Telegram with Gmail, Calendar, Slack, and news context.
                                    </div>
                                  </form>
                                <% end %>
                              </div>
                            </div>
                          <% end %>
                        </div>
                      </.panel>
                    <% end %>

                    <%= if not chief_of_staff_agent?(@selected_agent) and @selected_panel == :inspect do %>
                    <div class="grid grid-cols-1 gap-4 sm:grid-cols-2 lg:grid-cols-3">
                      <.summary_card title="Started" value={format_datetime(@selected_agent.started_at)} />
                      <.summary_card title="Stopped" value={format_datetime(@selected_agent.stopped_at)} />
                      <.summary_card title="Signals to watch" value={subscriptions_preview(@selected_agent.config)} />
                      <.summary_card title="Allowed actions" value={tools_preview(@selected_agent.config)} />
                      <.summary_card title="Updates" value={to_string(@inspection.event_count)} />
                      <.summary_card title="Spend" value={"$#{Float.round(@agent_spend.total_cost, 4)}"} value_class="text-amber-700" />
                    </div>

                    <%= if @selected_architecture do %>
                      <.architecture_card architecture={@selected_architecture} mode="full" />
                    <% end %>

                    <div class="grid grid-cols-1 gap-4 lg:grid-cols-2">
                      <.panel class="bg-amber-50">
                        <.heading level={3} class="text-base/7 text-amber-950">Usage</.heading>
                        <dl class="mt-3 space-y-2 text-sm">
                          <div class="flex items-center justify-between gap-3">
                            <dt class="text-amber-700/80">Assistant work</dt>
                            <dd class="font-medium text-amber-950"><%= @agent_spend.llm_calls %></dd>
                          </div>
                          <div class="flex items-center justify-between gap-3">
                            <dt class="text-amber-700/80">Context processed</dt>
                            <dd class="font-medium text-amber-950"><%= @agent_spend.input_tokens %></dd>
                          </div>
                          <div class="flex items-center justify-between gap-3">
                            <dt class="text-amber-700/80">Response output</dt>
                            <dd class="font-medium text-amber-950"><%= @agent_spend.output_tokens %></dd>
                          </div>
                          <div class="flex items-center justify-between gap-3 border-t border-amber-200 pt-2">
                            <dt class="text-amber-700/80">Estimated spend</dt>
                            <dd class="font-semibold text-amber-950">
                              $<%= Float.round(@agent_spend.total_cost, 4) %>
                            </dd>
                          </div>
                        </dl>
                      </.panel>

                      <.panel class="bg-zinc-50">
                        <.heading level={3} class="text-base/7">Current settings</.heading>
                        <pre class="mt-3 overflow-x-auto whitespace-pre-wrap break-all text-xs/5 text-zinc-600"><%= pretty_config(@selected_agent.config) %></pre>
                      </.panel>
                    </div>

                    <.panel class="bg-zinc-50">
                      <.heading level={3} class="text-base/7">Instructions</.heading>
                      <p class="mt-3 whitespace-pre-wrap text-sm/6 text-zinc-700"><%= agent_prompt(@selected_agent.config) %></p>
                    </.panel>

                    <.panel>
                      <:header>
                        <.heading level={3} class="text-base/7">Work in progress</.heading>
                        <.text class="mt-1">
                          See what is waiting, running, or needs attention.
                        </.text>
                      </:header>
                      <div class="space-y-3">
                        <div class="grid grid-cols-3 gap-2 text-xs">
                          <.queue_metric title="Pending" value={@inspection.effect_counts.pending} />
                          <.queue_metric title="In progress" value={@inspection.effect_counts.claimed} />
                          <.queue_metric
                            title="Failed"
                            value={@inspection.effect_counts.failed}
                            value_class="text-rose-600"
                          />
                        </div>

                        <div class="max-h-80 space-y-2 overflow-y-auto">
                          <%= for effect <- @inspection.recent_effects do %>
                            <div class="rounded-lg border border-zinc-950/10 p-3">
                              <div class="flex items-center justify-between gap-3">
                                <div class="text-sm/6 font-medium text-zinc-950"><%= work_type_label(effect.effect_type) %></div>
                                <span class={effect_status_class(effect.status)}><%= humanize_status(effect.status) %></span>
                              </div>
                              <div class="mt-1 text-xs/5 text-zinc-500">
                                attempts <%= effect.attempts %>
                                <span class="mx-1">•</span>
                                updated <%= format_time(effect.updated_at) %>
                              </div>
                              <div class="mt-2 rounded-lg bg-zinc-50 px-2 py-1 text-xs/5 text-zinc-600">
                                <%= effect_preview(effect) %>
                              </div>
                            </div>
                          <% end %>

                          <%= if @inspection.recent_effects == [] do %>
                            <p class="text-sm/6 text-zinc-500">No queued work recorded yet.</p>
                          <% end %>
                        </div>
                      </div>
                    </.panel>

                    <.panel>
                      <:header>
                        <.heading level={3} class="text-base/7">Upcoming checks</.heading>
                        <.text class="mt-1">
                          Scheduled follow-ups and health checks for this automation.
                        </.text>
                      </:header>
                      <div class="space-y-3">
                        <div class="grid grid-cols-2 gap-2 text-xs">
                          <.queue_metric title="Pending" value={@inspection.job_counts.pending} />
                          <.queue_metric
                            title="In progress"
                            value={@inspection.job_counts.dispatched}
                            value_class="text-amber-600"
                          />
                          <.queue_metric title="Delivered" value={@inspection.job_counts.delivered} />
                          <.queue_metric title="Cancelled" value={@inspection.job_counts.cancelled} />
                        </div>

                        <div class="max-h-80 space-y-2 overflow-y-auto">
                          <%= for job <- @inspection.recent_jobs do %>
                            <div class="rounded-lg border border-zinc-950/10 p-3">
                              <div class="flex items-center justify-between gap-3">
                                <div class="text-sm/6 font-medium text-zinc-950"><%= work_type_label(job.job_type) %></div>
                                <span class={job_status_class(job.status)}><%= humanize_status(job.status) %></span>
                              </div>
                              <div class="mt-1 text-xs/5 text-zinc-500">
                                scheduled <%= format_datetime(job.fire_at) %>
                                <span class="mx-1">•</span>
                                attempts <%= job.attempts %>
                              </div>
                              <div class="mt-2 rounded-lg bg-zinc-50 px-2 py-1 text-xs/5 text-zinc-600">
                                <%= job_preview(job) %>
                              </div>
                            </div>
                          <% end %>

                          <%= if @inspection.recent_jobs == [] do %>
                            <p class="text-sm/6 text-zinc-500">No scheduled work recorded yet.</p>
                          <% end %>
                        </div>
                      </div>
                    </.panel>
                    <% end %>
                  </div>

                  <div :if={!chief_of_staff_agent?(@selected_agent)} class="space-y-6">
                    <.panel body_class="px-4 py-4">
                      <:header>
                        <.heading level={3} class="text-base/7">Recent updates</.heading>
                      </:header>
                      <div class="max-h-96 space-y-2 overflow-y-auto px-4 py-4">
                        <%= for event <- Enum.reverse(@events) do %>
                          <div class="rounded-lg border border-zinc-950/10 p-3 text-sm">
                            <div class="flex items-center justify-between gap-3">
                              <span class="font-medium text-cyan-700"><%= work_type_label(event.event_type) %></span>
                            </div>
                            <div class="mt-1 text-xs/5 text-zinc-500"><%= format_datetime(event.created_at) %></div>
                            <div class="mt-2 rounded-lg bg-zinc-50 px-2 py-1 text-xs/5 text-zinc-600">
                              <%= event_preview(event) %>
                            </div>
                          </div>
                        <% end %>

                        <%= if @events == [] do %>
                          <p class="text-sm/6 text-zinc-500">No updates yet.</p>
                        <% end %>
                      </div>
                    </.panel>

                    <section class="overflow-hidden rounded-lg border border-zinc-950 bg-zinc-950 shadow-sm">
                      <div class="border-b border-white/10 px-4 py-4">
                        <h3 class="text-base/7 font-semibold text-white">Automation notes</h3>
                        <p class="mt-1 text-sm/6 text-zinc-400">
                          Recent automation notes. Sensitive diagnostic details are hidden from this view.
                        </p>
                      </div>
                      <div class="max-h-[32rem] overflow-y-auto px-4 py-4 font-mono text-[11px] leading-5">
                        <%= for log <- @inspection.recent_logs do %>
                          <div class="grid grid-cols-[auto_auto_1fr] gap-3 border-b border-white/10 py-2">
                            <span class="text-zinc-500"><%= format_log_timestamp(log.timestamp) %></span>
                            <span class={["font-semibold", log_level_class(log.level)]}>
                              <%= log.level %>
                            </span>
                            <div class="min-w-0">
                              <span class="break-words whitespace-pre-wrap text-zinc-100"><%= log_message_preview(log.message) %></span>
                            </div>
                          </div>
                        <% end %>

                        <%= if @inspection.recent_logs == [] do %>
                          <p class="text-sm/6 text-zinc-500">No automation notes captured yet.</p>
                        <% end %>
                      </div>
                    </section>
                  </div>

                  <details
                    :if={chief_of_staff_agent?(@selected_agent)}
                    class="rounded-lg border border-zinc-950/10 bg-white px-5 py-4 shadow-sm"
                  >
                    <summary class="cursor-pointer list-none">
                      <div class="flex flex-wrap items-center justify-between gap-3">
                        <div>
                          <h3 class="text-base/7 font-semibold text-zinc-950">Advanced diagnostics</h3>
                          <p class="mt-1 text-sm/6 text-zinc-500">Technical details for troubleshooting, billing, and support.</p>
                        </div>
                        <span class="text-sm/6 font-medium text-zinc-500">Show</span>
                      </div>
                    </summary>

                    <div class="mt-5 grid grid-cols-1 gap-4 sm:grid-cols-2 lg:grid-cols-4">
                      <.summary_card title="Started" value={format_datetime(@selected_agent.started_at)} />
                      <.summary_card title="Last Updated" value={format_datetime(agent_updated_at(@selected_agent))} />
                      <.summary_card title="Updates" value={to_string(@inspection.event_count)} />
                      <.summary_card
                        title="Spend"
                        value={"$#{Float.round(@agent_spend.total_cost, 4)}"}
                        value_class="text-amber-700"
                      />
                    </div>

                    <div class="mt-4 rounded-lg border border-zinc-950/10 bg-zinc-50 p-4">
                      <div class="text-xs/5 font-medium text-zinc-500">
                        Automation id
                      </div>
                      <p class="mt-2 break-all font-mono text-xs/5 text-zinc-600"><%= @selected_agent.id %></p>
                    </div>
                  </details>
                </div>
              <% end %>
            </div>
          <% end %>
        </.panel>
      </div>
    </Layouts.app>
    """
  end

  attr :title, :string, required: true
  attr :value, :string, required: true
  attr :value_class, :string, default: "text-zinc-950"

  defp summary_card(assigns) do
    ~H"""
    <div class="rounded-lg border border-zinc-950/10 bg-zinc-50 p-4">
      <dt class="text-xs/5 font-medium text-zinc-500"><%= @title %></dt>
      <dd class={"mt-2 text-sm font-medium #{@value_class}"}><%= @value %></dd>
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

  defp apply_selection(socket, nil, _panel, raw_panel) when is_binary(raw_panel) do
    {:sanitize, clear_selection(socket), filters_path(socket), nil}
  end

  defp apply_selection(socket, nil, _panel, _raw_panel) do
    {:ok, clear_selection(socket)}
  end

  defp apply_selection(socket, id, panel, _raw_panel) do
    case Agents.get_agent_for_user(id, current_user_id(socket), preload: agent_display_preloads()) do
      nil ->
        {:sanitize, clear_selection(socket), filters_path(socket),
         {:error, "Automation not found"}}

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
           selected_agent: preload_agent_display_data(snapshot.agent),
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
        {:sanitize, clear_selection(socket), filters_path(socket),
         {:error, "Automation not found"}}
    end
  end

  defp refresh_registry(socket) do
    user_id = current_user_id(socket)
    agents = Agents.list_agents(user_id: user_id, preload: agent_display_preloads())
    filtered_agents = filter_agents(agents, socket.assigns.filters)
    provider_status = library_provider_status(user_id)
    {library, marketplace_error} = marketplace_library(user_id)

    assign(socket,
      all_agents: agents,
      agents: filtered_agents,
      library: library,
      marketplace_error: marketplace_error,
      provider_status: provider_status
    )
  end

  defp library_provider_status(nil), do: %{}

  defp library_provider_status(user_id) do
    case connection_snapshot(user_id) do
      %{providers: providers} when is_list(providers) ->
        providers
        |> Enum.map(fn provider ->
          {to_string(provider.provider), Map.get(provider, :status, :not_configured)}
        end)
        |> Map.new()

      _ ->
        %{}
    end
  end

  defp library_readiness(spec, provider_status) do
    providers =
      (spec.requirements || [])
      |> Enum.filter(&connector_requirement?/1)
      |> Enum.filter(& &1[:required?])
      |> Enum.map(& &1.provider)
      |> Enum.uniq()

    case providers do
      [] ->
        %{label: "Ready to install", connected: 0, total: 0}

      list ->
        connected =
          Enum.count(list, fn provider ->
            Map.get(provider_status, provider, :not_configured) == :connected
          end)

        %{
          label:
            cond do
              connected == length(list) -> "All connectors ready"
              connected > 0 -> "#{connected} of #{length(list)} ready"
              true -> "Connect required apps"
            end,
          connected: connected,
          total: length(list)
        }
    end
  end

  defp refresh_selected_workspace(socket) do
    case socket.assigns.selected_agent_id do
      nil ->
        {:ok, socket}

      id ->
        case Agents.get_agent_for_user(id, current_user_id(socket),
               preload: agent_display_preloads()
             ) do
          nil ->
            {:sanitize, clear_selection(socket), filters_path(socket),
             {:error, "Automation not found"}}

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
  defp normalize_panel("apps"), do: :apps
  defp normalize_panel("skills"), do: :skills
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
  defp panel_param(:apps), do: "apps"
  defp panel_param(:skills), do: "skills"
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
  defp humanize_status("running"), do: "Active"
  defp humanize_status("degraded"), do: "Needs attention"
  defp humanize_status("stopped"), do: "Paused"
  defp humanize_status(status), do: status |> String.replace("_", " ") |> String.capitalize()

  defp work_type_label("tool_call"), do: "Action"
  defp work_type_label("llm_call"), do: "Reasoning"
  defp work_type_label("heartbeat"), do: "Heartbeat"
  defp work_type_label("inspection_ready"), do: "Inspection ready"

  defp work_type_label(type) when is_binary(type) do
    type
    |> String.replace("_", " ")
    |> String.split()
    |> Enum.map_join(" ", &String.capitalize/1)
  end

  defp work_type_label(_type), do: "Work"

  defp row_class(selected_agent_id, agent_id) when selected_agent_id == agent_id,
    do:
      "cursor-pointer bg-blue-50/70 transition hover:bg-blue-50 focus:outline-none focus:ring-2 focus:ring-inset focus:ring-blue-500"

  defp row_class(_selected_agent_id, _agent_id),
    do:
      "cursor-pointer transition hover:bg-zinc-950/[0.025] focus:outline-none focus:ring-2 focus:ring-inset focus:ring-blue-500"

  defp inspect_layout_class(agent) do
    if chief_of_staff_agent?(agent) do
      "space-y-6"
    else
      "grid grid-cols-1 gap-6 xl:grid-cols-[minmax(0,1.1fr)_minmax(0,0.9fr)]"
    end
  end

  defp workspace_tab_class(true),
    do:
      "inline-flex items-center border-b-2 border-zinc-950 px-1 pb-2 text-sm/6 font-medium text-zinc-950"

  defp workspace_tab_class(false),
    do:
      "inline-flex items-center border-b-2 border-transparent px-1 pb-2 text-sm/6 font-medium text-zinc-500 hover:text-zinc-950"

  defp behaviors do
    AgentBuilder.behavior_specs()
    |> Enum.map(& &1.id)
    |> Enum.sort()
  end

  defp marketplace_library(user_id) do
    case AgentMarketplace.sync_builtin_packages() do
      {:ok, _packages} ->
        library =
          user_id
          |> Agents.list_marketplace_packages()
          |> Enum.map(&marketplace_entry_to_spec/1)

        {library, nil}

      {:error, reason} ->
        {[], AgentActionCopy.marketplace_error(reason)}
    end
  end

  defp marketplace_entry_to_spec(%{package: package, installation: installation}) do
    behavior = package_behavior(package)
    spec = package_behavior_spec(behavior, package)

    spec
    |> Map.put(:id, package.slug)
    |> Map.put(:label, package.name)
    |> Map.put(:summary, package.summary || spec.summary)
    |> Map.put(:category, package.category || spec.category)
    |> Map.put(:installed?, not is_nil(installation))
    |> Map.put(:installed_agent_id, installation && installation.id)
  end

  defp package_behavior(%{latest_version: %{behavior: behavior}}) when is_binary(behavior),
    do: behavior

  defp package_behavior(%{slug: slug}), do: slug

  defp package_behavior_spec("manifest_agent", package) do
    %{
      id: package.slug,
      label: package.name,
      category: package.category || "Marketplace",
      summary:
        package.summary ||
          "A package-defined automation assembled from a manifest and markdown skills.",
      requirements: package_requirements(package),
      fields: [],
      simple_fields: [],
      defaults: %{},
      suggestions: []
    }
  end

  defp package_behavior_spec(behavior, _package), do: AgentBuilder.behavior_spec(behavior)

  defp package_requirements(%{latest_version: %{required_connectors: connectors}})
       when is_map(connectors) do
    requirements_from_connector_map(connectors)
  end

  defp package_requirements(_package), do: []

  defp requirements_from_connector_map(connectors) when is_map(connectors) do
    connectors
    |> Enum.flat_map(fn {provider, requirements} ->
      requirements
      |> List.wrap()
      |> Enum.map(fn requirement ->
        %{
          kind: :provider,
          provider: provider,
          label: Map.get(requirement, "label") || provider,
          required?: true
        }
      end)
    end)
  end

  defp requirements_from_connector_map(_connectors), do: []

  defp ensure_marketplace_package(behavior_id) when is_binary(behavior_id) do
    _ = AgentMarketplace.sync_builtin_packages()
    Agents.get_agent_package_by_slug(behavior_id, preload: [:latest_version])
  end

  defp ensure_marketplace_package(_behavior_id), do: nil

  defp install_library_package(user_id, "ai_chief_of_staff") do
    Runtime.install_chief_of_staff(user_id)
  end

  defp install_library_package(user_id, slug) do
    Runtime.install_agent_package(user_id, slug)
  end

  defp remove_or_delete_agent(%{agent_package_id: package_id}, id)
       when is_binary(package_id) do
    {:remove, "Automation removed", Runtime.remove_agent_installation(id)}
  end

  defp remove_or_delete_agent(_agent, id) do
    {:delete, "Automation deleted", Runtime.delete_agent(id)}
  end

  defp agent_display_preloads do
    [:project, :agent_package_version, agent_package: [:latest_version]]
  end

  defp preload_agent_display_data(nil), do: nil

  defp preload_agent_display_data(agent) do
    Agents.get_agent(agent.id, preload: agent_display_preloads()) || agent
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
        label: ChiefOfStaffSkills.label(id),
        description: ChiefOfStaffSkills.description(id)
      }
    end)
  end

  defp chief_skill_rows(_agent), do: []

  defp chief_source_labels, do: ["Gmail", "Calendar", "Slack", "News"]

  defp morning_brief_schedule(%{config: config}) when is_map(config) do
    hour = config |> Map.get("morning_brief_hour_local") |> parse_integer(8) |> clamp_hour()
    minute = config |> Map.get("morning_brief_minute_local") |> parse_integer(0) |> clamp_minute()
    timezone_offset = config |> Map.get("timezone_offset_hours") |> parse_integer(-5)

    %{
      hour: hour,
      minute: minute,
      display_time_local: display_time(hour, minute),
      local_timezone: timezone_label(timezone_offset)
    }
  end

  defp morning_brief_schedule(_agent) do
    %{hour: 8, minute: 0, display_time_local: "8:00 AM", local_timezone: "UTC-05:00"}
  end

  defp morning_brief_hour_options do
    Enum.map(0..23, fn hour ->
      %{value: hour, label: display_hour(hour)}
    end)
  end

  defp morning_brief_minute_options do
    [0, 15, 30, 45]
    |> Enum.map(fn minute ->
      %{value: minute, label: minute |> Integer.to_string() |> String.pad_leading(2, "0")}
    end)
  end

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

  defp clamp_minute(minute) when minute < 0, do: 0
  defp clamp_minute(minute) when minute > 59, do: 59
  defp clamp_minute(minute), do: minute

  defp display_hour(hour) when is_integer(hour) do
    display_time(hour, 0)
  end

  defp display_time(hour, minute) when is_integer(hour) and is_integer(minute) do
    suffix = if hour < 12, do: "AM", else: "PM"
    display_hour = rem(hour, 12)
    display_hour = if display_hour == 0, do: 12, else: display_hour

    "#{display_hour}:#{minute |> Integer.to_string() |> String.pad_leading(2, "0")} #{suffix}"
  end

  defp timezone_label(offset) when is_integer(offset) do
    sign = if offset < 0, do: "-", else: "+"
    hours = offset |> abs() |> Integer.to_string() |> String.pad_leading(2, "0")

    "UTC#{sign}#{hours}:00"
  end

  defp agent_prompt(config),
    do: config["prompt"] || AgentBuilder.default_launch_params()["prompt"]

  defp pretty_config(config) when is_map(config) do
    config
    |> display_config()
    |> Jason.encode!(pretty: true)
  rescue
    _ -> inspect(config, pretty: true, limit: :infinity)
  end

  defp pretty_config(config), do: inspect(config, pretty: true, limit: :infinity)

  defp display_config(config) when is_map(config) do
    config
    |> Enum.map(fn {key, value} -> {display_config_key(key), display_config(value)} end)
    |> Map.new()
  end

  defp display_config(value) when is_list(value), do: Enum.map(value, &display_config/1)
  defp display_config(value), do: value

  defp display_config_key("tools"), do: "actions"
  defp display_config_key("tool_calls"), do: "action_runs"
  defp display_config_key("budget_tool_calls"), do: "action_budget"
  defp display_config_key("tool_allowlist"), do: "action_allowlist"
  defp display_config_key("llm_calls"), do: "reasoning_runs"
  defp display_config_key("budget_llm_calls"), do: "reasoning_budget"
  defp display_config_key(:tools), do: "actions"
  defp display_config_key(:tool_calls), do: "action_runs"
  defp display_config_key(:budget_tool_calls), do: "action_budget"
  defp display_config_key(:tool_allowlist), do: "action_allowlist"
  defp display_config_key(:llm_calls), do: "reasoning_runs"
  defp display_config_key(:budget_llm_calls), do: "reasoning_budget"
  defp display_config_key(key), do: key

  defp subscriptions_preview(config) do
    case config["subscribe"] || [] do
      [] -> "No subscriptions"
      values -> values |> Enum.take(3) |> Enum.join(", ") |> truncate(70)
    end
  end

  defp tools_preview(config) do
    case config["tools"] || [] do
      [] -> "No actions"
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
    |> Map.get(:summary, "Runs the saved automation behavior for this operator.")
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

  defp library_connector_logos(spec) do
    (spec.requirements || [])
    |> Enum.filter(&connector_requirement?/1)
    |> Enum.map(& &1.provider)
    |> Enum.map(&connector_logo_provider/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.take(5)
  end

  defp library_requirement_summary(%{requirements: []}), do: "No connected apps required."

  defp library_requirement_summary(%{requirements: requirements}) do
    labels =
      requirements
      |> Enum.filter(& &1[:required?])
      |> Enum.map(& &1.label)
      |> Enum.uniq()

    case labels do
      [] -> "Optional connectors only."
      list -> "Needs " <> Enum.join(list, ", ")
    end
  end

  defp library_requirement_summary(_spec), do: ""

  defp behavior_spec(agent) do
    case package_version_for_agent(agent) do
      %AgentPackageVersion{} = version ->
        package_behavior_spec_from_version(agent, version)

      _ ->
        AgentBuilder.behavior_spec(agent.behavior)
    end
  end

  defp package_version_for_agent(%{agent_package_version: %AgentPackageVersion{} = version}),
    do: version

  defp package_version_for_agent(%{agent_package_version_id: id}) when is_binary(id),
    do: Agents.get_agent_package_version(id)

  defp package_version_for_agent(_agent), do: nil

  defp package_behavior_spec_from_version(agent, %AgentPackageVersion{} = version) do
    base = behavior_spec_base(version.behavior)
    package = loaded_package(agent)

    requirements =
      case requirements_from_connector_map(version.required_connectors || %{}) do
        [] -> Map.get(base, :requirements, [])
        values -> values
      end

    base
    |> Map.put(:id, version.behavior)
    |> Map.put(:label, package_label(package, base.label))
    |> Map.put(:category, package_category(package, base.category))
    |> Map.put(:summary, package_summary(package, base.summary))
    |> Map.put(:requirements, requirements)
  end

  defp behavior_spec_base("manifest_agent") do
    %{
      id: "manifest_agent",
      label: "Manifest automation",
      category: "Marketplace",
      summary: "Runs from an installed package manifest and markdown skills.",
      requirements: [],
      fields: [],
      simple_fields: [],
      defaults: %{},
      suggestions: []
    }
  end

  defp behavior_spec_base(behavior), do: AgentBuilder.behavior_spec(behavior)

  defp loaded_package(%{agent_package: %AgentPackage{} = package}), do: package
  defp loaded_package(_agent), do: nil

  defp package_label(%AgentPackage{name: name}, _fallback) when is_binary(name) and name != "",
    do: name

  defp package_label(_package, fallback), do: fallback

  defp package_category(%AgentPackage{category: category}, _fallback)
       when is_binary(category) and category != "",
       do: category

  defp package_category(_package, fallback), do: fallback

  defp package_summary(%AgentPackage{summary: summary}, _fallback)
       when is_binary(summary) and summary != "",
       do: summary

  defp package_summary(_package, fallback), do: fallback

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

    %{
      logo_provider: "telegram",
      app: Map.get(provider, :label) || "Telegram",
      account: if(username, do: "@#{username}", else: "Telegram chat"),
      note: "Telegram delivery linked",
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

  defp inspection_error_detail(%{details: details}) do
    safe_product_detail(details, "Refresh this view in a moment.")
  end

  defp inspection_error_detail(_error), do: "Refresh this view in a moment."

  defp effect_preview(effect) do
    cond do
      is_binary(effect.error) and effect.error != "" ->
        run_error_label(effect.error)

      effect.status == "completed" ->
        completed_effect_preview(effect)

      effect.status == "claimed" ->
        "In progress."

      effect.status == "pending" ->
        pending_effect_preview(effect)

      true ->
        "Status will update shortly."
    end
  end

  defp completed_effect_preview(%{effect_type: "tool_call", params: params}) do
    "Completed #{action_name(params)}."
  end

  defp completed_effect_preview(%{effect_type: "llm_call"}), do: "Reasoning step completed."
  defp completed_effect_preview(_effect), do: "Finished successfully."

  defp pending_effect_preview(%{effect_type: "tool_call", params: params}) do
    "Waiting to run #{action_name(params)}."
  end

  defp pending_effect_preview(%{effect_type: "llm_call"}),
    do: "Waiting for the next reasoning step."

  defp pending_effect_preview(_effect), do: "Waiting to run."

  defp action_name(params) when is_map(params) do
    case params["tool"] || params[:tool] do
      tool when is_binary(tool) and tool != "" -> work_type_label(tool)
      _ -> "an action"
    end
  end

  defp action_name(_params), do: "an action"

  defp job_preview(%{job_type: "heartbeat"}), do: "Keeps the automation available."
  defp job_preview(%{job_type: "checkpoint"}), do: "Saves the automation's latest progress."
  defp job_preview(%{job_type: "wakeup"}), do: "Next scheduled check-in."
  defp job_preview(_job), do: "Scheduled follow-up."

  defp event_preview(%{payload: payload}) when is_map(payload) do
    payload
    |> Map.get(:message, Map.get(payload, "message"))
    |> safe_product_detail("Recorded automation activity.")
  end

  defp event_preview(_event), do: "Recorded automation activity."

  defp run_error_label(error) do
    error
    |> then(&RunErrorCopy.runtime_failure(%{source: "effect", details: &1}))
    |> String.replace("Effect", "Action")
    |> String.replace("Operation", "Action")
  end

  defp effect_status_class("failed"),
    do: "inline-flex rounded-md bg-rose-400/15 px-1.5 py-0.5 text-xs/5 font-medium text-rose-700"

  defp effect_status_class("completed"),
    do:
      "inline-flex rounded-md bg-emerald-500/15 px-1.5 py-0.5 text-xs/5 font-medium text-emerald-700"

  defp effect_status_class("claimed"),
    do:
      "inline-flex rounded-md bg-amber-400/20 px-1.5 py-0.5 text-xs/5 font-medium text-amber-700"

  defp effect_status_class(_status),
    do: "inline-flex rounded-md bg-zinc-600/10 px-1.5 py-0.5 text-xs/5 font-medium text-zinc-700"

  defp job_status_class("cancelled"),
    do: "inline-flex rounded-md bg-rose-400/15 px-1.5 py-0.5 text-xs/5 font-medium text-rose-700"

  defp job_status_class("delivered"),
    do:
      "inline-flex rounded-md bg-emerald-500/15 px-1.5 py-0.5 text-xs/5 font-medium text-emerald-700"

  defp job_status_class("dispatched"),
    do:
      "inline-flex rounded-md bg-amber-400/20 px-1.5 py-0.5 text-xs/5 font-medium text-amber-700"

  defp job_status_class(_status),
    do: "inline-flex rounded-md bg-zinc-600/10 px-1.5 py-0.5 text-xs/5 font-medium text-zinc-700"

  defp log_message_preview(message) when is_binary(message) do
    safe_product_detail(message, "Diagnostic details are hidden from this view.")
  end

  defp log_message_preview(_message), do: "Diagnostic details are hidden from this view."

  defp safe_product_detail(value, fallback) when is_binary(value) do
    trimmed = String.trim(value)

    cond do
      trimmed == "" -> fallback
      technical_detail?(trimmed) -> fallback
      true -> truncate(trimmed, 180)
    end
  end

  defp safe_product_detail(_value, fallback), do: fallback

  defp technical_detail?(value) do
    lower = String.downcase(value)

    String.contains?(lower, [
      "dbconnection",
      "ecto.",
      "http_status",
      "internal",
      "nsurlerrordomain",
      "oauth",
      "postgrex",
      "stacktrace",
      "token=",
      "traceback"
    ]) or String.contains?(value, ["{", "}", "=>", "#PID<"])
  end

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
      _ -> "text-zinc-300"
    end
  end

  defp log_level_class(_level), do: "text-zinc-300"

  defp format_time(nil), do: "No timestamp"

  defp format_time(datetime) when is_binary(datetime) do
    case DateTime.from_iso8601(datetime) do
      {:ok, dt, _offset} -> format_time(dt)
      _ -> datetime
    end
  end

  defp format_time(%DateTime{} = dt), do: Calendar.strftime(dt, "%H:%M:%S")
  defp format_time(%NaiveDateTime{} = dt), do: Calendar.strftime(dt, "%H:%M:%S")

  defp format_datetime(nil), do: "No timestamp"

  defp format_datetime(datetime) when is_binary(datetime) do
    case DateTime.from_iso8601(datetime) do
      {:ok, dt, _offset} -> format_datetime(dt)
      _ -> datetime
    end
  end

  defp format_datetime(%DateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S UTC")
  defp format_datetime(%NaiveDateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S")
end
