defmodule Maraithon.ChiefOfStaff.Skills do
  @moduledoc """
  Registry and helper utilities for AI Chief of Staff skills.
  """

  @process_override_key {__MODULE__, :config_override}

  @default_skill_modules %{
    "followthrough" => Maraithon.ChiefOfStaff.Skills.Followthrough,
    "travel_logistics" => Maraithon.ChiefOfStaff.Skills.TravelLogistics,
    "morning_briefing" => Maraithon.ChiefOfStaff.Skills.MorningBriefing,
    "commitment_tracker" => Maraithon.ChiefOfStaff.Skills.CommitmentTracker,
    "calendar_check_in" => Maraithon.ChiefOfStaff.Skills.CalendarCheckIn,
    "briefing" => Maraithon.ChiefOfStaff.Skills.Briefing,
    "project_scope_alignment" => Maraithon.ChiefOfStaff.Skills.ProjectScopeAlignment,
    "holiday_radar" => Maraithon.ChiefOfStaff.Skills.HolidayRadar
  }

  @default_enabled_ids [
    "followthrough",
    "travel_logistics",
    "morning_briefing",
    "commitment_tracker",
    "calendar_check_in",
    "project_scope_alignment",
    "holiday_radar"
  ]

  @doc false
  def put_process_override(config) when is_list(config) do
    Process.put(@process_override_key, config)
    :ok
  end

  @doc false
  def clear_process_override do
    Process.delete(@process_override_key)
    :ok
  end

  def modules do
    configured = config()

    configured
    |> Keyword.get(:skill_modules, @default_skill_modules)
    |> normalize_module_map()
    |> Map.merge(
      configured
      |> Keyword.get(:extra_skill_modules, %{})
      |> normalize_module_map()
    )
  end

  def list_ids do
    modules()
    |> Map.keys()
    |> Enum.sort()
  end

  def get(id) when is_binary(id) do
    Map.get(modules(), id)
  end

  def get!(id) when is_binary(id) do
    case get(id) do
      nil -> raise ArgumentError, "Unknown Chief of Staff skill: #{id}"
      module -> module
    end
  end

  def label(id) when is_binary(id) do
    id
    |> get()
    |> module_label(id)
  end

  def description(id) when is_binary(id) do
    id
    |> get()
    |> module_description()
  end

  def default_enabled_ids do
    configured =
      config()
      |> Keyword.get(:default_enabled_ids, @default_enabled_ids)

    configured
    |> Enum.map(&normalize_id/1)
    |> Enum.filter(&Map.has_key?(modules(), &1))
    |> case do
      [] -> @default_enabled_ids
      ids -> Enum.uniq(ids)
    end
  end

  def enabled_ids(config) when is_map(config) do
    config
    |> Map.get("enabled_skills", Map.get(config, :enabled_skills, default_enabled_ids()))
    |> List.wrap()
    |> Enum.map(&normalize_id/1)
    |> Enum.filter(&Map.has_key?(modules(), &1))
    |> case do
      [] -> default_enabled_ids()
      ids -> Enum.uniq(ids)
    end
  end

  def requirements(skill_ids) when is_list(skill_ids) do
    skill_ids
    |> Enum.map(&normalize_id/1)
    |> Enum.filter(&Map.has_key?(modules(), &1))
    |> Enum.flat_map(fn id -> get!(id).requirements() end)
    |> Enum.uniq_by(fn requirement ->
      {
        Map.get(requirement, :kind),
        Map.get(requirement, :provider),
        Map.get(requirement, :service),
        Map.get(requirement, :label)
      }
    end)
  end

  def subscriptions(skill_configs, user_id, skill_ids \\ nil)

  def subscriptions(skill_configs, user_id, nil)
      when is_map(skill_configs) and is_binary(user_id) do
    subscriptions(skill_configs, user_id, Map.keys(skill_configs))
  end

  def subscriptions(skill_configs, user_id, skill_ids)
      when is_map(skill_configs) and is_binary(user_id) and is_list(skill_ids) do
    skill_ids
    |> Enum.map(&normalize_id/1)
    |> Enum.filter(&Map.has_key?(modules(), &1))
    |> Enum.flat_map(fn id ->
      module = get!(id)
      config = Map.get(skill_configs, id, %{})
      module.subscriptions(config, user_id)
    end)
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  def interested_in?(skill_id, skill_configs, context)
      when is_binary(skill_id) and is_map(skill_configs) and is_map(context) do
    module = get!(skill_id)
    config = Map.get(skill_configs, skill_id, %{})

    if function_exported?(module, :interested_in?, 2) do
      module.interested_in?(config, context)
    else
      true
    end
  end

  defp normalize_id(id) when is_binary(id), do: String.trim(id)
  defp normalize_id(id) when is_atom(id), do: id |> Atom.to_string() |> normalize_id()
  defp normalize_id(id), do: id |> to_string() |> normalize_id()

  defp normalize_module_map(modules) when is_map(modules) do
    Map.new(modules, fn {id, module} -> {normalize_id(id), module} end)
  end

  defp normalize_module_map(_modules), do: %{}

  defp module_label(nil, id), do: humanize_id(id)

  defp module_label(module, id) do
    if function_exported?(module, :label, 0), do: module.label(), else: humanize_id(id)
  end

  defp module_description(nil), do: "Runs as part of the Chief of Staff cycle."

  defp module_description(module) do
    if function_exported?(module, :description, 0) do
      module.description()
    else
      "Runs as part of the Chief of Staff cycle."
    end
  end

  defp humanize_id(id) when is_binary(id) do
    id
    |> String.replace("_", " ")
    |> String.split()
    |> Enum.map_join(" ", &String.capitalize/1)
  end

  defp config do
    Process.get(@process_override_key) || Application.get_env(:maraithon, __MODULE__, [])
  end
end
