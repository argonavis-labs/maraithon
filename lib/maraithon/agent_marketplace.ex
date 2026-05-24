defmodule Maraithon.AgentMarketplace do
  @moduledoc """
  Database-backed marketplace operations for installable agents.
  """

  alias Maraithon.AgentBuilder
  alias Maraithon.Agents
  alias Maraithon.Accounts
  alias Maraithon.ConnectedAccounts
  alias Maraithon.LLM

  @chief_of_staff_slug "ai_chief_of_staff"
  @primary_admin_chief_of_staff_config %{
    "skill_configs" => %{
      "morning_briefing" => %{
        "commercial_gmail_queries" => [
          "newer_than:7d Cogniate",
          "newer_than:7d Glossier",
          "newer_than:7d \"team plan\"",
          "newer_than:7d \"Ultra plan\"",
          "newer_than:7d Enterprise",
          "newer_than:7d discount",
          "newer_than:7d intro",
          "newer_than:7d availability"
        ],
        "commercial_counterparty_domain_markers" => [
          "cogniate",
          "glossier",
          "represent",
          "sandwich.co"
        ],
        "commercial_teammate_domains" => ["runner.now"],
        "slack_key_channels" => [
          "runner-general",
          "runner-leads",
          "runner-gtm",
          "runner-user-feedback",
          "gtm-leads",
          "general",
          "eng-general",
          "exec-agora-gov-mgmt-w-dash",
          "jeff",
          "charlie",
          "yitong"
        ]
      }
    }
  }

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
  def ensure_default_installations do
    ensure_default_installations([], :bootstrap)
  end

  def ensure_default_installations(opts) when is_list(opts) do
    ensure_default_installations(opts, :explicit_options)
  end

  defp ensure_default_installations(opts, call_source) do
    slugs = Keyword.get(opts, :slugs, default_install_slugs())

    with {:ok, user_id, install_source} <- default_install_user_id(opts, call_source),
         {:ok, _packages} <- sync_builtin_packages() do
      case user_id do
        nil ->
          {:ok, []}

        user_id ->
          if default_install_allowed?(user_id, install_source) do
            slugs
            |> Enum.map(&ensure_user_installation(user_id, &1, install_source))
            |> split_results()
          else
            {:ok, []}
          end
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

  @doc """
  Returns normalized connector requirements for a package slug or package struct.
  """
  def required_connectors_for(slug) when is_binary(slug) do
    case Agents.get_agent_package_by_slug(slug, preload: [:latest_version]) do
      %{latest_version: %{required_connectors: required_connectors}}
      when is_map(required_connectors) ->
        required_connectors

      _missing ->
        slug
        |> builtin_manifest_for_slug()
        |> Map.get("required_connectors", %{})
    end
  end

  def required_connectors_for(%{latest_version: %{required_connectors: required_connectors}})
      when is_map(required_connectors),
      do: required_connectors

  def required_connectors_for(_package), do: %{}

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

  defp default_install_user_id(opts, call_source) do
    explicit_user_id = Keyword.get(opts, :user_id)

    cond do
      call_source == :explicit_options and is_binary(explicit_user_id) and
          String.trim(explicit_user_id) != "" ->
        {:ok, Accounts.normalize_email(explicit_user_id), :explicit}

      user = Accounts.primary_admin_email() ->
        {:ok, user, :primary_admin}

      true ->
        {:ok, nil, :none}
    end
  end

  defp default_install_slugs do
    :maraithon
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:default_install_slugs, [@chief_of_staff_slug])
  end

  defp default_install_allowed?(user_id, :explicit), do: primary_admin_user?(user_id)

  defp default_install_allowed?(user_id, :primary_admin),
    do: ConnectedAccounts.telegram_destination(user_id) != nil

  defp default_install_allowed?(_user_id, _source), do: false

  defp primary_admin_user?(user_id) when is_binary(user_id) do
    case Accounts.primary_admin_email() do
      nil -> false
      primary -> Accounts.normalize_email(user_id) == primary
    end
  end

  defp primary_admin_user?(_user_id), do: false

  defp ensure_user_installation(nil, _slug, _install_source), do: {:ok, nil}

  defp ensure_user_installation(user_id, slug, install_source) do
    case installed_package_agent(user_id, slug) do
      nil ->
        Agents.install_agent_package(user_id, slug,
          runtime_status: "running",
          install_status: "enabled",
          config: default_install_config(slug, install_source),
          delivery_policy: %{"telegram" => "enabled"}
        )

      agent ->
        {:ok, agent}
    end
  end

  defp default_install_config(@chief_of_staff_slug, :primary_admin),
    do: @primary_admin_chief_of_staff_config

  defp default_install_config(_slug, _install_source), do: %{}

  defp builtin_manifest_for_slug(slug) when is_binary(slug) do
    AgentBuilder.library_specs()
    |> Enum.find(&(&1.id == slug))
    |> case do
      nil -> %{}
      spec -> builtin_manifest(spec)
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
      "priv/agents/skills/chief_of_staff/commitment_tracker.md",
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
      "list_connected_accounts",
      "get_open_loops",
      "get_todo",
      "list_todos",
      "upsert_todos",
      "update_todo",
      "resolve_todo",
      "delete_todo",
      "list_people",
      "get_person",
      "upsert_person",
      "link_person_data",
      "merge_people",
      "get_relationship_context",
      "learn_relationship_context",
      "recall_memory",
      "write_memory",
      "record_memory_feedback",
      "update_memory_confidence",
      "llm.complete"
    ]
  end

  defp tool_allowlist_for(_behavior), do: ["llm.complete"]

  defp mcp_allowlist_for("ai_chief_of_staff"), do: ["google", "slack", "telegram", "maraithon"]
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
