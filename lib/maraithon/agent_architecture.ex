defmodule Maraithon.AgentArchitecture do
  @moduledoc """
  First-class architecture manifests for Maraithon agents.

  The runtime still executes behavior modules, but higher-level orchestration
  needs a stable way to inspect what an agent is made from before it is started:
  runtime owner, behavior module, internal skills, allowed tools, subscriptions,
  connector requirements, and optional project binding.
  """

  alias Maraithon.AgentBuilder
  alias Maraithon.AgentHarness.Manifest
  alias Maraithon.AgentHarness.ToolCatalog
  alias Maraithon.Agents
  alias Maraithon.Agents.Agent
  alias Maraithon.Agents.AgentPackage
  alias Maraithon.Agents.AgentPackageVersion
  alias Maraithon.Behaviors
  alias Maraithon.ChiefOfStaff.Skills, as: ChiefOfStaffSkills
  alias Maraithon.Tools

  @runtime_component %{
    kind: :runtime,
    id: "otp_gen_state_machine",
    label: "Maraithon Automation Service",
    module: "Maraithon.Runtime.Agent",
    responsibility: "Keeps the automation running, routes new work, and schedules follow-up."
  }

  @memory_components [
    %{
      kind: :memory,
      id: "agent_events",
      label: "Run History",
      module: "Maraithon.Events",
      responsibility:
        "Keeps a durable history of agent activity for review, status, and recovery."
    },
    %{
      kind: :memory,
      id: "user_memory",
      label: "Operator Memory",
      module: "Maraithon.UserMemory",
      responsibility: "Carries stable preferences and context into each run."
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
    case package_architecture(agent) do
      {:ok, architecture} ->
        {:ok, architecture}

      :no_package ->
        {:ok,
         build_manifest(agent.behavior,
           config: agent.config || %{},
           project_id: agent.project_id,
           agent: agent
         )}

      {:error, reason} ->
        {:error, reason}
    end
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
      %{label: "Actions", value: component_count(architecture, :tool)},
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
    |> Enum.with_index()
    |> Enum.sort_by(fn {component, index} ->
      {Enum.find_index(priority, &(&1 == component.kind)) || length(priority), index}
    end)
    |> Enum.map(fn {component, _index} -> component end)
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

  defp package_architecture(%Agent{agent_package_version_id: nil}), do: :no_package

  defp package_architecture(%Agent{} = agent) do
    with {:ok, version} <- package_version_for_agent(agent),
         {:ok, manifest} <- Manifest.build(version) do
      package = package_for_agent(agent, version)
      {:ok, build_package_manifest(agent, package, version, manifest)}
    end
  end

  defp package_version_for_agent(%Agent{agent_package_version: %AgentPackageVersion{} = version}) do
    {:ok, version}
  end

  defp package_version_for_agent(%Agent{agent_package_version_id: version_id})
       when is_binary(version_id) do
    case Agents.get_agent_package_version(version_id, preload: [:agent_package]) do
      %AgentPackageVersion{} = version -> {:ok, version}
      nil -> {:error, :package_version_not_found}
    end
  end

  defp package_version_for_agent(_agent), do: :no_package

  defp package_for_agent(%Agent{agent_package: %AgentPackage{} = package}, _version), do: package

  defp package_for_agent(_agent, %AgentPackageVersion{agent_package: %AgentPackage{} = package}),
    do: package

  defp package_for_agent(_agent, _version), do: nil

  defp build_package_manifest(agent, package, version, manifest) do
    components =
      [
        @runtime_component,
        behavior_component(
          version.behavior,
          Behaviors.get(version.behavior),
          package_behavior_spec(package, version)
        )
      ] ++
        package_skill_components(manifest) ++
        package_tool_components(manifest) ++
        package_connector_components(manifest) ++
        @memory_components ++
        project_components(agent.project_id)

    %{
      id: package_slug(package, version),
      label: package_name(package, version),
      category: package_category(package),
      summary: package_summary(package, version),
      behavior_module: inspect_module(Behaviors.get(version.behavior)),
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
      manifest: package_manifest_envelope(version, manifest),
      components: components,
      capabilities: %{
        tools: component_ids(components, :tool),
        skills: component_ids(components, :skill),
        subscriptions: component_ids(components, :subscription),
        requirements: Manifest.get(manifest, :required_connectors, %{}),
        inputs: [],
        outputs: []
      },
      controls: %{
        fields: [],
        simple_fields: [],
        defaults: version.default_config || %{}
      },
      binding: binding(agent, agent.project_id)
    }
  end

  defp package_behavior_spec(package, version) do
    %{
      label: package_name(package, version),
      summary: package_summary(package, version)
    }
  end

  defp package_manifest_envelope(version, manifest) do
    %{
      package_version_id: version.id,
      version: version.version,
      behavior: version.behavior,
      system_prompt: version.system_prompt,
      model: Manifest.get(manifest, :model),
      intelligence: Manifest.get(manifest, :intelligence),
      goals: Manifest.get(manifest, :goals, []),
      skills: Enum.map(Manifest.get(manifest, :skills, []), &skill_envelope/1),
      required_connectors: Manifest.get(manifest, :required_connectors, %{}),
      tool_allowlist: Manifest.get(manifest, :tool_allowlist, []),
      mcp_allowlist: Manifest.get(manifest, :mcp_allowlist, []),
      default_config: Manifest.get(manifest, :default_config, %{})
    }
  end

  defp skill_envelope(skill) do
    %{
      id: skill.id,
      name: skill.name,
      description: skill.description,
      path: skill.path,
      connectors: skill.connectors,
      tools: skill.tools
    }
  end

  defp package_skill_components(manifest) do
    manifest
    |> Manifest.get(:skills, [])
    |> Enum.map(fn skill ->
      %{
        kind: :skill,
        id: skill.id,
        label: skill.name,
        path: skill.path,
        enabled_by_default?: true,
        requirements: skill.connectors,
        tools: skill.tools,
        description: skill.description
      }
    end)
  end

  defp package_tool_components(manifest) do
    manifest
    |> Manifest.get(:tool_allowlist, [])
    |> ToolCatalog.describe()
    |> Enum.map(fn descriptor ->
      %{
        kind: :tool,
        id: descriptor.name,
        label: action_label(descriptor),
        connector: descriptor.connector,
        action: descriptor.action,
        available?: ToolCatalog.known_tool?(descriptor.name),
        description: "Approved for this agent package."
      }
    end)
  end

  defp package_connector_components(manifest) do
    manifest
    |> Manifest.get(:required_connectors, %{})
    |> Enum.map(fn {provider, requirements} ->
      %{
        kind: :connector,
        id: provider,
        label: humanize_id(provider),
        requirements: requirements,
        responsibility: "Required connection for this agent."
      }
    end)
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
    skill_ids = Enum.uniq(enabled_ids ++ ChiefOfStaffSkills.list_ids())

    skill_ids
    |> Enum.map(fn skill_id ->
      module = ChiefOfStaffSkills.get!(skill_id)

      %{
        kind: :skill,
        id: skill_id,
        label: skill_component_label(skill_id),
        module: inspect_module(module),
        enabled_by_default?: skill_id in enabled_ids,
        description: ChiefOfStaffSkills.description(skill_id),
        requirements: module.requirements(),
        subscriptions: safe_skill_subscriptions(module, config, skill_id)
      }
    end)
  end

  defp skill_components(_behavior_id, _config), do: []

  defp skill_component_label("followthrough"), do: "Follow-through"
  defp skill_component_label(skill_id), do: humanize_id(skill_id)

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
        label: humanize_id(tool_id),
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
        responsibility: "Watches matching updates for this agent."
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
        responsibility: "Keeps this agent's work attached to the selected project."
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

    "Capability area with #{requirements} connected-account requirements."
  end

  defp component_detail_from_metadata(_component), do: nil

  defp tool_descriptor(tool_id) do
    %{
      description:
        if(Tools.exists?(tool_id),
          do: "Configured action available in Maraithon.",
          else: "Action is not currently available."
        )
    }
  end

  defp action_label(%{action: action}) when is_binary(action) and action != "",
    do: humanize_id(action)

  defp action_label(%{name: name}), do: humanize_id(name)

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
    |> to_string()
    |> String.replace("_", " ")
    |> String.replace(".", " ")
    |> String.split(" ")
    |> Enum.map_join(" ", &String.capitalize/1)
  end

  defp package_slug(%AgentPackage{slug: slug}, _version), do: slug
  defp package_slug(_package, version), do: "package:#{version.id}"

  defp package_name(%AgentPackage{name: name}, _version) when is_binary(name) and name != "",
    do: name

  defp package_name(_package, version), do: humanize_id(version.behavior)

  defp package_category(%AgentPackage{category: category}) when is_binary(category) do
    case String.trim(category) do
      "" -> "Automation"
      value -> value
    end
  end

  defp package_category(_package), do: "Automation"

  defp package_summary(%AgentPackage{summary: summary}, _version)
       when is_binary(summary) and summary != "",
       do: summary

  defp package_summary(_package, version), do: "Package version #{version.version}"

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
