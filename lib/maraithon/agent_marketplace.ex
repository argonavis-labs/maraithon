defmodule Maraithon.AgentMarketplace do
  @moduledoc """
  Database-backed marketplace operations for installable agents.
  """

  alias Maraithon.AgentBuilder
  alias Maraithon.Agents
  alias Maraithon.Accounts
  alias Maraithon.LLM

  @doc """
  Ensure built-in agent packages exist in the marketplace tables.
  """
  def sync_builtin_packages do
    AgentBuilder.library_specs()
    |> Enum.map(&sync_builtin_package/1)
    |> split_results()
  end

  @doc """
  Ensure the primary operator has the default marketplace agents installed.
  """
  def ensure_default_installations(opts \\ []) do
    slugs = Keyword.get(opts, :slugs, default_install_slugs())

    with {:ok, user_id} <- default_install_user_id(opts),
         {:ok, _packages} <- sync_builtin_packages() do
      case user_id do
        nil ->
          {:ok, []}

        user_id ->
          slugs
          |> Enum.map(&ensure_user_installation(user_id, &1))
          |> split_results()
      end
    else
      {:error, reason} ->
        {:error, reason}
    end
  end

  def builtin_manifest(%{} = spec) do
    %{
      "slug" => spec.id,
      "name" => spec.label,
      "summary" => spec.summary,
      "category" => spec.category,
      "source_kind" => "builtin",
      "status" => "published",
      "version" => "1.0.0",
      "changelog" => "Initial manifest-backed marketplace package.",
      "behavior" => "manifest_agent",
      "source_behavior" => spec.id,
      "system_prompt" => system_prompt_for(spec.id),
      "model" => LLM.model(),
      "intelligence" => LLM.intelligence(),
      "goals" => spec.outputs || [],
      "skill_paths" => skill_paths_for(spec.id),
      "required_connectors" => required_connectors(spec.requirements || []),
      "tool_allowlist" => tool_allowlist_for(spec.id),
      "mcp_allowlist" => mcp_allowlist_for(spec.id),
      "default_config" => default_config_for(spec.id)
    }
  end

  defp sync_builtin_package(spec) do
    spec
    |> builtin_manifest()
    |> Agents.sync_agent_package_manifest()
  end

  defp default_config_for(behavior) do
    behavior
    |> AgentBuilder.launch_params_for_behavior()
    |> Map.put("behavior", "manifest_agent")
    |> Map.put("source_behavior", behavior)
  end

  defp default_install_user_id(opts) do
    explicit_user_id = Keyword.get(opts, :user_id)

    cond do
      is_binary(explicit_user_id) and String.trim(explicit_user_id) != "" ->
        {:ok, Accounts.normalize_email(explicit_user_id)}

      user = Accounts.primary_admin_email() ->
        {:ok, user}

      true ->
        {:ok, nil}
    end
  end

  defp default_install_slugs do
    :maraithon
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:default_install_slugs, ["ai_chief_of_staff"])
  end

  defp ensure_user_installation(nil, _slug), do: {:ok, nil}

  defp ensure_user_installation(user_id, slug) do
    case installed_package_agent(user_id, slug) do
      nil ->
        Agents.install_agent_package(user_id, slug,
          runtime_status: "running",
          install_status: "enabled",
          delivery_policy: %{"telegram" => "enabled"}
        )

      agent ->
        {:ok, agent}
    end
  end

  defp installed_package_agent(user_id, slug) do
    packages = Agents.list_marketplace_packages(user_id, preload: [:latest_version])

    packages
    |> Enum.find_value(fn
      %{package: %{slug: ^slug}, installation: installation} -> installation
      _ -> nil
    end)
  end

  defp split_results(results) do
    Enum.reduce(results, {:ok, []}, fn
      {:ok, package}, {:ok, packages} -> {:ok, [package | packages]}
      {:error, reason}, {:ok, _packages} -> {:error, reason}
      _result, {:error, reason} -> {:error, reason}
    end)
    |> case do
      {:ok, packages} -> {:ok, Enum.reverse(packages)}
      error -> error
    end
  end

  defp system_prompt_for("ai_chief_of_staff") do
    "Act as a high-intelligence Chief of Staff. Use connected sources and markdown skills to produce condensed, decision-grade briefs. Do not summarize raw inboxes or messages as lists; rank, synthesize, and explain only what deserves operator attention."
  end

  defp system_prompt_for(_behavior) do
    "Run the agent loop from the package manifest. Use the selected model, goals, skills, connectors, and tool catalog until the requested agent objective is complete."
  end

  defp skill_paths_for("ai_chief_of_staff") do
    [
      "priv/agents/skills/chief_of_staff/morning_briefing.md",
      "priv/agents/skills/chief_of_staff/followthrough.md",
      "priv/agents/skills/chief_of_staff/travel_logistics.md"
    ]
  end

  defp skill_paths_for("github_product_planner") do
    ["priv/agents/skills/product/github_product_planner.md"]
  end

  defp skill_paths_for("codebase_advisor") do
    ["priv/agents/skills/engineering/codebase_advisor.md"]
  end

  defp skill_paths_for("repo_planner") do
    ["priv/agents/skills/engineering/repo_planner.md"]
  end

  defp skill_paths_for(_behavior), do: []

  defp tool_allowlist_for("ai_chief_of_staff") do
    [
      "gmail.search",
      "gmail.read",
      "calendar.list",
      "slack.search",
      "slack.read",
      "telegram.send",
      "llm.complete"
    ]
  end

  defp tool_allowlist_for(_behavior), do: ["llm.complete"]

  defp mcp_allowlist_for("ai_chief_of_staff"), do: ["google", "slack", "telegram"]
  defp mcp_allowlist_for(_behavior), do: []

  defp required_connectors(requirements) do
    requirements
    |> Enum.filter(&connector_requirement?/1)
    |> Enum.map(fn requirement ->
      service =
        case requirement[:service] do
          nil -> nil
          value -> to_string(value)
        end

      %{
        "provider" => to_string(requirement.provider),
        "service" => service,
        "label" => requirement.label
      }
    end)
    |> Enum.group_by(& &1["provider"])
  end

  defp connector_requirement?(%{kind: kind, provider: provider, required?: true})
       when kind in [:provider, :provider_service] and is_binary(provider),
       do: true

  defp connector_requirement?(_requirement), do: false
end
