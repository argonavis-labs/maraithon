defmodule Maraithon.AgentHarness.Manifest do
  @moduledoc """
  Builds an executable harness manifest from package records.
  """

  alias Maraithon.AgentHarness.MarkdownSkill
  alias Maraithon.Agents.AgentPackageVersion
  alias Maraithon.LLM

  @known_keys %{
    "behavior" => :behavior,
    "category" => :category,
    "changelog" => :changelog,
    "default_config" => :default_config,
    "goals" => :goals,
    "intelligence" => :intelligence,
    "manifest" => :manifest,
    "mcp_allowlist" => :mcp_allowlist,
    "model" => :model,
    "name" => :name,
    "owner_user_id" => :owner_user_id,
    "package_version_id" => :package_version_id,
    "required_connectors" => :required_connectors,
    "slug" => :slug,
    "source_kind" => :source_kind,
    "status" => :status,
    "skills" => :skills,
    "skill_paths" => :skill_paths,
    "summary" => :summary,
    "system_prompt" => :system_prompt,
    "tool_allowlist" => :tool_allowlist,
    "version" => :version,
    "version_status" => :version_status
  }

  def build(%AgentPackageVersion{} = version) do
    with {:ok, model} <- configured_model(version),
         {:ok, intelligence} <- configured_intelligence(version),
         {:ok, skills} <- MarkdownSkill.load_many(version.skill_paths || []) do
      {:ok,
       %{
         package_version_id: version.id,
         behavior: version.behavior,
         system_prompt: version.system_prompt || "",
         model: model,
         intelligence: intelligence,
         goals: version.goals || [],
         skills: skills,
         required_connectors: version.required_connectors || %{},
         tool_allowlist: version.tool_allowlist || [],
         mcp_allowlist: version.mcp_allowlist || [],
         default_config: version.default_config || %{},
         manifest: version.manifest || %{}
       }}
    end
  end

  def normalize(manifest) when is_map(manifest) do
    Map.new(manifest, fn {key, value} -> {normalize_key(key), value} end)
  end

  def normalize(_manifest), do: %{}

  def get(manifest, key, default \\ nil)

  def get(manifest, key, default) when is_map(manifest) and is_atom(key) do
    Map.get(manifest, key, Map.get(manifest, Atom.to_string(key), default))
  end

  def get(manifest, key, default) when is_map(manifest) and is_binary(key) do
    atom_key = Map.get(@known_keys, key)

    cond do
      Map.has_key?(manifest, key) -> Map.get(manifest, key)
      is_atom(atom_key) -> Map.get(manifest, atom_key, default)
      true -> default
    end
  end

  def get(_manifest, _key, default), do: default

  def require_text(manifest, key) do
    case get(manifest, key) do
      value when is_binary(value) ->
        value = String.trim(value)

        if value == "" do
          {:error, {:"#{key}_not_configured", "Agent harness requires #{key}."}}
        else
          {:ok, value}
        end

      _ ->
        {:error, {:"#{key}_not_configured", "Agent harness requires #{key}."}}
    end
  end

  def active_skill_ids(manifest) do
    manifest
    |> get(:skills, [])
    |> Enum.map(fn
      %{id: id} -> id
      %{"id" => id} -> id
      other -> to_string(other)
    end)
  end

  defp normalize_key(key) when is_atom(key), do: key
  defp normalize_key(key) when is_binary(key), do: Map.get(@known_keys, key, key)
  defp normalize_key(key), do: key

  defp configured_model(%AgentPackageVersion{model: model})
       when is_binary(model) and model != "" do
    {:ok, model}
  end

  defp configured_model(_version) do
    case LLM.model() do
      model when is_binary(model) and model != "" -> {:ok, model}
      _ -> {:error, {:model_not_configured, "Agent packages require an explicit model."}}
    end
  end

  defp configured_intelligence(%AgentPackageVersion{intelligence: intelligence})
       when is_binary(intelligence) and intelligence != "" do
    {:ok, intelligence}
  end

  defp configured_intelligence(_version) do
    case LLM.intelligence() do
      intelligence when is_binary(intelligence) and intelligence != "" ->
        {:ok, intelligence}

      _ ->
        {:error,
         {:intelligence_not_configured,
          "Agent packages require an explicit intelligence setting."}}
    end
  end
end
