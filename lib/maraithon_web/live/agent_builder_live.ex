defmodule MaraithonWeb.AgentBuilderLive do
  use MaraithonWeb, :live_view

  alias Maraithon.AgentArchitecture
  alias Maraithon.AgentBuilder
  alias Maraithon.Connections
  alias Maraithon.Projects
  alias Maraithon.Runtime
  alias Maraithon.Runtime.Config, as: RuntimeConfig
  alias Maraithon.Timezones
  alias MaraithonWeb.AgentActionCopy

  @tool_provider_requirements %{
    "gmail_get_message" => %{provider: "google", service: "gmail", label: "Gmail"},
    "gmail_list_recent" => %{provider: "google", service: "gmail", label: "Gmail"},
    "gmail_search" => %{provider: "google", service: "gmail", label: "Gmail"},
    "google_calendar_list_events" => %{
      provider: "google",
      service: "calendar",
      label: "Google Calendar"
    },
    "github_create_issue_comment" => %{provider: "github", label: "GitHub"},
    "slack_post_message" => %{provider: "slack", service: "channels", label: "Slack Channels"},
    "slack_list_conversations" => %{
      provider: "slack",
      service: "channels",
      label: "Slack Channels"
    },
    "slack_list_messages" => %{provider: "slack", service: "channels", label: "Slack Channels"},
    "slack_get_thread_replies" => %{
      provider: "slack",
      service: "channels",
      label: "Slack Channels"
    },
    "slack_search_messages" => %{provider: "slack", service: "dms", label: "Slack DMs"},
    "linear_create_comment" => %{provider: "linear", label: "Linear"},
    "linear_create_issue" => %{provider: "linear", label: "Linear"},
    "linear_update_issue_state" => %{provider: "linear", label: "Linear"}
  }

  @path_tools MapSet.new(["file_tree", "list_files", "read_file", "search_files"])

  @impl true
  def mount(_params, _session, socket) do
    user_id = current_user_id(socket)
    {providers, connection_errors} = load_providers(user_id)
    launch = AgentBuilder.default_launch_params()
    projects = Projects.list_projects(user_id: user_id)

    socket =
      socket
      |> assign(
        page_title: "New automation",
        current_path: "/agents/new",
        behavior_specs: AgentBuilder.library_specs(),
        cost_profile_options: AgentBuilder.cost_profile_options(),
        provider_map: providers,
        connection_errors: connection_errors,
        projects: projects,
        tool_allowed_paths: RuntimeConfig.tool_allowed_paths(),
        builder_error: nil,
        builder_mode: "simple"
      )
      |> assign_builder_state(launch)

    {:ok, socket}
  end

  @impl true
  def handle_params(params, uri, socket) do
    behavior = Map.get(params, "behavior")
    requested_project_id = Map.get(params, "project_id")
    current_behavior = socket.assigns.launch["behavior"]
    builder_mode = socket.assigns[:builder_mode] || "simple"

    launch =
      cond do
        is_binary(behavior) and behavior != current_behavior ->
          behavior
          |> AgentBuilder.launch_params_for_behavior()
          |> Map.put("builder_mode", builder_mode)
          |> AgentBuilder.normalize_launch_params()

        true ->
          socket.assigns.launch
      end

    launch =
      case requested_project_id do
        value when is_binary(value) and value != "" -> Map.put(launch, "project_id", value)
        _ -> launch
      end

    {:noreply,
     socket
     |> assign(:current_path, current_path_from_uri(uri))
     |> assign(:builder_error, nil)
     |> assign_builder_state(launch)}
  end

  @impl true
  def handle_event("choose_behavior", %{"behavior" => behavior}, socket) do
    {:noreply, push_patch(socket, to: ~p"/agents/new?behavior=#{behavior}")}
  end

  def handle_event("set_builder_mode", %{"mode" => mode}, socket)
      when mode in ["simple", "advanced"] do
    launch =
      socket.assigns.launch
      |> Map.put("builder_mode", mode)
      |> AgentBuilder.normalize_launch_params()

    {:noreply,
     socket
     |> assign(:builder_mode, mode)
     |> assign_builder_state(launch)}
  end

  def handle_event("update_launch", %{"launch" => params}, socket) do
    launch = AgentBuilder.normalize_launch_params(params)
    {:noreply, socket |> assign(:builder_error, nil) |> assign_builder_state(launch)}
  end

  def handle_event("create_agent", %{"launch" => params}, socket) do
    launch = AgentBuilder.normalize_launch_params(params)
    blockers = launch_blockers(launch, socket)

    with [] <- blockers,
         {:ok, start_params} <- AgentBuilder.build_start_params(launch, current_user_id(socket)),
         {:ok, agent} <- Runtime.start_agent(start_params) do
      {:noreply,
       socket
       |> put_flash(:info, "Automation created")
       |> push_navigate(to: "/agents?id=#{agent.id}")}
    else
      [_ | _] = blocking_items ->
        {:noreply,
         socket
         |> assign_builder_state(launch)
         |> assign(:builder_error, blocker_message(blocking_items))}

      {:error, message} when is_binary(message) ->
        {:noreply,
         socket
         |> assign_builder_state(launch)
         |> assign(:builder_error, message)}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply,
         socket
         |> assign_builder_state(launch)
         |> assign(:builder_error, AgentActionCopy.error(:create, changeset))}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign_builder_state(launch)
         |> assign(:builder_error, AgentActionCopy.error(:create, reason))}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_path={@current_path} current_user={@current_user}>
      <div class="space-y-5">
        <header class="flex flex-wrap items-end justify-between gap-3">
          <div class="min-w-0">
            <.link
              navigate={~p"/agents"}
              class="inline-flex items-center gap-1 text-xs/5 font-medium text-zinc-500 hover:text-zinc-950"
            >
              <span aria-hidden="true">←</span> Automations
            </.link>
            <h1 class="mt-1 text-2xl/8 font-semibold tracking-tight text-zinc-950 sm:text-xl/8">
              New automation
            </h1>
            <p class="mt-1 max-w-2xl text-sm/6 text-zinc-500">
              Pick the job, confirm the connected apps it can use, then launch.
            </p>
          </div>
        </header>

        <%= if @builder_error do %>
          <.alert color="rose">
            <%= @builder_error %>
          </.alert>
        <% end %>

        <%= if @connection_errors != [] do %>
          <.alert color="amber" title="Permission readiness could not be fully verified.">
            <p>
              Connector status is temporarily degraded, so the builder is showing best-effort guidance.
            </p>
          </.alert>
        <% end %>

        <div class="grid grid-cols-1 gap-5 xl:grid-cols-[minmax(0,1.55fr)_minmax(340px,0.9fr)]">
          <div class="space-y-5">
            <section class="overflow-hidden rounded-lg border border-zinc-950/10 bg-white shadow-sm">
              <div class="border-b border-zinc-950/10 px-5 py-4">
                <h2 class="text-base font-semibold text-zinc-950">Template</h2>
                <p class="mt-1 text-sm text-zinc-500">
                  Pick the outcome you want. Each row shows the work it will do and the apps it needs.
                </p>
              </div>

              <div class="divide-y divide-zinc-950/5">
                <button
                  :for={spec <- @behavior_specs}
                  type="button"
                  phx-click="choose_behavior"
                  phx-value-behavior={spec.id}
                  class={behavior_card_class(@selected_spec.id == spec.id)}
                >
                  <span class={behavior_indicator_class(@selected_spec.id == spec.id)}></span>
                  <span class="min-w-0 flex-1">
                    <span class="flex flex-wrap items-center gap-2">
                      <span class="text-sm font-semibold text-zinc-950"><%= spec.label %></span>
                      <span class="rounded-md bg-zinc-100 px-2 py-0.5 text-xs font-medium text-zinc-600">
                        <%= spec.category %>
                      </span>
                    </span>
                    <span class="mt-1 block text-sm leading-6 text-zinc-600"><%= spec.summary %></span>
                    <span class="mt-2 block text-xs text-zinc-500">
                      <%= spec_requirement_summary(spec) %>
                    </span>
                  </span>
                  <span class="shrink-0 text-xs font-medium text-zinc-500">
                    <%= if @selected_spec.id == spec.id, do: "Selected", else: "Choose" %>
                  </span>
                </button>
              </div>
            </section>

            <section class="overflow-hidden rounded-lg border border-zinc-950/10 bg-white shadow-sm">
              <div class="border-b border-zinc-950/10 px-5 py-4">
                <div class="flex flex-wrap items-center justify-between gap-3">
                  <div>
                    <h2 class="text-base font-semibold text-zinc-950">Launch details</h2>
                    <p class="mt-1 text-sm text-zinc-500">
                      Choose the essentials. Advanced keeps detailed controls available when you need them.
                    </p>
                  </div>
                  <div class="inline-flex rounded-lg border border-zinc-950/10 bg-zinc-50 p-1">
                    <button
                      type="button"
                      phx-click="set_builder_mode"
                      phx-value-mode="simple"
                      class={builder_mode_button_class(@builder_mode == "simple")}
                    >
                      Simple
                    </button>
                    <button
                      type="button"
                      phx-click="set_builder_mode"
                      phx-value-mode="advanced"
                      class={builder_mode_button_class(@builder_mode == "advanced")}
                    >
                      Advanced
                    </button>
                  </div>
                </div>
              </div>

              <form id="agent-builder-form" phx-change="update_launch" phx-submit="create_agent" class="space-y-5 px-5 py-5">
                <input type="hidden" name="launch[behavior]" value={@launch["behavior"]} />
                <input type="hidden" name="launch[builder_mode]" value={@builder_mode} />
                <input :for={field <- @hidden_fields} type="hidden" name={"launch[#{field}]"} value={Map.get(@launch, field, "")} />
                <%= if @builder_mode != "advanced" do %>
                  <input type="hidden" name="launch[budget_llm_calls]" value={@launch["budget_llm_calls"]} />
                  <input type="hidden" name="launch[budget_tool_calls]" value={@launch["budget_tool_calls"]} />
                  <input type="hidden" name="launch[config_json]" value={@launch["config_json"]} />
                <% end %>

                <%= if @builder_mode == "simple" do %>
                  <div class="rounded-lg border border-sky-200 bg-sky-50 px-4 py-3 text-sm text-sky-950">
                    <p class="font-medium">Focused launch</p>
                    <p class="mt-1 text-sky-900/80">
                      Set the name, scope, and coverage. Detailed controls stay on sensible defaults unless you open Advanced.
                    </p>
                  </div>
                <% end %>

                <div class="grid grid-cols-1 gap-4 md:grid-cols-[minmax(0,1fr)_minmax(260px,0.8fr)]">
                  <div>
                    <label for="launch_name" class="block text-sm font-medium text-zinc-700">
                      Automation name
                    </label>
                    <input
                      id="launch_name"
                      type="text"
                      name="launch[name]"
                      value={@launch["name"]}
                      placeholder="Optional display name"
                      class="mt-1 block w-full rounded-lg border border-zinc-300 px-3 py-2 text-sm text-zinc-950 shadow-sm focus:border-indigo-500 focus:outline-none focus:ring-2 focus:ring-indigo-200"
                    />
                    <p class="mt-2 text-xs text-zinc-500">
                      Leave blank and Maraithon will name it from the template.
                    </p>
                  </div>

                  <div class="rounded-lg border border-zinc-950/10 bg-zinc-50 px-4 py-3">
                    <div class="flex flex-wrap items-center justify-between gap-2">
                      <p class="text-sm font-semibold text-zinc-950"><%= @selected_spec.label %></p>
                      <span class="text-xs font-medium text-zinc-500"><%= @selected_spec.category %></span>
                    </div>
                    <p class="mt-2 text-sm leading-6 text-zinc-600"><%= @selected_spec.summary %></p>
                  </div>
                </div>

                <%= if @projects != [] do %>
                  <div class="rounded-lg border border-emerald-200 bg-emerald-50/50 p-4">
                    <div class="grid grid-cols-1 gap-4 md:grid-cols-2">
                      <div>
                        <label for="launch_project_id" class="block text-sm font-medium text-zinc-700">
                          Attach to project
                        </label>
                        <select
                          id="launch_project_id"
                          name="launch[project_id]"
                          class="mt-1 block w-full rounded-lg border border-zinc-300 px-3 py-2 text-sm text-zinc-950 shadow-sm focus:border-indigo-500 focus:outline-none focus:ring-2 focus:ring-indigo-200"
                        >
                          <option value="">No project</option>
                          <option
                            :for={project <- @projects}
                            value={project.id}
                            selected={@launch["project_id"] == project.id}
                          >
                            <%= project.name %>
                          </option>
                        </select>
                        <p class="mt-2 text-xs text-zinc-500">
                          Attach this automation to a project so Maraithon can use its output when you ask about that project in chat.
                        </p>
                      </div>

                      <div class="rounded-lg border border-white/70 bg-white px-4 py-3">
                        <p class="text-xs font-semibold text-emerald-700">
                          Why this matters
                        </p>
                        <p class="mt-2 text-sm text-zinc-700">
                          Project-scoped automations feed local project state instead of disappearing into global noise. This is especially important for project-management and delivery flows.
                        </p>
                      </div>
                    </div>
                  </div>
                <% end %>

                <%= if field_visible?(@selected_spec, "cost_profile") do %>
                  <div class="space-y-4 rounded-lg border border-violet-200 bg-violet-50/60 p-4">
                    <div>
                      <p class="text-sm font-medium text-violet-950">Coverage level</p>
                      <p class="mt-1 text-xs text-violet-900/80">
                        Choose how closely Maraithon should watch this work. Higher coverage checks more often and reviews more context.
                      </p>
                    </div>

                    <div class="grid grid-cols-1 gap-3 xl:grid-cols-3">
                      <label
                        :for={option <- @cost_profile_options}
                        class={cost_profile_card_class(@launch["cost_profile"] == option.id)}
                      >
                        <input
                          type="radio"
                          name="launch[cost_profile]"
                          value={option.id}
                          checked={@launch["cost_profile"] == option.id}
                          class="sr-only"
                        />
                        <div class="flex items-start justify-between gap-3">
                          <div>
                            <p class="text-sm font-semibold text-zinc-950"><%= option.label %></p>
                            <p class="mt-1 text-xs leading-5 text-zinc-600"><%= option.description %></p>
                          </div>
                          <span class="rounded-md bg-white/80 px-2 py-1 text-[11px] font-semibold text-violet-700">
                            <%= if @launch["cost_profile"] == option.id, do: "Selected", else: "Option" %>
                          </span>
                        </div>
                        <p class="mt-3 text-xs leading-5 text-zinc-700">
                          <%= cost_profile_summary(@selected_spec_full.id, option.id) %>
                        </p>
                      </label>
                    </div>
                  </div>
                <% end %>

                <.launch_textarea
                  :if={field_visible?(@selected_spec, "prompt")}
                  id="launch_prompt"
                  name="launch[prompt]"
                  label="Instructions"
                  value={@launch["prompt"]}
                  rows={5}
                  description="Tell Maraithon what this automation is responsible for, how it should communicate, and what it should avoid."
                />

                <%= if field_visible?(@selected_spec, "subscriptions") or field_visible?(@selected_spec, "tools") do %>
                  <div class="grid grid-cols-1 gap-4 md:grid-cols-2">
                    <%= if field_visible?(@selected_spec, "subscriptions") do %>
                      <.launch_input
                        id="launch_subscriptions"
                        name="launch[subscriptions]"
                        label="Sources to watch"
                        value={@launch["subscriptions"]}
                        placeholder="github:owner/repo or email:you@example.com"
                        description="Optional. Add only the source feeds this automation should inspect."
                      />
                    <% end %>

                    <%= if field_visible?(@selected_spec, "tools") do %>
                      <.launch_input
                        id="launch_tools"
                        name="launch[tools]"
                        label="Allowed actions"
                        value={@launch["tools"]}
                        placeholder="read_file,search_files"
                        description="Keep this list short; only listed actions can run."
                      />
                    <% end %>
                  </div>
                <% end %>

                <%= if field_visible?(@selected_spec, "memory_limit") do %>
                  <div class="grid grid-cols-1 gap-4 md:grid-cols-3">
                    <.launch_input
                      id="launch_memory_limit"
                      type="number"
                      min="1"
                      name="launch[memory_limit]"
                      label="Recent context window"
                      value={@launch["memory_limit"]}
                      description="How many recent updates the custom automation keeps in view while it works."
                    />
                  </div>
                <% end %>

                <%= if field_visible?(@selected_spec, "codebase_path") or field_visible?(@selected_spec, "output_path") do %>
                  <div class="grid grid-cols-1 gap-4 md:grid-cols-2">
                    <%= if field_visible?(@selected_spec, "codebase_path") do %>
                      <.launch_input
                        id="launch_codebase_path"
                        name="launch[codebase_path]"
                        label="Codebase path"
                        value={@launch["codebase_path"]}
                        description="Absolute or relative directory that Maraithon should inspect."
                      />
                    <% end %>

                    <%= if field_visible?(@selected_spec, "output_path") do %>
                      <.launch_input
                        id="launch_output_path"
                        name="launch[output_path]"
                        label="Output path"
                        value={@launch["output_path"]}
                        description="Where the report or generated plan files should be written."
                      />
                    <% end %>
                  </div>
                <% end %>

                <%= if field_visible?(@selected_spec, "file_patterns") or field_visible?(@selected_spec, "ignore_patterns") do %>
                  <div class="grid grid-cols-1 gap-4 md:grid-cols-2">
                    <%= if field_visible?(@selected_spec, "file_patterns") do %>
                      <.launch_input
                        id="launch_file_patterns"
                        name="launch[file_patterns]"
                        label="Include patterns"
                        value={@launch["file_patterns"]}
                        description="Comma-separated glob patterns that define the files the automation may inspect."
                      />
                    <% end %>

                    <%= if field_visible?(@selected_spec, "ignore_patterns") do %>
                      <.launch_input
                        id="launch_ignore_patterns"
                        name="launch[ignore_patterns]"
                        label="Ignore patterns"
                        value={@launch["ignore_patterns"]}
                        description="Comma-separated globs to exclude generated, vendored, or irrelevant files."
                      />
                    <% end %>
                  </div>
                <% end %>

                <%= if field_visible?(@selected_spec, "check_url") do %>
                  <.launch_input
                    id="launch_check_url"
                    name="launch[check_url]"
                    label="Optional URL to check"
                    value={@launch["check_url"]}
                    placeholder="https://status.example.com/health"
                    description="If set, the monitor will check this URL on its schedule."
                  />
                <% end %>

                <%= if field_visible?(@selected_spec, "repo_full_name") or field_visible?(@selected_spec, "base_branch") or field_visible?(@selected_spec, "feature_limit") do %>
                  <div class="grid grid-cols-1 gap-4 md:grid-cols-2 xl:grid-cols-3">
                    <%= if field_visible?(@selected_spec, "repo_full_name") do %>
                      <.launch_input
                        id="launch_repo_full_name"
                        name="launch[repo_full_name]"
                        label="GitHub repository"
                        value={@launch["repo_full_name"]}
                        placeholder="owner/repo"
                        description="The exact GitHub repository the planner should review every day."
                      />
                    <% end %>

                    <%= if field_visible?(@selected_spec, "base_branch") do %>
                      <.launch_input
                        id="launch_base_branch"
                        name="launch[base_branch]"
                        label="Base branch"
                        value={@launch["base_branch"]}
                        placeholder="main"
                        description="Usually main. This is the branch snapshot the planner treats as the current product baseline."
                      />
                    <% end %>

                    <%= if field_visible?(@selected_spec, "feature_limit") do %>
                      <.launch_select
                        id="launch_feature_limit"
                        name="launch[feature_limit]"
                        label="Daily feature limit"
                        value={@launch["feature_limit"]}
                        description="How many roadmap opportunities the planner should show in each daily review."
                      >
                          <option value="2" selected={@launch["feature_limit"] == "2"}>2</option>
                          <option value="3" selected={@launch["feature_limit"] == "3"}>3</option>
                      </.launch_select>
                    <% end %>
                  </div>
                <% end %>

                <%= if field_visible?(@selected_spec, "email_scan_limit") or field_visible?(@selected_spec, "event_scan_limit") or field_visible?(@selected_spec, "prep_window_hours") or field_visible?(@selected_spec, "max_insights_per_cycle") or field_visible?(@selected_spec, "min_confidence") do %>
                  <div class="grid grid-cols-1 gap-4 md:grid-cols-2 xl:grid-cols-3">
                    <%= if field_visible?(@selected_spec, "email_scan_limit") do %>
                      <.launch_input
                        id="launch_email_scan_limit"
                        type="number"
                        min="1"
                        name="launch[email_scan_limit]"
                        label="Email review limit"
                        value={@launch["email_scan_limit"]}
                      />
                    <% end %>

                    <%= if field_visible?(@selected_spec, "event_scan_limit") do %>
                      <.launch_input
                        id="launch_event_scan_limit"
                        type="number"
                        min="1"
                        name="launch[event_scan_limit]"
                        label="Calendar review limit"
                        value={@launch["event_scan_limit"]}
                      />
                    <% end %>

                    <%= if field_visible?(@selected_spec, "prep_window_hours") do %>
                      <.launch_input
                        id="launch_prep_window_hours"
                        type="number"
                        min="1"
                        name="launch[prep_window_hours]"
                        label="Meeting follow-up window (hours)"
                        value={@launch["prep_window_hours"]}
                      />
                    <% end %>

                    <%= if field_visible?(@selected_spec, "max_insights_per_cycle") do %>
                      <.launch_input
                        id="launch_max_insights_per_cycle"
                        type="number"
                        min="1"
                        name="launch[max_insights_per_cycle]"
                        label="Max items per check"
                        value={@launch["max_insights_per_cycle"]}
                        description="Caps how many follow-up items Maraithon can show at once."
                      />
                    <% end %>

                    <%= if field_visible?(@selected_spec, "min_confidence") do %>
                      <.launch_select
                        id="launch_min_confidence"
                        name="launch[min_confidence]"
                        label="Notification selectivity"
                        value={@launch["min_confidence"]}
                        description="Choose how selective Maraithon should be before it sends a notification."
                      >
                        <option
                          :for={
                            option <-
                              notification_selectivity_options(
                                @selected_spec.id,
                                @launch["min_confidence"]
                              )
                          }
                          value={option.value}
                          selected={@launch["min_confidence"] == option.value}
                        >
                          <%= option.label %>
                        </option>
                      </.launch_select>
                    <% end %>
                  </div>
                <% end %>

                <%= if field_visible?(@selected_spec, "team_id") or field_visible?(@selected_spec, "channel_scan_limit") or field_visible?(@selected_spec, "dm_scan_limit") or field_visible?(@selected_spec, "lookback_hours") do %>
                  <div class="grid grid-cols-1 gap-4 md:grid-cols-2 xl:grid-cols-3">
                    <%= if field_visible?(@selected_spec, "team_id") do %>
                      <.launch_select
                        id="launch_team_id"
                        name="launch[team_id]"
                        label="Slack workspace"
                        value={@launch["team_id"]}
                        description="Leave as all workspaces, or choose one connected Slack workspace for this automation."
                      >
                        <option
                          :for={option <- @slack_workspace_options}
                          value={option.value}
                          selected={@launch["team_id"] == option.value}
                        >
                          <%= option.label %>
                        </option>
                      </.launch_select>
                    <% end %>

                    <%= if field_visible?(@selected_spec, "channel_scan_limit") do %>
                      <.launch_input
                        id="launch_channel_scan_limit"
                        type="number"
                        min="1"
                        name="launch[channel_scan_limit]"
                        label="Channel review limit"
                        value={@launch["channel_scan_limit"]}
                      />
                    <% end %>

                    <%= if field_visible?(@selected_spec, "dm_scan_limit") do %>
                      <.launch_input
                        id="launch_dm_scan_limit"
                        type="number"
                        min="1"
                        name="launch[dm_scan_limit]"
                        label="DM review limit"
                        value={@launch["dm_scan_limit"]}
                      />
                    <% end %>

                    <%= if field_visible?(@selected_spec, "lookback_hours") do %>
                      <.launch_input
                        id="launch_lookback_hours"
                        type="number"
                        min="1"
                        name="launch[lookback_hours]"
                        label="Lookback window (hours)"
                        value={@launch["lookback_hours"]}
                      />
                    <% end %>
                  </div>
                <% end %>

                <%= if field_visible?(@selected_spec, "wakeup_interval_ms") or field_visible?(@selected_spec, "write_plan_files") do %>
                  <div class="grid grid-cols-1 gap-4 md:grid-cols-2">
                    <%= if field_visible?(@selected_spec, "wakeup_interval_ms") do %>
                      <.launch_input
                        id="launch_wakeup_interval_ms"
                        name="launch[wakeup_interval_ms]"
                        label="Check cadence"
                        value={@launch["wakeup_interval_ms"]}
                        placeholder="30m"
                        description="How often this automation checks in. Use 30m, 1h, 1d, or a custom millisecond value."
                      />
                    <% end %>

                    <%= if field_visible?(@selected_spec, "write_plan_files") do %>
                      <.launch_select
                        id="launch_write_plan_files"
                        name="launch[write_plan_files]"
                        label="Write plan files"
                        value={@launch["write_plan_files"]}
                        description="When enabled, generated plans are written to disk in addition to the in-app activity log."
                      >
                          <option value="true" selected={@launch["write_plan_files"] == "true"}>Yes</option>
                          <option value="false" selected={@launch["write_plan_files"] == "false"}>No</option>
                      </.launch_select>
                    <% end %>
                  </div>
                <% end %>

                <%= if field_visible?(@selected_spec, "timezone") or field_visible?(@selected_spec, "timezone_offset_hours") or field_visible?(@selected_spec, "morning_brief_hour_local") or field_visible?(@selected_spec, "end_of_day_brief_hour_local") or field_visible?(@selected_spec, "weekly_review_day_local") or field_visible?(@selected_spec, "weekly_review_hour_local") or field_visible?(@selected_spec, "brief_max_items") do %>
                  <div class="space-y-4 rounded-lg border border-emerald-200 bg-emerald-50/50 p-4">
                    <div>
                      <p class="text-sm font-medium text-emerald-950">Chief-of-Staff Briefing</p>
                      <p class="mt-1 text-xs text-emerald-900/80">
                        Configure the daily and weekly summary cadence that lands in Telegram alongside timely follow-through nudges.
                      </p>
                    </div>

                    <div class="grid grid-cols-1 gap-4 md:grid-cols-2 xl:grid-cols-3">
                      <%= if field_visible?(@selected_spec, "timezone") do %>
                        <.launch_select
                          id="launch_timezone"
                          name="launch[timezone]"
                          label="Timezone"
                          value={launch_timezone_value(@launch)}
                          description="Named timezones keep brief timing correct through daylight-saving changes."
                        >
                          <option
                            :for={option <- timezone_options()}
                            value={option.value}
                            selected={option.value == launch_timezone_value(@launch)}
                          >
                            <%= option.label %>
                          </option>
                        </.launch_select>
                      <% end %>

                      <%= if field_visible?(@selected_spec, "timezone_offset_hours") do %>
                        <.launch_input
                          id="launch_timezone_offset_hours"
                          type="number"
                          min="-12"
                          max="14"
                          name="launch[timezone_offset_hours]"
                          label="Timezone offset from UTC"
                          value={@launch["timezone_offset_hours"]}
                          description="Use -5 for Eastern Standard Time, -4 for Eastern Daylight Time, 0 for UTC."
                        />
                      <% end %>

                      <%= if field_visible?(@selected_spec, "morning_brief_hour_local") do %>
                        <.launch_input
                          id="launch_morning_brief_hour_local"
                          type="number"
                          min="0"
                          max="23"
                          name="launch[morning_brief_hour_local]"
                          label="Morning brief hour"
                          value={@launch["morning_brief_hour_local"]}
                        />
                      <% end %>

                      <%= if field_visible?(@selected_spec, "end_of_day_brief_hour_local") do %>
                        <.launch_input
                          id="launch_end_of_day_brief_hour_local"
                          type="number"
                          min="0"
                          max="23"
                          name="launch[end_of_day_brief_hour_local]"
                          label="End-of-day brief hour"
                          value={@launch["end_of_day_brief_hour_local"]}
                        />
                      <% end %>

                      <%= if field_visible?(@selected_spec, "weekly_review_day_local") do %>
                        <.launch_input
                          id="launch_weekly_review_day_local"
                          type="number"
                          min="1"
                          max="7"
                          name="launch[weekly_review_day_local]"
                          label="Weekly review day"
                          value={@launch["weekly_review_day_local"]}
                          description="Use 1 for Monday through 7 for Sunday."
                        />
                      <% end %>

                      <%= if field_visible?(@selected_spec, "weekly_review_hour_local") do %>
                        <.launch_input
                          id="launch_weekly_review_hour_local"
                          type="number"
                          min="0"
                          max="23"
                          name="launch[weekly_review_hour_local]"
                          label="Weekly review hour"
                          value={@launch["weekly_review_hour_local"]}
                        />
                      <% end %>

                      <%= if field_visible?(@selected_spec, "brief_max_items") do %>
                        <.launch_input
                          id="launch_brief_max_items"
                          type="number"
                          min="1"
                          max="30"
                          name="launch[brief_max_items]"
                          label="Items per brief"
                          value={@launch["brief_max_items"]}
                        />
                      <% end %>
                    </div>
                  </div>
                <% end %>

                <%= if @builder_mode == "advanced" do %>
                  <div class="grid grid-cols-1 gap-4 md:grid-cols-2 xl:grid-cols-3">
                    <.launch_input
                      id="launch_budget_llm_calls"
                      type="number"
                      min="1"
                      name="launch[budget_llm_calls]"
                      label="Review limit"
                      value={@launch["budget_llm_calls"]}
                    />

                    <.launch_input
                      id="launch_budget_tool_calls"
                      type="number"
                      min="1"
                      name="launch[budget_tool_calls]"
                      label="Action limit"
                      value={@launch["budget_tool_calls"]}
                    />
                  </div>

                  <.launch_textarea
                    id="launch_config_json"
                    name="launch[config_json]"
                    label="Support setup JSON"
                    value={@launch["config_json"]}
                    rows={6}
                    textarea_class="font-mono"
                    description="Leave blank unless Maraithon support gives you setup JSON."
                  />
                <% end %>

                <div class="flex flex-wrap items-center justify-between gap-3 border-t border-zinc-950/10 pt-5">
                  <div class="text-sm text-zinc-500">
                    <%= if @blockers == [] do %>
                      Ready to create. Maraithon will save the automation and start it right away.
                    <% else %>
                      Resolve the highlighted blockers before launch.
                    <% end %>
                  </div>

                  <.button
                    type="submit"
                    phx-disable-with="Creating..."
                    disabled={@blockers != []}
                    color={if @blockers == [], do: "dark", else: "zinc"}
                  >
                    Create automation
                  </.button>
                </div>
              </form>
            </section>
          </div>

          <aside class="space-y-5 xl:sticky xl:top-5 xl:self-start">
            <section class="rounded-lg border border-zinc-950/10 bg-white p-5 shadow-sm">
              <p class="text-sm/6 font-semibold text-zinc-950">What goes in</p>
              <div class="mt-3 divide-y divide-zinc-950/5">
                <div :for={item <- @input_preview} class="py-2.5 first:pt-0 last:pb-0">
                  <p :if={item.title} class="text-xs/5 font-medium text-zinc-500">
                    <%= item.title %>
                  </p>
                  <p class={["text-sm/6 text-zinc-700", item.title && "mt-0.5"]}>
                    <%= item.body %>
                  </p>
                </div>
              </div>
            </section>

            <section class="rounded-lg border border-zinc-950/10 bg-white p-5 shadow-sm">
              <p class="text-sm/6 font-semibold text-zinc-950">What comes out</p>
              <div class="mt-3 divide-y divide-zinc-950/5">
                <div :for={item <- @output_preview} class="py-2.5 first:pt-0 last:pb-0">
                  <p :if={item.title} class="text-xs/5 font-medium text-zinc-500">
                    <%= item.title %>
                  </p>
                  <p class={["text-sm/6 text-zinc-700", item.title && "mt-0.5"]}>
                    <%= item.body %>
                  </p>
                </div>
              </div>
            </section>

            <.architecture_card architecture={@architecture} mode="compact" />

            <section class="rounded-lg border border-zinc-950/10 bg-white p-5 shadow-sm">
              <div class="flex items-center justify-between gap-3">
                <p class="text-sm font-semibold text-zinc-950">Permission readiness</p>
                <a href={~p"/connectors"} class="text-xs font-medium text-indigo-600 hover:text-indigo-500">Open connectors</a>
              </div>
              <div class="mt-3 space-y-2">
                <div :for={item <- @readiness_items} class="rounded-lg border border-zinc-950/10 px-3 py-3">
                  <div class="flex items-start justify-between gap-3">
                    <div>
                      <p class="text-sm font-medium text-zinc-950"><%= item.label %></p>
                      <p class="mt-1 text-sm leading-6 text-zinc-600"><%= item.description %></p>
                    </div>
                    <span class={readiness_badge_class(item)}>
                      <%= readiness_badge_text(item) %>
                    </span>
                  </div>
                  <p class="mt-2 text-xs text-zinc-500"><%= item.details %></p>
                </div>
              </div>
            </section>

            <section class="rounded-lg border border-zinc-950/10 bg-white p-5 shadow-sm">
              <p class="text-sm font-semibold text-zinc-950">Suggested starting point</p>
              <div class="mt-3 space-y-2">
                <div :for={item <- @starter_values} class="flex items-start justify-between gap-3 rounded-lg bg-zinc-50 px-3 py-2">
                  <div class="text-sm font-medium text-zinc-950"><%= item.label %></div>
                  <div class="max-w-[55%] text-right text-sm text-zinc-600"><%= item.value %></div>
                </div>
                <div :for={tip <- @selected_spec.suggestions} class="rounded-lg border border-dashed border-zinc-200 px-3 py-3 text-sm leading-6 text-zinc-600">
                  <%= tip %>
                </div>
              </div>
            </section>
          </aside>
        </div>
      </div>
    </Layouts.app>
    """
  end

  defp assign_builder_state(socket, launch) do
    selected_spec_full = AgentBuilder.behavior_spec(launch["behavior"])
    builder_mode = socket.assigns[:builder_mode] || "simple"
    visible_fields = AgentBuilder.visible_fields_for_mode(selected_spec_full, builder_mode)
    hidden_fields = AgentBuilder.hidden_fields_for_mode(selected_spec_full, builder_mode)
    selected_spec = %{selected_spec_full | fields: visible_fields}
    provider_map = socket.assigns.provider_map
    slack_workspace_options = slack_workspace_options(provider_map, launch["team_id"])

    readiness_items =
      readiness_items(
        selected_spec_full,
        launch,
        provider_map,
        socket.assigns.tool_allowed_paths
      )

    assign(socket,
      launch: launch,
      selected_spec: selected_spec,
      selected_spec_full: selected_spec_full,
      hidden_fields: hidden_fields,
      hidden_simple_count: length(hidden_fields) + hidden_control_count(builder_mode),
      readiness_items: readiness_items,
      blockers: Enum.filter(readiness_items, &(&1.required? and not &1.ready?)),
      input_preview: input_preview(selected_spec_full, launch, provider_map),
      output_preview: output_preview(selected_spec_full, launch),
      architecture: AgentArchitecture.for_launch(launch),
      starter_values: starter_values(selected_spec_full, launch, provider_map),
      slack_workspace_options: slack_workspace_options
    )
  end

  defp load_providers(user_id) do
    case Connections.safe_dashboard_snapshot(user_id, return_to: "/agents/new") do
      {:ok, snapshot} ->
        {Map.new(snapshot.providers, &{&1.provider, &1}), []}

      {:degraded, snapshot} ->
        {Map.new(snapshot.providers, &{&1.provider, &1}), snapshot.errors}
    end
  end

  defp readiness_items(spec, launch, provider_map, tool_allowed_paths) do
    spec_items =
      Enum.map(spec.requirements, &readiness_item(&1, launch, provider_map))

    dynamic_items =
      case spec.id do
        "prompt_agent" -> prompt_agent_readiness(launch, provider_map, tool_allowed_paths)
        "watchdog_summarizer" -> watchdog_readiness(launch)
        _ -> []
      end

    case spec_items ++ dynamic_items do
      [] ->
        [
          %{
            label: "No external permissions required",
            description:
              "This template can run without connected app permissions or special setup.",
            details:
              "You can create it immediately and add more permissions later if the behavior evolves.",
            ready?: true,
            required?: false
          }
        ]

      items ->
        items
    end
  end

  defp prompt_agent_readiness(launch, provider_map, tool_allowed_paths) do
    tools = parse_csv(launch["tools"])

    provider_items =
      tools
      |> Enum.map(&Map.get(@tool_provider_requirements, &1))
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
      |> Enum.map(fn requirement ->
        readiness_item(
          Map.merge(requirement, %{
            kind: (Map.get(requirement, :service, nil) && :provider_service) || :provider,
            description: "Required because one of the selected tools depends on this connector.",
            required?: true
          }),
          launch,
          provider_map
        )
      end)

    path_item =
      if Enum.any?(tools, &MapSet.member?(@path_tools, &1)) do
        [
          %{
            label: "Local file access",
            description: "Needed because the selected action list includes file access.",
            details:
              "Allowed roots: " <>
                (tool_allowed_paths |> Enum.map(&Path.expand/1) |> Enum.join(", ")),
            ready?: tool_allowed_paths != [],
            required?: true
          }
        ]
      else
        []
      end

    provider_items ++ path_item
  end

  defp watchdog_readiness(%{"check_url" => ""}), do: []

  defp watchdog_readiness(%{"check_url" => url}) do
    [
      %{
        label: "Optional URL check",
        description:
          "The monitor will check the configured endpoint every sixth scheduled check.",
        details: "Configured URL: #{url}",
        ready?: true,
        required?: false
      }
    ]
  end

  defp readiness_item(%{kind: :provider_service} = requirement, _launch, provider_map) do
    provider = Map.get(provider_map, requirement.provider)

    service =
      provider &&
        Enum.find(provider.services, fn service ->
          service.id == requirement.service
        end)

    ready? = service && service.status == :connected

    %{
      label: requirement.label,
      description: requirement.description,
      details:
        if(
          ready?,
          do: "Ready. The required service is connected.",
          else: "Missing. Connect #{requirement.label} before launch."
        ),
      ready?: !!ready?,
      required?: requirement.required?
    }
  end

  defp readiness_item(%{kind: :provider} = requirement, _launch, provider_map) do
    provider = Map.get(provider_map, requirement.provider)
    ready? = provider && provider.status in [:connected, :partial]

    %{
      label: requirement.label,
      description: requirement.description,
      details:
        if(
          ready?,
          do: "Ready. The connector is available for this user.",
          else: "Missing. Connect #{requirement.label} before launch."
        ),
      ready?: !!ready?,
      required?: requirement.required?
    }
  end

  defp readiness_item(%{kind: :directory} = requirement, launch, _provider_map) do
    value = Map.get(launch, requirement.field, "")
    ready? = value != "" and File.dir?(value)

    %{
      label: requirement.label,
      description: requirement.description,
      details:
        if(
          ready?,
          do: "Ready. Maraithon can access #{value}.",
          else: "Missing. Point this field at an existing directory."
        ),
      ready?: ready?,
      required?: requirement.required?
    }
  end

  defp readiness_item(%{kind: :parent_directory} = requirement, launch, _provider_map) do
    value = Map.get(launch, requirement.field, "")
    ready? = value != "" and File.dir?(Path.dirname(value))

    %{
      label: requirement.label,
      description: requirement.description,
      details:
        if(
          ready?,
          do: "Ready. #{Path.dirname(value)} exists and can receive output files.",
          else: "Missing. The parent directory for this output path must already exist."
        ),
      ready?: ready?,
      required?: requirement.required?
    }
  end

  defp launch_blockers(launch, socket) do
    spec = AgentBuilder.behavior_spec(launch["behavior"])

    readiness_items(spec, launch, socket.assigns.provider_map, socket.assigns.tool_allowed_paths)
    |> Enum.filter(&(&1.required? and not &1.ready?))
  end

  defp blocker_message(blockers) do
    labels = Enum.map_join(blockers, ", ", & &1.label)
    "Resolve these blockers before launch: #{labels}."
  end

  defp input_preview(spec, launch, provider_map) do
    base = Enum.map(spec.inputs, fn line -> %{title: nil, body: line} end)
    base ++ dynamic_input_preview(spec.id, launch, provider_map)
  end

  defp dynamic_input_preview("inbox_calendar_advisor", launch, provider_map) do
    [
      %{
        title: "Operating profile",
        body: cost_profile_summary("inbox_calendar_advisor", launch["cost_profile"])
      },
      %{
        title: "Context checked",
        body:
          "Reviews recent inbox, calendar, Slack channel, and Slack DM activity before deciding what deserves follow-up."
      },
      %{
        title: "Workspace scope",
        body:
          slack_scope_sentence(
            launch,
            provider_map,
            "Uses all connected Slack workspaces for unresolved commitments.",
            "Scoped to %{workspace}."
          )
      },
      %{
        title: "What reaches you",
        body:
          "Shows up to #{launch["max_insights_per_cycle"]} action-ready items at a time and keeps notifications #{notification_selectivity_phrase("inbox_calendar_advisor", launch["min_confidence"])}."
      }
    ]
  end

  defp dynamic_input_preview("ai_chief_of_staff", launch, provider_map) do
    [
      %{
        title: "Operating profile",
        body: cost_profile_summary("ai_chief_of_staff", launch["cost_profile"])
      },
      %{
        title: "Built-in skills",
        body:
          "Covers follow-through, travel logistics, and recurring executive briefs from one assistant."
      },
      %{
        title: "Slack scope",
        body:
          slack_scope_sentence(
            launch,
            provider_map,
            "Uses all connected Slack workspaces for follow-through.",
            "Scoped to %{workspace} for follow-through."
          )
      },
      %{
        title: "Brief timing",
        body:
          "Uses #{launch_timezone_label(launch)} with morning brief #{launch["morning_brief_hour_local"]}:00 and end-of-day brief #{launch["end_of_day_brief_hour_local"]}:00."
      }
    ]
  end

  defp dynamic_input_preview("slack_followthrough_agent", launch, provider_map) do
    [
      %{
        title: "Operating profile",
        body: cost_profile_summary("slack_followthrough_agent", launch["cost_profile"])
      },
      %{
        title: "Workspace scope",
        body:
          slack_scope_sentence(
            launch,
            provider_map,
            "Uses all connected Slack workspaces.",
            "Scoped to %{workspace}."
          )
      },
      %{
        title: "Context checked",
        body:
          "Reviews recent Slack channel and DM activity before surfacing commitments that still need a reply."
      },
      %{
        title: "What reaches you",
        body:
          "Shows up to #{launch["max_insights_per_cycle"]} unresolved Slack commitments at a time and keeps notifications #{notification_selectivity_phrase("slack_followthrough_agent", launch["min_confidence"])}."
      }
    ]
  end

  defp dynamic_input_preview(behavior, launch, _provider_map),
    do: dynamic_input_preview(behavior, launch)

  defp dynamic_input_preview("prompt_agent", launch) do
    subscriptions =
      case launch["subscriptions"] do
        "" ->
          "This automation responds only to direct messages until you add sources to watch."

        value ->
          "Sources: #{value}"
      end

    tools =
      case launch["tools"] do
        "" -> "No actions enabled. The automation will stay text-only."
        value -> "Allowed actions: #{value}"
      end

    [
      %{
        title: "Operating profile",
        body: cost_profile_summary("prompt_agent", launch["cost_profile"])
      },
      %{title: "Sources to watch", body: subscriptions},
      %{title: "Allowed actions", body: tools}
    ]
  end

  defp dynamic_input_preview("codebase_advisor", launch) do
    [
      %{title: "Repository scope", body: "Reviewing files under #{launch["codebase_path"]}"},
      %{title: "Output target", body: "Writing recommendations to #{launch["output_path"]}"}
    ]
  end

  defp dynamic_input_preview("repo_planner", launch) do
    [
      %{title: "Repository scope", body: "Indexing files under #{launch["codebase_path"]}"},
      %{
        title: "Plan files",
        body:
          if(launch["write_plan_files"] == "true",
            do: "Plans will also be written to #{launch["output_path"]}",
            else: "Plans will stay in the in-app activity log unless you enable plan files."
          )
      }
    ]
  end

  defp dynamic_input_preview("watchdog_summarizer", launch) do
    [
      %{
        title: "Check cadence",
        body:
          "Checks every #{format_cadence(launch["wakeup_interval_ms"])} to write monitoring updates."
      },
      %{
        title: "URL check",
        body:
          if(launch["check_url"] == "",
            do: "Monitoring updates only. Add a URL if you also want endpoint checks.",
            else: "Configured endpoint: #{launch["check_url"]}"
          )
      }
    ]
  end

  defp dynamic_input_preview("personal_assistant_agent", launch) do
    [
      %{
        title: "Operating profile",
        body: cost_profile_summary("personal_assistant_agent", launch["cost_profile"])
      },
      %{
        title: "Trip context",
        body:
          "Uses Gmail travel confirmations and matching calendar events to assemble the itinerary."
      },
      %{
        title: "Delivery timing",
        body:
          "Sends the prep brief the day before the trip using your local offset (#{blank_fallback(launch["timezone_offset_hours"], "-5")})."
      },
      %{
        title: "Notification selectivity",
        body:
          "Only sends trip briefs when itinerary details are clear enough. Current setting: #{notification_selectivity_label("personal_assistant_agent", launch["min_confidence"])}."
      }
    ]
  end

  defp dynamic_input_preview("github_product_planner", launch) do
    [
      %{
        title: "Operating profile",
        body: cost_profile_summary("github_product_planner", launch["cost_profile"])
      },
      %{
        title: "Repository review target",
        body:
          if(launch["repo_full_name"] == "",
            do:
              "Add a repository in `owner/repo` format so the planner can review current product work.",
            else:
              "Reviewing #{launch["repo_full_name"]} on branch #{blank_fallback(launch["base_branch"], "main")}."
          )
      },
      %{
        title: "Daily planning scope",
        body:
          "The planner will shortlist #{blank_fallback(launch["feature_limit"], "3")} product moves for each review."
      }
    ]
  end

  defp dynamic_input_preview(_behavior, _launch), do: []

  defp output_preview(spec, launch) do
    base = Enum.map(spec.outputs, fn line -> %{title: nil, body: line} end)
    base ++ dynamic_output_preview(spec.id, launch)
  end

  defp dynamic_output_preview("prompt_agent", launch) do
    [
      %{
        title: "Launch result",
        body:
          "The automation starts immediately with room for #{launch["budget_llm_calls"]} review passes and #{launch["budget_tool_calls"]} allowed actions."
      }
    ]
  end

  defp dynamic_output_preview("ai_chief_of_staff", _launch) do
    [
      %{
        title: "Saved output",
        body:
          "The assistant can save both follow-through insights and travel briefing records under one automation."
      }
    ]
  end

  defp dynamic_output_preview("inbox_calendar_advisor", _launch) do
    [
      %{
        title: "Saved output",
        body:
          "Each insight saves a commitment record with evidence and next action across Gmail, Calendar, and Slack."
      }
    ]
  end

  defp dynamic_output_preview("personal_assistant_agent", _launch) do
    [
      %{
        title: "Saved output",
        body:
          "Each trip saves an itinerary with flight and hotel details, then sends the prep brief through Telegram."
      }
    ]
  end

  defp dynamic_output_preview("slack_followthrough_agent", _launch) do
    [
      %{
        title: "Saved output",
        body:
          "Each unresolved Slack commitment saves a record with the person, deadline, evidence, and next action."
      }
    ]
  end

  defp dynamic_output_preview("codebase_advisor", launch) do
    [
      %{title: "Saved output", body: "Recommendations report: #{launch["output_path"]}"}
    ]
  end

  defp dynamic_output_preview("repo_planner", launch) do
    [
      %{
        title: "Saved output",
        body:
          if(launch["write_plan_files"] == "true",
            do: "Saved plans go to #{launch["output_path"]} and also appear in the activity log.",
            else: "Plans remain in the in-app activity log unless you enable plan file writing."
          )
      }
    ]
  end

  defp dynamic_output_preview("github_product_planner", launch) do
    [
      %{
        title: "Telegram push behavior",
        body:
          "Roadmap suggestions that need same-day attention are saved for #{blank_fallback(launch["repo_full_name"], "the selected repository")} and sent in Telegram."
      }
    ]
  end

  defp dynamic_output_preview(_behavior, _launch), do: []

  defp starter_values(spec, launch, provider_map) do
    case spec.id do
      "ai_chief_of_staff" ->
        [
          %{label: "Coverage", value: cost_profile_label(launch["cost_profile"])},
          %{
            label: "Slack workspace",
            value: slack_scope_value(launch, provider_map)
          },
          %{
            label: "Timezone",
            value: launch_timezone_label(launch)
          },
          %{label: "Brief max items", value: launch["brief_max_items"]}
        ]

      "prompt_agent" ->
        [
          %{
            label: "Coverage",
            value:
              launch["cost_profile"]
              |> cost_profile_label()
              |> Kernel.<>(" coverage")
          },
          %{label: "Recent context", value: launch["memory_limit"] <> " updates"},
          %{label: "Review limit", value: launch["budget_llm_calls"]},
          %{label: "Action limit", value: launch["budget_tool_calls"]}
        ]

      "inbox_calendar_advisor" ->
        [
          %{label: "Coverage", value: cost_profile_label(launch["cost_profile"])},
          %{label: "Email review limit", value: launch["email_scan_limit"]},
          %{label: "Calendar review limit", value: launch["event_scan_limit"]},
          %{
            label: "Slack workspace",
            value: slack_scope_value(launch, provider_map)
          },
          %{label: "Slack DM review", value: launch["dm_scan_limit"]}
        ]

      "personal_assistant_agent" ->
        [
          %{label: "Coverage", value: cost_profile_label(launch["cost_profile"])},
          %{label: "Email review limit", value: launch["email_scan_limit"]},
          %{label: "Calendar review limit", value: launch["event_scan_limit"]},
          %{label: "Lookback window", value: launch["lookback_hours"] <> " hours"},
          %{
            label: "Notification selectivity",
            value:
              notification_selectivity_label("personal_assistant_agent", launch["min_confidence"])
          }
        ]

      "slack_followthrough_agent" ->
        [
          %{label: "Coverage", value: cost_profile_label(launch["cost_profile"])},
          %{
            label: "Slack workspace",
            value: slack_scope_value(launch, provider_map)
          },
          %{label: "Channel review limit", value: launch["channel_scan_limit"]},
          %{label: "DM review limit", value: launch["dm_scan_limit"]}
        ]

      "codebase_advisor" ->
        [
          %{label: "Codebase path", value: launch["codebase_path"]},
          %{label: "Check cadence", value: format_cadence(launch["wakeup_interval_ms"])},
          %{label: "Output path", value: launch["output_path"]}
        ]

      "repo_planner" ->
        [
          %{label: "Codebase path", value: launch["codebase_path"]},
          %{
            label: "Write plan files",
            value: if(launch["write_plan_files"] == "true", do: "Yes", else: "No")
          },
          %{label: "Check cadence", value: format_cadence(launch["wakeup_interval_ms"])}
        ]

      "watchdog_summarizer" ->
        [
          %{label: "Check cadence", value: format_cadence(launch["wakeup_interval_ms"])},
          %{
            label: "Optional URL",
            value:
              if(launch["check_url"] == "",
                do: "Monitoring updates only",
                else: launch["check_url"]
              )
          },
          %{label: "Action limit", value: launch["budget_tool_calls"]}
        ]

      "github_product_planner" ->
        [
          %{label: "Coverage", value: cost_profile_label(launch["cost_profile"])},
          %{
            label: "Repository",
            value: blank_fallback(launch["repo_full_name"], "Set `owner/repo`")
          },
          %{
            label: "Daily shortlist",
            value: blank_fallback(launch["feature_limit"], "3") <> " features"
          },
          %{label: "Check cadence", value: format_cadence(launch["wakeup_interval_ms"])}
        ]

      _ ->
        [
          %{label: "Review limit", value: launch["budget_llm_calls"]},
          %{label: "Action limit", value: launch["budget_tool_calls"]}
        ]
    end
  end

  defp format_cadence(value) do
    case parse_cadence_ms(value) do
      {:ok, ms} -> format_duration_ms(ms)
      :error -> blank_fallback(value, "Not set")
    end
  end

  defp parse_cadence_ms(value) do
    value = value |> to_string() |> String.trim() |> String.downcase()

    cond do
      value == "" ->
        :error

      match =
          Regex.run(
            ~r/^(\d+)\s*(ms|s|sec|secs|second|seconds|m|min|mins|minute|minutes|h|hr|hrs|hour|hours|d|day|days|w|week|weeks)$/,
            value
          ) ->
        [_full, amount, unit] = match
        {:ok, String.to_integer(amount) * cadence_unit_multiplier(unit)}

      true ->
        case Integer.parse(value) do
          {parsed, ""} when parsed > 0 -> {:ok, parsed}
          _ -> :error
        end
    end
  end

  defp cadence_unit_multiplier(unit) when unit in ["ms"], do: 1

  defp cadence_unit_multiplier(unit) when unit in ["s", "sec", "secs", "second", "seconds"],
    do: 1_000

  defp cadence_unit_multiplier(unit) when unit in ["m", "min", "mins", "minute", "minutes"],
    do: 60_000

  defp cadence_unit_multiplier(unit) when unit in ["h", "hr", "hrs", "hour", "hours"],
    do: 3_600_000

  defp cadence_unit_multiplier(unit) when unit in ["d", "day", "days"], do: 86_400_000
  defp cadence_unit_multiplier(unit) when unit in ["w", "week", "weeks"], do: 604_800_000

  defp format_duration_ms(ms) when is_integer(ms) and ms > 0 do
    cond do
      rem(ms, 604_800_000) == 0 -> duration_unit(div(ms, 604_800_000), "week")
      rem(ms, 86_400_000) == 0 -> duration_unit(div(ms, 86_400_000), "day")
      rem(ms, 3_600_000) == 0 -> duration_unit(div(ms, 3_600_000), "hour")
      rem(ms, 60_000) == 0 -> duration_unit(div(ms, 60_000), "minute")
      rem(ms, 1_000) == 0 -> duration_unit(div(ms, 1_000), "second")
      true -> "#{ms} ms"
    end
  end

  defp duration_unit(1, unit), do: "1 #{unit}"
  defp duration_unit(count, unit), do: "#{count} #{unit}s"

  defp slack_workspace_options(provider_map, selected_team_id) do
    selected_team_id = normalize_blank(selected_team_id)

    account_options =
      provider_map
      |> Map.get("slack", %{})
      |> Map.get(:accounts, [])
      |> Enum.with_index(1)
      |> Enum.map(fn {account, index} -> slack_workspace_option(account, index) end)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq_by(& &1.value)

    account_options =
      if selected_team_id && Enum.all?(account_options, &(&1.value != selected_team_id)) do
        [%{label: "Selected Slack workspace", value: selected_team_id} | account_options]
      else
        account_options
      end

    [%{label: "All connected workspaces", value: ""} | account_options]
  end

  defp slack_workspace_option(account, index) when is_map(account) do
    with team_id when is_binary(team_id) <- slack_workspace_team_id(account) do
      %{
        value: team_id,
        label: slack_workspace_option_label(account, team_id, index)
      }
    end
  end

  defp slack_workspace_option(_account, _index), do: nil

  defp slack_scope_sentence(launch, provider_map, all_workspaces, selected_template) do
    case normalize_blank(launch["team_id"]) do
      nil ->
        all_workspaces

      team_id ->
        workspace = slack_workspace_display_name(provider_map, team_id)
        String.replace(selected_template, "%{workspace}", workspace)
    end
  end

  defp slack_scope_value(launch, provider_map) do
    case normalize_blank(launch["team_id"]) do
      nil -> "All connected workspaces"
      team_id -> slack_workspace_display_name(provider_map, team_id)
    end
  end

  defp slack_workspace_display_name(provider_map, team_id) do
    provider_map
    |> slack_workspace_options(team_id)
    |> Enum.find(&(&1.value == team_id))
    |> case do
      %{label: label} when is_binary(label) -> slack_scope_display_label(label)
      _ -> "the selected Slack workspace"
    end
  end

  defp slack_scope_display_label("Selected Slack workspace"), do: "the selected Slack workspace"
  defp slack_scope_display_label("Connected Slack workspace"), do: "the selected Slack workspace"

  defp slack_scope_display_label("Connected Slack workspace " <> _suffix),
    do: "the selected Slack workspace"

  defp slack_scope_display_label(label), do: label

  defp slack_workspace_option_label(account, team_id, index) do
    label =
      account
      |> Map.get(:account)
      |> normalize_blank()

    cond do
      is_nil(label) ->
        fallback_slack_workspace_label(index)

      raw_slack_identifier?(label, team_id) ->
        fallback_slack_workspace_label(index)

      true ->
        label
    end
  end

  defp fallback_slack_workspace_label(1), do: "Connected Slack workspace"
  defp fallback_slack_workspace_label(index), do: "Connected Slack workspace #{index}"

  defp slack_workspace_team_id(account) do
    account
    |> Map.get(:provider)
    |> normalize_blank()
    |> case do
      "slack:" <> rest ->
        rest
        |> String.split(":")
        |> List.first()
        |> normalize_blank()

      _ ->
        nil
    end
  end

  defp raw_slack_identifier?(label, team_id) do
    label == team_id or
      String.starts_with?(label, "slack:") or
      Regex.match?(~r/^[TE][A-Z0-9]{6,}$/i, label)
  end

  attr :id, :string, required: true
  attr :name, :string, required: true
  attr :label, :string, required: true
  attr :value, :any, default: nil
  attr :type, :string, default: "text"
  attr :description, :string, default: nil
  attr :placeholder, :string, default: nil
  attr :min, :any, default: nil
  attr :max, :any, default: nil
  attr :class, :string, default: nil
  attr :rest, :global

  defp launch_input(assigns) do
    ~H"""
    <.field label={@label} description={@description} for={@id} class={@class}>
      <.c_input
        id={@id}
        name={@name}
        type={@type}
        value={@value}
        min={@min}
        max={@max}
        placeholder={@placeholder}
        {@rest}
      />
    </.field>
    """
  end

  attr :id, :string, required: true
  attr :name, :string, required: true
  attr :label, :string, required: true
  attr :value, :any, default: nil
  attr :description, :string, default: nil
  attr :class, :string, default: nil
  attr :rest, :global
  slot :inner_block, required: true

  defp launch_select(assigns) do
    ~H"""
    <.field label={@label} description={@description} for={@id} class={@class}>
      <.c_select id={@id} name={@name} value={@value} {@rest}>
        <%= render_slot(@inner_block) %>
      </.c_select>
    </.field>
    """
  end

  attr :id, :string, required: true
  attr :name, :string, required: true
  attr :label, :string, required: true
  attr :value, :any, default: nil
  attr :rows, :integer, default: 4
  attr :description, :string, default: nil
  attr :class, :string, default: nil
  attr :textarea_class, :string, default: nil
  attr :rest, :global

  defp launch_textarea(assigns) do
    ~H"""
    <.field label={@label} description={@description} for={@id} class={@class}>
      <.c_textarea
        id={@id}
        name={@name}
        value={@value}
        rows={@rows}
        class={@textarea_class}
        {@rest}
      />
    </.field>
    """
  end

  defp current_user_id(socket), do: socket.assigns.current_user.id

  defp field_visible?(spec, field), do: field in spec.fields

  defp notification_selectivity_options("personal_assistant_agent", current_value) do
    [
      %{value: "0.86", label: "Selective - confirmed trips only"},
      %{value: "0.8", label: "Standard - clear trips and material changes"},
      %{value: "0.74", label: "Broad - catch more itinerary changes"}
    ]
    |> include_current_selectivity_option(current_value)
  end

  defp notification_selectivity_options("inbox_calendar_advisor", current_value) do
    [
      %{value: "0.8", label: "Selective - only clear, action-ready items"},
      %{value: "0.72", label: "Standard - balanced follow-through"},
      %{value: "0.66", label: "Broad - catch more possible loops"}
    ]
    |> include_current_selectivity_option(current_value)
  end

  defp notification_selectivity_options("slack_followthrough_agent", current_value) do
    [
      %{value: "0.82", label: "Selective - only explicit Slack commitments"},
      %{value: "0.75", label: "Standard - balanced Slack follow-through"},
      %{value: "0.68", label: "Broad - catch more possible Slack loops"}
    ]
    |> include_current_selectivity_option(current_value)
  end

  defp notification_selectivity_options(_behavior, current_value) do
    []
    |> include_current_selectivity_option(current_value)
  end

  defp include_current_selectivity_option(options, current_value) do
    current_value = to_string(current_value || "")

    cond do
      current_value == "" ->
        options

      Enum.any?(options, &(&1.value == current_value)) ->
        options

      true ->
        options ++ [%{value: current_value, label: "Custom - current saved setting"}]
    end
  end

  defp notification_selectivity_label(behavior, value) do
    behavior
    |> notification_selectivity_options(value)
    |> Enum.find(&(&1.value == to_string(value || "")))
    |> case do
      %{label: label} -> label |> String.split(" - ") |> List.first()
      _ -> "Standard"
    end
  end

  defp notification_selectivity_phrase(behavior, value) do
    behavior
    |> notification_selectivity_label(value)
    |> String.downcase()
  end

  defp spec_requirement_summary(%{requirements: []}), do: "No connected apps required."

  defp spec_requirement_summary(%{requirements: requirements}) do
    labels =
      requirements
      |> Enum.map(& &1.label)
      |> Enum.uniq()

    "Needs " <> Enum.join(labels, ", ")
  end

  defp hidden_control_count("advanced"), do: 0
  defp hidden_control_count(_mode), do: 3

  defp timezone_options, do: Timezones.options()

  defp launch_timezone_value(launch) when is_map(launch) do
    case normalize_blank(Map.get(launch, "timezone")) do
      nil ->
        launch
        |> launch_timezone_offset()
        |> Timezones.fixed_offset_value()

      timezone ->
        timezone
    end
  end

  defp launch_timezone_label(launch) when is_map(launch) do
    selected = launch_timezone_value(launch)

    timezone_options()
    |> Enum.find(&(&1.value == selected))
    |> case do
      %{label: label} -> label
      _ -> Timezones.offset_label(launch_timezone_offset(launch))
    end
  end

  defp launch_timezone_offset(launch) when is_map(launch) do
    case Integer.parse(to_string(Map.get(launch, "timezone_offset_hours", "-5"))) do
      {offset, ""} when offset in -12..14 -> offset
      _ -> -5
    end
  end

  defp cost_profile_label("lean"), do: "Lean"
  defp cost_profile_label("balanced"), do: "Balanced"
  defp cost_profile_label("thorough"), do: "Thorough"
  defp cost_profile_label(_profile), do: "Balanced"

  defp cost_profile_summary("prompt_agent", "lean"),
    do:
      "Lower memory and lighter checks. Best when you want a focused helper, not a constantly reasoning automation."

  defp cost_profile_summary("prompt_agent", "balanced"),
    do: "Keeps enough memory for steady reasoning while staying selective on each check."

  defp cost_profile_summary("prompt_agent", "thorough"),
    do: "Uses deeper memory for richer reasoning across longer-running conversations."

  defp cost_profile_summary("github_product_planner", "lean"),
    do: "Reviews the repo less often and keeps the shortlist tight for lightweight planning."

  defp cost_profile_summary("github_product_planner", "balanced"),
    do: "Daily planning pass with enough context to catch meaningful roadmap changes."

  defp cost_profile_summary("github_product_planner", "thorough"),
    do: "Checks more frequently with a larger planning window for fast-moving repositories."

  defp cost_profile_summary("ai_chief_of_staff", "lean"),
    do: "Fewer follow-through checks and selective travel alerts for a quieter assistant."

  defp cost_profile_summary("ai_chief_of_staff", "balanced"),
    do:
      "Good default coverage across follow-through, travel logistics, and recurring briefing without flooding you."

  defp cost_profile_summary("ai_chief_of_staff", "thorough"),
    do:
      "Broader follow-through coverage and faster travel checks for executives who want one proactive assistant."

  defp cost_profile_summary("inbox_calendar_advisor", "lean"),
    do:
      "Tighter Gmail, Calendar, and Slack review so only clear action-ready commitments reach you."

  defp cost_profile_summary("inbox_calendar_advisor", "balanced"),
    do:
      "Good default coverage across inbox, meetings, and Slack with standard notification selectivity."

  defp cost_profile_summary("inbox_calendar_advisor", "thorough"),
    do:
      "Broader cross-channel review and follow-through coverage for executives who want fewer missed follow-ups."

  defp cost_profile_summary("slack_followthrough_agent", "lean"),
    do: "Smaller channel and DM review with fewer Slack alerts."

  defp cost_profile_summary("slack_followthrough_agent", "balanced"),
    do: "Good default Slack coverage with practical urgency filtering."

  defp cost_profile_summary("slack_followthrough_agent", "thorough"),
    do: "Broader Slack coverage and faster checks when Slack is where most team work happens."

  defp cost_profile_summary(_behavior, "lean"),
    do: "Tighter review and fewer checks."

  defp cost_profile_summary(_behavior, "balanced"),
    do: "Default coverage for most teams."

  defp cost_profile_summary(_behavior, "thorough"),
    do: "Deeper coverage and more proactive behavior."

  defp parse_csv(""), do: []

  defp parse_csv(values) when is_binary(values) do
    values
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp parse_csv(_values), do: []

  defp normalize_blank(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      normalized -> normalized
    end
  end

  defp normalize_blank(_value), do: nil

  defp blank_fallback(value, fallback) when is_binary(value) do
    case String.trim(value) do
      "" -> fallback
      normalized -> normalized
    end
  end

  defp blank_fallback(_value, fallback), do: fallback

  defp behavior_card_class(true),
    do:
      "flex w-full items-start gap-3 bg-indigo-50 px-5 py-4 text-left transition hover:bg-indigo-50"

  defp behavior_card_class(false),
    do: "flex w-full items-start gap-3 bg-white px-5 py-4 text-left transition hover:bg-zinc-50"

  defp behavior_indicator_class(true),
    do: "mt-1 h-3 w-3 shrink-0 rounded-full bg-indigo-600 ring-4 ring-indigo-100"

  defp behavior_indicator_class(false),
    do: "mt-1 h-3 w-3 shrink-0 rounded-full border border-zinc-300 bg-white"

  defp builder_mode_button_class(true),
    do: "rounded-md bg-white px-3 py-1.5 text-sm font-medium text-zinc-950 shadow-sm"

  defp builder_mode_button_class(false),
    do: "rounded-md px-3 py-1.5 text-sm font-medium text-zinc-500 transition hover:text-zinc-700"

  defp cost_profile_card_class(true),
    do:
      "block cursor-pointer rounded-lg border border-violet-300 bg-white px-4 py-4 shadow-sm ring-2 ring-violet-200"

  defp cost_profile_card_class(false),
    do:
      "block cursor-pointer rounded-lg border border-violet-100 bg-white/80 px-4 py-4 transition hover:border-violet-200 hover:bg-white"

  defp readiness_badge_class(%{required?: true, ready?: true}),
    do: "rounded-md bg-emerald-100 px-2.5 py-1 text-xs font-medium text-emerald-800"

  defp readiness_badge_class(%{required?: true, ready?: false}),
    do: "rounded-md bg-rose-100 px-2.5 py-1 text-xs font-medium text-rose-800"

  defp readiness_badge_class(_item),
    do: "rounded-md bg-zinc-100 px-2.5 py-1 text-xs font-medium text-zinc-600"

  defp readiness_badge_text(%{required?: true, ready?: true}), do: "Ready"
  defp readiness_badge_text(%{required?: true, ready?: false}), do: "Blocked"
  defp readiness_badge_text(_item), do: "Optional"

  defp current_path_from_uri(uri) when is_binary(uri) do
    uri
    |> URI.parse()
    |> Map.get(:path)
    |> case do
      nil -> "/agents/new"
      "" -> "/agents/new"
      path -> path
    end
  end

  defp current_path_from_uri(_uri), do: "/agents/new"
end
