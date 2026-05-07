defmodule Maraithon.AgentArchitecture do
  @moduledoc """
  First-class architecture manifests for Maraithon agents.

  The runtime still executes behavior modules, but higher-level orchestration
  needs a stable way to inspect what an agent is made from before it is started:
  runtime owner, behavior module, internal skills, allowed tools, subscriptions,
  connector requirements, and optional project binding.
  """

  alias Maraithon.AgentBuilder
  alias Maraithon.Agents.Agent
  alias Maraithon.Behaviors
  alias Maraithon.ChiefOfStaff.Skills, as: ChiefOfStaffSkills
  alias Maraithon.Tools

  @runtime_component %{
    kind: :runtime,
    id: "otp_gen_state_machine",
    label: "OTP Agent Runtime",
    module: "Maraithon.Runtime.Agent",
    responsibility: "Owns the long-lived process, trigger routing, effect dispatch, and wakeups."
  }

  @memory_components [
    %{
      kind: :memory,
      id: "agent_events",
      label: "Agent Event Log",
      module: "Maraithon.Events",
      responsibility: "Persists runtime events for replay, inspection, and status answers."
    },
    %{
      kind: :memory,
      id: "user_memory",
      label: "User Memory",
      module: "Maraithon.UserMemory",
      responsibility: "Injects durable cross-agent operator context into every run."
    }
  ]

  @doc """
  List architecture manifests for every builder-visible behavior.
  """
  def list(opts \\ []) do
    AgentBuilder.behavior_specs()
    |> Enum.map(fn spec -> build_manifest(spec.id, opts) end)
  end

  @doc """
  Return the architecture manifest for one behavior id.
  """
  def get(behavior_id, opts \\ [])

  def get(behavior_id, opts) when is_binary(behavior_id) do
    if Behaviors.exists?(behavior_id) or builder_behavior?(behavior_id) do
      {:ok, build_manifest(behavior_id, opts)}
    else
      {:error, :unknown_behavior}
    end
  end

  def get(_behavior_id, _opts), do: {:error, :unknown_behavior}

  @doc """
  Build a manifest from a persisted agent row, including its project binding.
  """
  def for_agent(%Agent{} = agent) do
    {:ok,
     build_manifest(agent.behavior,
       config: agent.config || %{},
       project_id: agent.project_id,
       agent: agent
     )}
  end

  def for_agent(agent) when is_map(agent) do
    behavior = Map.get(agent, :behavior) || Map.get(agent, "behavior")

    if is_binary(behavior) do
      {:ok,
       build_manifest(behavior,
         config: Map.get(agent, :config) || Map.get(agent, "config") || %{},
         project_id: Map.get(agent, :project_id) || Map.get(agent, "project_id"),
         agent: agent
       )}
    else
      {:error, :unknown_behavior}
    end
  end

  @doc """
  Build a manifest from launch params before an agent exists.
  """
  def for_launch(launch) when is_map(launch) do
    behavior = Map.get(launch, "behavior") || Map.get(launch, :behavior) || "prompt_agent"
    config = launch_config_projection(behavior, launch)
    build_manifest(behavior, config: config, project_id: Map.get(launch, "project_id"))
  end

  @doc """
  Return stable headline metrics for architecture previews.
  """
  def metrics(architecture) when is_map(architecture) do
    [
      %{label: "Skills", value: component_count(architecture, :skill)},
      %{label: "Tools", value: component_count(architecture, :tool)},
      %{label: "Topics", value: component_count(architecture, :subscription)},
      %{label: "Memory", value: component_count(architecture, :memory)}
    ]
  end

  @doc """
  Return ordered components for compact UI previews.
  """
  def preview_components(architecture, opts \\ []) when is_map(architecture) do
    limit = Keyword.get(opts, :limit, 8)
    priority = [:runtime, :behavior, :skill, :tool, :subscription, :memory, :scope]

    architecture
    |> Map.get(:components, [])
    |> Enum.sort_by(fn component ->
      Enum.find_index(priority, &(&1 == component.kind)) || length(priority)
    end)
    |> Enum.take(limit)
  end

  @doc """
  Return concise display copy for a component.
  """
  def component_detail(component) when is_map(component) do
    Map.get(component, :responsibility) ||
      Map.get(component, :description) ||
      component_detail_from_metadata(component) ||
      "Configured as part of this agent contract."
  end

  defp build_manifest(behavior_id, opts) do
    spec = AgentBuilder.behavior_spec(behavior_id)
    config = Keyword.get(opts, :config, %{})
    project_id = Keyword.get(opts, :project_id)
    agent = Keyword.get(opts, :agent)
    behavior_module = Behaviors.get(behavior_id)

    components =
      [
        @runtime_component,
        behavior_component(behavior_id, behavior_module, spec)
      ] ++
        skill_components(behavior_id, config) ++
        tool_components(behavior_id, config) ++
        subscription_components(behavior_id, config) ++
        @memory_components ++
        project_components(project_id)

    %{
      id: spec.id,
      label: spec.label,
      category: spec.category,
      summary: spec.summary,
      behavior_module: inspect_module(behavior_module),
      runtime: %{
        process_module: "Maraithon.Runtime.Agent",
        supervisor_module: "Maraithon.Runtime.AgentSupervisor",
        registry_module: "Maraithon.Runtime.AgentRegistry",
        dispatch_module: "Maraithon.Runtime.Dispatch",
        scheduler_module: "Maraithon.Runtime.Scheduler"
      },
      contract: %{
        behaviour: "Maraithon.Behaviors.Behavior",
        callbacks: ~w(init handle_wakeup handle_effect_result next_wakeup),
        effect_types: ~w(llm_call tool_call)
      },
      components: components,
      capabilities: %{
        tools: component_ids(components, :tool),
        skills: component_ids(components, :skill),
        subscriptions: component_ids(components, :subscription),
        requirements: spec.requirements,
        inputs: spec.inputs,
        outputs: spec.outputs
      },
      controls: %{
        fields: spec.fields,
        simple_fields: Map.get(spec, :simple_fields, spec.fields),
        defaults: AgentBuilder.launch_params_for_behavior(spec.id)
      },
      binding: binding(agent, project_id)
    }
  end

  defp behavior_component(behavior_id, behavior_module, spec) do
    %{
      kind: :behavior,
      id: behavior_id,
      label: spec.label,
      module: inspect_module(behavior_module),
      responsibility: spec.summary
    }
  end

  defp skill_components("ai_chief_of_staff", config) do
    enabled_ids = ChiefOfStaffSkills.enabled_ids(config)

    ChiefOfStaffSkills.list_ids()
    |> Enum.map(fn skill_id ->
      module = ChiefOfStaffSkills.get!(skill_id)

      %{
        kind: :skill,
        id: skill_id,
        label: humanize_id(skill_id),
        module: inspect_module(module),
        enabled_by_default?: skill_id in enabled_ids,
        requirements: module.requirements(),
        subscriptions: safe_skill_subscriptions(module, config, skill_id)
      }
    end)
  end

  defp skill_components(_behavior_id, _config), do: []

  defp safe_skill_subscriptions(module, config, skill_id) do
    user_id = Map.get(config, "user_id") || Map.get(config, :user_id) || "user@example.com"
    skill_config = get_in(config, ["skill_configs", skill_id]) || %{}

    module.subscriptions(skill_config, user_id)
  rescue
    _ -> []
  end

  defp tool_components(behavior_id, config) do
    behavior_id
    |> configured_tools(config)
    |> Enum.map(fn tool_id ->
      descriptor = tool_descriptor(tool_id)

      %{
        kind: :tool,
        id: tool_id,
        label: tool_id,
        available?: Tools.exists?(tool_id),
        description: descriptor.description
      }
    end)
  end

  defp configured_tools("prompt_agent", config) do
    config
    |> Map.get("tools", default_launch_csv("prompt_agent", "tools"))
    |> normalize_list()
  end

  defp configured_tools("watchdog_summarizer", config) do
    if present?(Map.get(config, "check_url") || Map.get(config, :check_url)),
      do: ["http_get"],
      else: []
  end

  defp configured_tools("repo_planner", _config), do: ["read_file"]
  defp configured_tools(_behavior_id, _config), do: []

  defp subscription_components(behavior_id, config) do
    behavior_id
    |> configured_subscriptions(config)
    |> Enum.map(fn topic ->
      %{
        kind: :subscription,
        id: topic,
        label: topic,
        responsibility: "Routes matching PubSub events into this agent."
      }
    end)
  end

  defp configured_subscriptions("prompt_agent", config) do
    config
    |> Map.get("subscribe", Map.get(config, "subscriptions", ""))
    |> normalize_list()
  end

  defp configured_subscriptions("ai_chief_of_staff", config) do
    skill_configs = Map.get(config, "skill_configs") || %{}
    user_id = Map.get(config, "user_id") || Map.get(config, :user_id)

    if is_binary(user_id) and user_id != "" do
      ChiefOfStaffSkills.subscriptions(
        skill_configs,
        user_id,
        ChiefOfStaffSkills.enabled_ids(config)
      )
    else
      []
    end
  rescue
    _ -> []
  end

  defp configured_subscriptions(_behavior_id, config) do
    config
    |> Map.get("subscribe", [])
    |> normalize_list()
  end

  defp project_components(project_id) when is_binary(project_id) and project_id != "" do
    [
      %{
        kind: :scope,
        id: "project:#{project_id}",
        label: "Project Scope",
        responsibility: "Binds agent output and delivery runs to a Maraithon project."
      }
    ]
  end

  defp project_components(_project_id), do: []

  defp binding(nil, project_id), do: %{project_id: empty_to_nil(project_id)}

  defp binding(%Agent{} = agent, project_id) do
    %{
      agent_id: agent.id,
      user_id: agent.user_id,
      status: agent.status,
      project_id: empty_to_nil(project_id)
    }
  end

  defp binding(agent, project_id) when is_map(agent) do
    %{
      agent_id: Map.get(agent, :id) || Map.get(agent, "id"),
      user_id: Map.get(agent, :user_id) || Map.get(agent, "user_id"),
      status: Map.get(agent, :status) || Map.get(agent, "status"),
      project_id: empty_to_nil(project_id)
    }
  end

  defp launch_config_projection("prompt_agent", launch) do
    %{
      "tools" => Map.get(launch, "tools", ""),
      "subscribe" => Map.get(launch, "subscriptions", "")
    }
  end

  defp launch_config_projection("watchdog_summarizer", launch) do
    %{"check_url" => Map.get(launch, "check_url", "")}
  end

  defp launch_config_projection(_behavior, launch), do: Map.new(launch)

  defp component_ids(components, kind) do
    components
    |> Enum.filter(&(&1.kind == kind))
    |> Enum.map(& &1.id)
  end

  defp component_count(architecture, kind) do
    architecture
    |> Map.get(:components, [])
    |> Enum.count(&(&1.kind == kind))
    |> to_string()
  end

  defp component_detail_from_metadata(%{kind: :skill} = component) do
    requirements =
      component
      |> Map.get(:requirements, [])
      |> length()

    "Skill module with #{requirements} connector requirements."
  end

  defp component_detail_from_metadata(_component), do: nil

  defp tool_descriptor(tool_id) do
    %{
      description:
        if(Tools.exists?(tool_id),
          do: "Configured tool available through Maraithon.Tools.",
          else: "Unknown tool."
        )
    }
  end

  defp default_launch_csv(behavior_id, key) do
    behavior_id
    |> AgentBuilder.launch_params_for_behavior()
    |> Map.get(key, "")
  end

  defp builder_behavior?(behavior_id) do
    AgentBuilder.behavior_specs()
    |> Enum.any?(&(&1.id == behavior_id))
  end

  defp normalize_list(value) when is_list(value) do
    value
    |> Enum.map(&to_string/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp normalize_list(value) when is_binary(value) do
    value
    |> String.split(",")
    |> normalize_list()
  end

  defp normalize_list(_value), do: []

  defp inspect_module(nil), do: nil
  defp inspect_module(module) when is_atom(module), do: inspect(module)

  defp humanize_id(id) do
    id
    |> String.replace("_", " ")
    |> String.split(" ")
    |> Enum.map_join(" ", &String.capitalize/1)
  end

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(value), do: not is_nil(value)

  defp empty_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp empty_to_nil(value), do: value
end
