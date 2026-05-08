defmodule MaraithonWeb.AgentBuilderLive do
  use MaraithonWeb, :live_view

  alias Maraithon.AgentArchitecture
  alias Maraithon.AgentBuilder
  alias Maraithon.Connections
  alias Maraithon.Projects
  alias Maraithon.Runtime
  alias Maraithon.Runtime.Config, as: RuntimeConfig

  @tool_provider_requirements %{
    "gmail_get_message" => %{provider: "google", service: "gmail", label: "Google Gmail"},
    "gmail_list_recent" => %{provider: "google", service: "gmail", label: "Google Gmail"},
    "gmail_search" => %{provider: "google", service: "gmail", label: "Google Gmail"},
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
        page_title: "Build Agent",
        current_path: "/agents/new",
        behavior_specs: AgentBuilder.behavior_specs(),
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
       |> put_flash(:info, "Agent #{String.slice(agent.id, 0, 8)} created")
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
         |> assign(:builder_error, "Failed to create agent: #{changeset_errors(changeset)}")}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign_builder_state(launch)
         |> assign(:builder_error, "Failed to create agent: #{inspect(reason)}")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_path={@current_path} current_user={@current_user}>
      <div class="space-y-5">
        <section class="border-b border-zinc-950/10 pb-5">
          <div class="flex flex-wrap items-start justify-between gap-4">
            <div class="max-w-3xl">
              <p class="text-sm font-medium text-zinc-500">Agent builder</p>
              <h1 class="mt-1 text-2xl font-semibold tracking-tight text-zinc-950 sm:text-3xl">
                Create a new agent
              </h1>
              <p class="mt-2 max-w-2xl text-sm text-zinc-600">
                Choose the job, confirm the connected apps it can use, then launch it.
              </p>
            </div>

            <div class="flex flex-wrap gap-2">
              <.button href={~p"/connectors"} variant="outline">
                Connectors
              </.button>
              <.button href={~p"/agents"}>
                Back to agents
              </.button>
            </div>
          </div>
        </section>

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
                    <h2 class="text-base font-semibold text-zinc-950">Setup</h2>
                    <p class="mt-1 text-sm text-zinc-500">
                      Configure only what this template needs. Advanced keeps the lower-level controls available.
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
                    <p class="font-medium">Focused setup</p>
                    <p class="mt-1 text-sky-900/80">
                      Set the name, scope, and coverage. <%= @hidden_simple_count %> advanced settings stay on defaults unless you open Advanced.
                    </p>
                  </div>
                <% end %>

                <div class="grid grid-cols-1 gap-4 md:grid-cols-[minmax(0,1fr)_minmax(260px,0.8fr)]">
                  <div>
                    <label for="launch_name" class="block text-sm font-medium text-zinc-700">
                      Agent name
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
                          Attach this agent to a project so Maraithon can use its output when you ask about that project in chat.
                        </p>
                      </div>

                      <div class="rounded-lg border border-white/70 bg-white px-4 py-3">
                        <p class="text-xs font-semibold text-emerald-700">
                          Why this matters
                        </p>
                        <p class="mt-2 text-sm text-zinc-700">
                          Project-scoped agents feed local project state instead of disappearing into global noise. This is especially important for the project manager and coding agent flows.
                        </p>
                      </div>
                    </div>
                  </div>
                <% end %>

                <%= if field_visible?(@selected_spec, "cost_profile") do %>
                  <div class="space-y-4 rounded-lg border border-violet-200 bg-violet-50/60 p-4">
                    <div>
                      <p class="text-sm font-medium text-violet-950">Coverage and spend</p>
                      <p class="mt-1 text-xs text-violet-900/80">
                        Pick how aggressive Maraithon should be. This drives the hidden scan limits, cadence, memory, and budgets for this template.
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
                  label="Prompt"
                  value={@launch["prompt"]}
                  rows={5}
                  description="Define how the agent should reason, what tone it should use, and which actions it should avoid."
                />

                <%= if field_visible?(@selected_spec, "subscriptions") or field_visible?(@selected_spec, "tools") do %>
                  <div class="grid grid-cols-1 gap-4 md:grid-cols-2">
                    <%= if field_visible?(@selected_spec, "subscriptions") do %>
                      <.launch_input
                        id="launch_subscriptions"
                        name="launch[subscriptions]"
                        label="Input subscriptions"
                        value={@launch["subscriptions"]}
                        placeholder="github:owner/repo,email:kent"
                        description="Comma-separated topics. Leave blank if the agent should only react to direct operator messages."
                      />
                    <% end %>

                    <%= if field_visible?(@selected_spec, "tools") do %>
                      <.launch_input
                        id="launch_tools"
                        name="launch[tools]"
                        label="Allowed tools"
                        value={@launch["tools"]}
                        placeholder="read_file,search_files,http_get"
                        description="Comma-separated tool allowlist. Any tool not listed here is off-limits to the agent."
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
                      label="Memory limit"
                      value={@launch["memory_limit"]}
                      description="How many recent events the prompt agent keeps in rolling memory."
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
                        description="Comma-separated glob patterns that define the files the agent may inspect."
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
                    description="If set, the watchdog will periodically issue http_get checks against this URL."
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
                        description="How many roadmap opportunities the planner should surface in each daily batch."
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
                        label="Email scan limit"
                        value={@launch["email_scan_limit"]}
                      />
                    <% end %>

                    <%= if field_visible?(@selected_spec, "event_scan_limit") do %>
                      <.launch_input
                        id="launch_event_scan_limit"
                        type="number"
                        min="1"
                        name="launch[event_scan_limit]"
                        label="Event scan limit"
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
                        label="Max insights per cycle"
                        value={@launch["max_insights_per_cycle"]}
                      />
                    <% end %>

                    <%= if field_visible?(@selected_spec, "min_confidence") do %>
                      <.launch_input
                        id="launch_min_confidence"
                        name="launch[min_confidence]"
                        label="Minimum confidence"
                        value={@launch["min_confidence"]}
                      />
                    <% end %>
                  </div>
                <% end %>

                <%= if field_visible?(@selected_spec, "team_id") or field_visible?(@selected_spec, "channel_scan_limit") or field_visible?(@selected_spec, "dm_scan_limit") or field_visible?(@selected_spec, "lookback_hours") do %>
                  <div class="grid grid-cols-1 gap-4 md:grid-cols-2 xl:grid-cols-3">
                    <%= if field_visible?(@selected_spec, "team_id") do %>
                      <.launch_input
                        id="launch_team_id"
                        name="launch[team_id]"
                        label="Slack team ID"
                        value={@launch["team_id"]}
                        placeholder="T01234567"
                        description="Leave blank to scan every connected workspace; set this to pin the agent to one team."
                      />
                    <% end %>

                    <%= if field_visible?(@selected_spec, "channel_scan_limit") do %>
                      <.launch_input
                        id="launch_channel_scan_limit"
                        type="number"
                        min="1"
                        name="launch[channel_scan_limit]"
                        label="Channel message scan limit"
                        value={@launch["channel_scan_limit"]}
                      />
                    <% end %>

                    <%= if field_visible?(@selected_spec, "dm_scan_limit") do %>
                      <.launch_input
                        id="launch_dm_scan_limit"
                        type="number"
                        min="1"
                        name="launch[dm_scan_limit]"
                        label="DM message scan limit"
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
                        type="number"
                        min="1"
                        name="launch[wakeup_interval_ms]"
                        label="Wakeup interval (ms)"
                        value={@launch["wakeup_interval_ms"]}
                        description="How frequently the behavior wakes up to continue work or check for new tasks."
                      />
                    <% end %>

                    <%= if field_visible?(@selected_spec, "write_plan_files") do %>
                      <.launch_select
                        id="launch_write_plan_files"
                        name="launch[write_plan_files]"
                        label="Write plan files"
                        value={@launch["write_plan_files"]}
                        description="When enabled, generated plans are written to disk in addition to runtime notes."
                      >
                          <option value="true" selected={@launch["write_plan_files"] == "true"}>Yes</option>
                          <option value="false" selected={@launch["write_plan_files"] == "false"}>No</option>
                      </.launch_select>
                    <% end %>
                  </div>
                <% end %>

                <%= if field_visible?(@selected_spec, "timezone_offset_hours") or field_visible?(@selected_spec, "morning_brief_hour_local") or field_visible?(@selected_spec, "end_of_day_brief_hour_local") or field_visible?(@selected_spec, "weekly_review_day_local") or field_visible?(@selected_spec, "weekly_review_hour_local") or field_visible?(@selected_spec, "brief_max_items") do %>
                  <div class="space-y-4 rounded-lg border border-emerald-200 bg-emerald-50/50 p-4">
                    <div>
                      <p class="text-sm font-medium text-emerald-950">Chief-of-Staff Briefing</p>
                      <p class="mt-1 text-xs text-emerald-900/80">
                        Configure the daily and weekly summary cadence that lands in Telegram in addition to interrupt-driven nudges.
                      </p>
                    </div>

                    <div class="grid grid-cols-1 gap-4 md:grid-cols-2 xl:grid-cols-3">
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
                          max="5"
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
                      label="LLM call budget"
                      value={@launch["budget_llm_calls"]}
                    />

                    <.launch_input
                      id="launch_budget_tool_calls"
                      type="number"
                      min="1"
                      name="launch[budget_tool_calls]"
                      label="Tool call budget"
                      value={@launch["budget_tool_calls"]}
                    />
                  </div>

                  <.launch_textarea
                    id="launch_config_json"
                    name="launch[config_json]"
                    label="Advanced JSON overrides"
                    value={@launch["config_json"]}
                    rows={6}
                    textarea_class="font-mono"
                    description="Optional object merged into the final config after the form values above. Use this for advanced behavior-specific keys."
                  />
                <% end %>

                <div class="flex flex-wrap items-center justify-between gap-3 border-t border-zinc-950/10 pt-5">
                  <div class="text-sm text-zinc-500">
                    <%= if @blockers == [] do %>
                      Ready to create. Maraithon will persist the agent and start it right away.
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
                    Create Agent
                  </.button>
                </div>
              </form>
            </section>
          </div>

          <aside class="space-y-5 xl:sticky xl:top-5 xl:self-start">
            <section class="rounded-lg border border-zinc-950/10 bg-white p-5 shadow-sm">
              <p class="text-sm font-semibold text-zinc-950">What goes in</p>
              <div class="mt-3 divide-y divide-zinc-950/5">
                <div :for={item <- @input_preview} class="py-3 first:pt-0 last:pb-0">
                  <p class="text-sm font-medium text-zinc-950"><%= item.title %></p>
                  <p class="mt-1 text-sm leading-6 text-zinc-600"><%= item.body %></p>
                </div>
              </div>
            </section>

            <section class="rounded-lg border border-zinc-950/10 bg-white p-5 shadow-sm">
              <p class="text-sm font-semibold text-zinc-950">What comes out</p>
              <div class="mt-3 divide-y divide-zinc-950/5">
                <div :for={item <- @output_preview} class="py-3 first:pt-0 last:pb-0">
                  <p class="text-sm font-medium text-zinc-950"><%= item.title %></p>
                  <p class="mt-1 text-sm leading-6 text-zinc-600"><%= item.body %></p>
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

    readiness_items =
      readiness_items(
        selected_spec_full,
        launch,
        socket.assigns.provider_map,
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
      input_preview: input_preview(selected_spec_full, launch),
      output_preview: output_preview(selected_spec_full, launch),
      architecture: AgentArchitecture.for_launch(launch),
      starter_values: starter_values(selected_spec_full, launch)
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
            description: "This template can run without OAuth grants or special setup.",
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
            description: "Needed because the selected tool list includes file-reading tools.",
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
        description: "The watchdog will probe the configured endpoint every sixth wakeup.",
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
          do: "Ready. #{value} exists on the runtime host.",
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

  defp input_preview(spec, launch) do
    base =
      spec.inputs
      |> Enum.with_index(1)
      |> Enum.map(fn {line, index} ->
        %{title: "Input #{index}", body: line}
      end)

    base ++ dynamic_input_preview(spec.id, launch)
  end

  defp dynamic_input_preview("prompt_agent", launch) do
    subscriptions =
      case launch["subscriptions"] do
        "" ->
          "No subscriptions yet. This agent will only react to direct operator messages until you add topics."

        value ->
          "Subscribed topics: #{value}"
      end

    tools =
      case launch["tools"] do
        "" -> "No tools enabled. The agent will stay text-only."
        value -> "Allowed tools: #{value}"
      end

    [
      %{
        title: "Operating profile",
        body: cost_profile_summary("prompt_agent", launch["cost_profile"])
      },
      %{title: "Current subscriptions", body: subscriptions},
      %{title: "Current tool allowlist", body: tools}
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
        title: "Plan persistence",
        body:
          if(launch["write_plan_files"] == "true",
            do: "Plans will also be written to #{launch["output_path"]}",
            else: "Plans will stay in runtime state unless you enable plan files."
          )
      }
    ]
  end

  defp dynamic_input_preview("watchdog_summarizer", launch) do
    [
      %{
        title: "Heartbeat cadence",
        body: "Wakes up every #{launch["wakeup_interval_ms"]} ms to emit summaries."
      },
      %{
        title: "URL check",
        body:
          if(launch["check_url"] == "",
            do: "No URL configured. The watchdog will only emit internal summaries.",
            else: "Configured endpoint: #{launch["check_url"]}"
          )
      }
    ]
  end

  defp dynamic_input_preview("inbox_calendar_advisor", launch) do
    [
      %{
        title: "Operating profile",
        body: cost_profile_summary("inbox_calendar_advisor", launch["cost_profile"])
      },
      %{
        title: "Scan coverage",
        body:
          "Checks up to #{launch["email_scan_limit"]} inbox emails, #{launch["event_scan_limit"]} calendar events, #{launch["channel_scan_limit"]} Slack channel messages, and #{launch["dm_scan_limit"]} Slack DM messages each cycle."
      },
      %{
        title: "Workspace scope",
        body:
          if(launch["team_id"] == "",
            do: "Scanning all connected Slack teams for unresolved commitments.",
            else: "Scoped to Slack team #{launch["team_id"]}."
          )
      },
      %{
        title: "Insight tuning",
        body:
          "Email/calendar follow-up window: #{launch["prep_window_hours"]}h. Slack lookback: #{launch["lookback_hours"]}h. Max insights: #{launch["max_insights_per_cycle"]}, minimum confidence: #{launch["min_confidence"]}."
      }
    ]
  end

  defp dynamic_input_preview("ai_chief_of_staff", launch) do
    [
      %{
        title: "Operating profile",
        body: cost_profile_summary("ai_chief_of_staff", launch["cost_profile"])
      },
      %{
        title: "Built-in skills",
        body:
          "Runs follow-through, travel logistics, and recurring briefing inside one assistant."
      },
      %{
        title: "Slack scope",
        body:
          if(launch["team_id"] == "",
            do: "Scanning all connected Slack teams for the follow-through skill.",
            else: "Scoped to Slack team #{launch["team_id"]} for follow-through."
          )
      },
      %{
        title: "Brief timing",
        body:
          "Uses timezone offset #{blank_fallback(launch["timezone_offset_hours"], "-5")} with morning brief #{launch["morning_brief_hour_local"]}:00 and end-of-day brief #{launch["end_of_day_brief_hour_local"]}:00."
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
        title: "Travel scan coverage",
        body:
          "Checks up to #{launch["email_scan_limit"]} Gmail travel candidates and #{launch["event_scan_limit"]} calendar events over the last #{launch["lookback_hours"]} hours."
      },
      %{
        title: "Delivery timing",
        body:
          "Computes the send window from the trip start time, then delivers the day-before brief in your local offset (#{blank_fallback(launch["timezone_offset_hours"], "-5")})."
      },
      %{
        title: "Confidence gate",
        body:
          "Requires a minimum itinerary confidence of #{launch["min_confidence"]} before interrupting you."
      }
    ]
  end

  defp dynamic_input_preview("slack_followthrough_agent", launch) do
    [
      %{
        title: "Operating profile",
        body: cost_profile_summary("slack_followthrough_agent", launch["cost_profile"])
      },
      %{
        title: "Workspace scope",
        body:
          if(launch["team_id"] == "",
            do: "Scanning all connected Slack teams.",
            else: "Scoped to Slack team #{launch["team_id"]}."
          )
      },
      %{
        title: "Scan coverage",
        body:
          "Checks up to #{launch["channel_scan_limit"]} channel messages and #{launch["dm_scan_limit"]} DM messages over the last #{launch["lookback_hours"]} hours each cycle."
      },
      %{
        title: "Escalation tuning",
        body:
          "Max insights: #{launch["max_insights_per_cycle"]}, minimum confidence: #{launch["min_confidence"]}."
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
            do: "No repository selected yet. Add one in `owner/repo` format.",
            else:
              "Reviewing #{launch["repo_full_name"]} on branch #{blank_fallback(launch["base_branch"], "main")}."
          )
      },
      %{
        title: "Daily planning scope",
        body:
          "The planner will shortlist #{blank_fallback(launch["feature_limit"], "3")} feature opportunities per cycle."
      }
    ]
  end

  defp dynamic_input_preview(_behavior, _launch), do: []

  defp output_preview(spec, launch) do
    (spec.outputs
     |> Enum.with_index(1)
     |> Enum.map(fn {line, index} ->
       %{title: "Output #{index}", body: line}
     end)) ++ dynamic_output_preview(spec.id, launch)
  end

  defp dynamic_output_preview("prompt_agent", launch) do
    [
      %{
        title: "Launch effect",
        body:
          "The agent is created in running state with LLM budget #{launch["budget_llm_calls"]} and tool budget #{launch["budget_tool_calls"]}."
      }
    ]
  end

  defp dynamic_output_preview("ai_chief_of_staff", _launch) do
    [
      %{
        title: "Stored records",
        body:
          "The assistant can persist both follow-through insights and travel-related brief artifacts under one agent identity."
      }
    ]
  end

  defp dynamic_output_preview("inbox_calendar_advisor", _launch) do
    [
      %{
        title: "Stored records",
        body:
          "Each insight stores a structured commitment record with evidence and next action, unified across Gmail, Calendar, and Slack sources."
      }
    ]
  end

  defp dynamic_output_preview("personal_assistant_agent", _launch) do
    [
      %{
        title: "Stored records",
        body:
          "Each trip persists a travel itinerary plus normalized flight and hotel items, then routes the prep brief through Telegram."
      }
    ]
  end

  defp dynamic_output_preview("slack_followthrough_agent", _launch) do
    [
      %{
        title: "Stored records",
        body:
          "Each unresolved Slack commitment persists a structured record with commitment, person, source, deadline, status, evidence, and next_action."
      }
    ]
  end

  defp dynamic_output_preview("codebase_advisor", launch) do
    [
      %{title: "Primary artifact", body: "Recommendation report path: #{launch["output_path"]}"}
    ]
  end

  defp dynamic_output_preview("repo_planner", launch) do
    [
      %{
        title: "Primary artifact",
        body:
          if(launch["write_plan_files"] == "true",
            do:
              "Plans are written into #{launch["output_path"]} and also emitted as runtime notes.",
            else: "Plans remain in runtime notes unless you enable plan file writing."
          )
      }
    ]
  end

  defp dynamic_output_preview("github_product_planner", launch) do
    [
      %{
        title: "Telegram push behavior",
        body:
          "High-signal roadmap suggestions for #{blank_fallback(launch["repo_full_name"], "the selected repository")} are stored as insights and sent through the Telegram notification pipeline."
      }
    ]
  end

  defp dynamic_output_preview(_behavior, _launch), do: []

  defp starter_values(spec, launch) do
    case spec.id do
      "ai_chief_of_staff" ->
        [
          %{label: "Cost profile", value: cost_profile_label(launch["cost_profile"])},
          %{
            label: "Slack team",
            value: if(launch["team_id"] == "", do: "All connected teams", else: launch["team_id"])
          },
          %{
            label: "Timezone",
            value: blank_fallback(launch["timezone_offset_hours"], "-5")
          },
          %{label: "Brief max items", value: launch["brief_max_items"]}
        ]

      "prompt_agent" ->
        [
          %{
            label: "Cost profile",
            value:
              launch["cost_profile"]
              |> cost_profile_label()
              |> Kernel.<>(" agent spend")
          },
          %{label: "Memory limit", value: launch["memory_limit"] <> " events"},
          %{label: "LLM call budget", value: launch["budget_llm_calls"]},
          %{label: "Tool call budget", value: launch["budget_tool_calls"]}
        ]

      "inbox_calendar_advisor" ->
        [
          %{label: "Cost profile", value: cost_profile_label(launch["cost_profile"])},
          %{label: "Email scan limit", value: launch["email_scan_limit"]},
          %{label: "Event scan limit", value: launch["event_scan_limit"]},
          %{
            label: "Slack team",
            value: if(launch["team_id"] == "", do: "All connected teams", else: launch["team_id"])
          },
          %{label: "Slack DM scan", value: launch["dm_scan_limit"]}
        ]

      "personal_assistant_agent" ->
        [
          %{label: "Cost profile", value: cost_profile_label(launch["cost_profile"])},
          %{label: "Email scan limit", value: launch["email_scan_limit"]},
          %{label: "Calendar scan limit", value: launch["event_scan_limit"]},
          %{label: "Lookback", value: launch["lookback_hours"] <> " hours"},
          %{label: "Min confidence", value: launch["min_confidence"]}
        ]

      "slack_followthrough_agent" ->
        [
          %{label: "Cost profile", value: cost_profile_label(launch["cost_profile"])},
          %{
            label: "Slack team",
            value: if(launch["team_id"] == "", do: "All connected teams", else: launch["team_id"])
          },
          %{label: "Channel scan limit", value: launch["channel_scan_limit"]},
          %{label: "DM scan limit", value: launch["dm_scan_limit"]}
        ]

      "codebase_advisor" ->
        [
          %{label: "Codebase path", value: launch["codebase_path"]},
          %{label: "Wakeup interval", value: launch["wakeup_interval_ms"] <> " ms"},
          %{label: "Output path", value: launch["output_path"]}
        ]

      "repo_planner" ->
        [
          %{label: "Codebase path", value: launch["codebase_path"]},
          %{
            label: "Write plan files",
            value: if(launch["write_plan_files"] == "true", do: "Yes", else: "No")
          },
          %{label: "Wakeup interval", value: launch["wakeup_interval_ms"] <> " ms"}
        ]

      "watchdog_summarizer" ->
        [
          %{label: "Wakeup interval", value: launch["wakeup_interval_ms"] <> " ms"},
          %{
            label: "Optional URL",
            value: if(launch["check_url"] == "", do: "None", else: launch["check_url"])
          },
          %{label: "Tool budget", value: launch["budget_tool_calls"]}
        ]

      "github_product_planner" ->
        [
          %{label: "Cost profile", value: cost_profile_label(launch["cost_profile"])},
          %{
            label: "Repository",
            value: blank_fallback(launch["repo_full_name"], "Set `owner/repo`")
          },
          %{
            label: "Daily shortlist",
            value: blank_fallback(launch["feature_limit"], "3") <> " features"
          },
          %{label: "Wakeup interval", value: launch["wakeup_interval_ms"] <> " ms"}
        ]

      _ ->
        [
          %{label: "LLM call budget", value: launch["budget_llm_calls"]},
          %{label: "Tool call budget", value: launch["budget_tool_calls"]}
        ]
    end
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

  defp cost_profile_label("lean"), do: "Lean"
  defp cost_profile_label("balanced"), do: "Balanced"
  defp cost_profile_label("thorough"), do: "Thorough"
  defp cost_profile_label(_profile), do: "Balanced"

  defp cost_profile_summary("prompt_agent", "lean"),
    do:
      "Lower memory and lower budgets. Best when you want a lightweight helper, not a constantly reasoning agent."

  defp cost_profile_summary("prompt_agent", "balanced"),
    do:
      "Keeps enough memory and budget for steady reasoning without overspending on every wakeup."

  defp cost_profile_summary("prompt_agent", "thorough"),
    do:
      "Uses deeper memory and higher budgets for richer reasoning across longer-running conversations."

  defp cost_profile_summary("github_product_planner", "lean"),
    do: "Reviews the repo less often and keeps the shortlist tight to minimize daily spend."

  defp cost_profile_summary("github_product_planner", "balanced"),
    do: "Daily planning pass with enough budget to catch meaningful roadmap changes."

  defp cost_profile_summary("github_product_planner", "thorough"),
    do: "Checks more frequently with a larger planning budget for fast-moving repositories."

  defp cost_profile_summary("ai_chief_of_staff", "lean"),
    do:
      "Smaller follow-through scans, a tighter travel confidence gate, and lower assistant-wide spend."

  defp cost_profile_summary("ai_chief_of_staff", "balanced"),
    do:
      "Good default coverage across follow-through, travel logistics, and recurring briefing without turning every cycle into a deep crawl."

  defp cost_profile_summary("ai_chief_of_staff", "thorough"),
    do:
      "Broader follow-through coverage, faster travel checks, and higher assistant-wide budget for founders who want one proactive operating layer."

  defp cost_profile_summary("inbox_calendar_advisor", "lean"),
    do:
      "Tighter Gmail, Calendar, and Slack scans with a higher confidence bar so only the clearest open loops interrupt you."

  defp cost_profile_summary("inbox_calendar_advisor", "balanced"),
    do:
      "Good default coverage across inbox, meetings, and Slack with moderate spend and a practical interruption threshold."

  defp cost_profile_summary("inbox_calendar_advisor", "thorough"),
    do:
      "Deeper cross-channel scans, lower confidence threshold, and more budget for founders who want broader followthrough coverage."

  defp cost_profile_summary("slack_followthrough_agent", "lean"),
    do: "Smaller channel and DM scans with fewer interrupts and the lowest recurring cost."

  defp cost_profile_summary("slack_followthrough_agent", "balanced"),
    do:
      "Good default Slack coverage with moderate scanning depth and practical urgency filtering."

  defp cost_profile_summary("slack_followthrough_agent", "thorough"),
    do:
      "Broader Slack coverage, faster wakeups, and more budget when Slack is your main operating system."

  defp cost_profile_summary(_behavior, "lean"),
    do: "Lower spend with tighter scans and fewer wakeups."

  defp cost_profile_summary(_behavior, "balanced"),
    do: "Default spend and coverage for most teams."

  defp cost_profile_summary(_behavior, "thorough"),
    do: "Higher spend for deeper coverage and more proactive behavior."

  defp parse_csv(""), do: []

  defp parse_csv(values) when is_binary(values) do
    values
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp parse_csv(_values), do: []

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
end
