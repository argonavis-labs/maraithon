defmodule Maraithon.BriefingSchedules do
  @moduledoc """
  Helpers for reading and updating recurring briefing schedules across briefing-capable agents.
  """

  alias Maraithon.Agents
  alias Maraithon.Agents.Agent
  alias Maraithon.Briefs
  alias Maraithon.ChiefOfStaff.Skills
  alias Maraithon.Runtime
  alias Maraithon.Timezones

  @briefing_behaviors ["ai_chief_of_staff", "founder_followthrough_agent"]
  @default_timezone_offset_hours -5
  @default_morning_hour 8
  @default_morning_minute 0
  @default_end_of_day_hour 18
  @default_end_of_day_minute 0
  @default_weekly_day 5
  @default_weekly_hour 16
  @default_weekly_minute 0

  @spec summarize_for_prompt(String.t() | nil) :: map()
  def summarize_for_prompt(user_id) when is_binary(user_id) do
    agents = list_briefing_agents(user_id)
    primary_agent = List.first(agents)

    timezone_name = timezone_name(primary_agent)
    timezone_offset_hours = timezone_offset_hours(primary_agent)

    morning_hour =
      primary_agent
      |> config_value("morning_brief_hour_local")
      |> parse_integer(@default_morning_hour)

    morning_minute =
      primary_agent
      |> config_value("morning_brief_minute_local")
      |> parse_integer(@default_morning_minute)

    end_of_day_hour =
      primary_agent
      |> config_value("end_of_day_brief_hour_local")
      |> parse_integer(@default_end_of_day_hour)

    end_of_day_minute =
      primary_agent
      |> config_value("end_of_day_brief_minute_local")
      |> parse_integer(@default_end_of_day_minute)

    weekly_day =
      primary_agent
      |> config_value("weekly_review_day_local")
      |> parse_integer(@default_weekly_day)

    weekly_hour =
      primary_agent
      |> config_value("weekly_review_hour_local")
      |> parse_integer(@default_weekly_hour)

    weekly_minute =
      primary_agent
      |> config_value("weekly_review_minute_local")
      |> parse_integer(@default_weekly_minute)

    %{
      configured: agents != [],
      timezone_name: timezone_name,
      timezone_offset_hours: timezone_offset_hours,
      local_timezone: Timezones.label(timezone_name, timezone_offset_hours),
      morning: %{
        hour_local: morning_hour,
        minute_local: morning_minute,
        time_local: time_label(morning_hour, morning_minute),
        display_time_local: display_time_label(morning_hour, morning_minute)
      },
      end_of_day: %{
        hour_local: end_of_day_hour,
        minute_local: end_of_day_minute,
        time_local: time_label(end_of_day_hour, end_of_day_minute),
        display_time_local: display_time_label(end_of_day_hour, end_of_day_minute)
      },
      weekly_review: %{
        day_local: weekly_day,
        weekday_local: weekday_label(weekly_day),
        hour_local: weekly_hour,
        minute_local: weekly_minute,
        time_local: time_label(weekly_hour, weekly_minute),
        display_time_local: display_time_label(weekly_hour, weekly_minute)
      },
      agent_count: length(agents),
      agents: Enum.map(agents, &serialize_agent_schedule/1)
    }
  end

  def summarize_for_prompt(_user_id), do: default_summary()

  @spec list_due_morning_agents(DateTime.t()) :: [map()]
  def list_due_morning_agents(%DateTime{} = now) do
    Agents.list_resumable_agents()
    |> Enum.filter(&briefing_agent?/1)
    |> Enum.map(&morning_due_entry(&1, now))
    |> Enum.reject(&is_nil/1)
    |> Enum.reject(&Briefs.exists?(&1.user_id, &1.dedupe_key))
  end

  @spec update_schedule(String.t(), map()) :: {:ok, map()} | {:error, atom() | String.t()}
  def update_schedule(user_id, attrs) when is_binary(user_id) and is_map(attrs) do
    with {:ok, agents} <- resolve_target_agents(user_id, attrs),
         {:ok, normalized} <- normalize_schedule_update(attrs, agents) do
      {updated_agents, failed_agents} =
        Enum.reduce(agents, {[], []}, fn agent, {updated, failed} ->
          previous = serialize_agent_schedule(agent)

          case Runtime.update_agent(agent.id, %{
                 config: schedule_config_updates(agent, normalized.config_updates)
               }) do
            {:ok, updated_agent} ->
              {[build_update_result(previous, updated_agent, normalized.briefing_kind) | updated],
               failed}

            {:error, reason} ->
              {updated,
               [
                 %{
                   id: agent.id,
                   name: agent_name(agent),
                   behavior: agent.behavior,
                   reason: normalize_error(reason)
                 }
                 | failed
               ]}
          end
        end)

      case updated_agents do
        [] ->
          {:error, :briefing_schedule_update_failed}

        updated_agents ->
          refreshed = summarize_for_prompt(user_id)

          {:ok,
           %{
             status: if(failed_agents == [], do: "updated", else: "partial"),
             briefing_kind: normalized.briefing_kind,
             local_hour: normalized.local_hour,
             local_minute: normalized.local_minute,
             local_time: time_label(normalized.local_hour, normalized.local_minute),
             display_time_local:
               display_time_label(normalized.local_hour, normalized.local_minute),
             local_timezone:
               if(normalized.timezone_name || is_integer(normalized.timezone_offset_hours),
                 do:
                   Timezones.label(
                     normalized.timezone_name,
                     normalized.timezone_offset_hours || refreshed.timezone_offset_hours
                   ),
                 else: refreshed.local_timezone
               ),
             timezone_name: normalized.timezone_name || refreshed.timezone_name,
             timezone_offset_hours:
               normalized.timezone_offset_hours || refreshed.timezone_offset_hours,
             weekly_review_day_local:
               normalized.weekly_review_day_local || refreshed.weekly_review.day_local,
             weekly_review_weekday_local:
               weekday_label(
                 normalized.weekly_review_day_local || refreshed.weekly_review.day_local
               ),
             updated_agent_count: length(updated_agents),
             failed_agent_count: length(failed_agents),
             updated_agents: Enum.reverse(updated_agents),
             failed_agents: Enum.reverse(failed_agents),
             current_schedule: refreshed
           }}
      end
    end
  end

  def update_schedule(_user_id, _attrs), do: {:error, :invalid_user}

  defp resolve_target_agents(user_id, attrs) do
    agents = list_briefing_agents(user_id)

    case Map.get(attrs, "agent_id") || Map.get(attrs, :agent_id) do
      value when is_binary(value) and value != "" ->
        case Enum.filter(agents, &(&1.id == value)) do
          [] -> {:error, :briefing_agent_not_found}
          matched -> {:ok, matched}
        end

      _ ->
        case agents do
          [] -> {:error, :no_briefing_agents}
          matched -> {:ok, matched}
        end
    end
  end

  defp morning_due_entry(%Agent{user_id: user_id} = agent, now) when is_binary(user_id) do
    timezone_name = timezone_name(agent)
    configured_timezone_offset_hours = timezone_offset_hours(agent)

    timezone_offset_hours =
      Timezones.offset_at(timezone_name, now, configured_timezone_offset_hours)

    morning_hour =
      agent
      |> config_value("morning_brief_hour_local")
      |> parse_integer(@default_morning_hour)

    morning_minute =
      agent
      |> config_value("morning_brief_minute_local")
      |> parse_integer(@default_morning_minute)

    local_now = DateTime.add(now, timezone_offset_hours, :hour)
    due_time = Time.new!(morning_hour, morning_minute, 0)

    if Time.compare(DateTime.to_time(local_now), due_time) != :lt do
      local_date = DateTime.to_date(local_now)
      dedupe_key = "morning_briefing:#{Date.to_iso8601(local_date)}"

      %{
        agent: agent,
        agent_id: agent.id,
        user_id: user_id,
        dedupe_key: dedupe_key,
        local_date: local_date,
        timezone_offset_hours: timezone_offset_hours,
        timezone_name: timezone_name,
        morning_brief_hour_local: morning_hour,
        morning_brief_minute_local: morning_minute
      }
    end
  end

  defp morning_due_entry(_agent, _now), do: nil

  defp normalize_schedule_update(attrs, agents) when is_map(attrs) and is_list(agents) do
    with {:ok, briefing_kind} <-
           normalize_briefing_kind(
             Map.get(attrs, "briefing_kind") || Map.get(attrs, :briefing_kind)
           ),
         {:ok, local_hour} <-
           parse_integer_in_range(
             Map.get(attrs, "local_hour") || Map.get(attrs, :local_hour),
             0,
             23
           ),
         {:ok, local_minute} <-
           parse_optional_integer_in_range(
             Map.get(attrs, "local_minute") || Map.get(attrs, :local_minute),
             0,
             59,
             :invalid_local_minute
           ),
         {:ok, timezone_updates} <- normalize_timezone_update(attrs),
         {:ok, weekly_review_day_local} <-
           parse_weekly_review_day(
             briefing_kind,
             Map.get(attrs, "local_day_of_week") || Map.get(attrs, :local_day_of_week),
             agents
           ) do
      local_minute = local_minute || existing_minute(agents, briefing_kind)

      {field, minute_field} =
        case briefing_kind do
          "morning" -> {"morning_brief_hour_local", "morning_brief_minute_local"}
          "end_of_day" -> {"end_of_day_brief_hour_local", "end_of_day_brief_minute_local"}
          "weekly_review" -> {"weekly_review_hour_local", "weekly_review_minute_local"}
        end

      config_updates =
        %{}
        |> Map.put(field, local_hour)
        |> Map.put(minute_field, local_minute)
        |> Map.merge(timezone_updates)
        |> maybe_put("weekly_review_day_local", weekly_review_day_local)

      {:ok,
       %{
         briefing_kind: briefing_kind,
         local_hour: local_hour,
         local_minute: local_minute,
         minute_field: minute_field,
         timezone_name: Map.get(timezone_updates, "timezone"),
         timezone_offset_hours: Map.get(timezone_updates, "timezone_offset_hours"),
         weekly_review_day_local: weekly_review_day_local,
         config_updates: config_updates
       }}
    end
  end

  defp normalize_briefing_kind("morning"), do: {:ok, "morning"}
  defp normalize_briefing_kind("end_of_day"), do: {:ok, "end_of_day"}
  defp normalize_briefing_kind("weekly_review"), do: {:ok, "weekly_review"}
  defp normalize_briefing_kind(_value), do: {:error, :invalid_briefing_kind}

  defp normalize_timezone_update(attrs) when is_map(attrs) do
    timezone_value =
      Map.get(attrs, "timezone") ||
        Map.get(attrs, :timezone) ||
        Map.get(attrs, "timezone_name") ||
        Map.get(attrs, :timezone_name)

    timezone_updates = Timezones.config_updates(to_string(timezone_value || ""))

    if timezone_value in [nil, ""] do
      with {:ok, timezone_offset_hours} <-
             parse_optional_integer_in_range(
               Map.get(attrs, "timezone_offset_hours") || Map.get(attrs, :timezone_offset_hours),
               -12,
               14,
               :invalid_timezone_offset_hours
             ) do
        {:ok,
         if(is_nil(timezone_offset_hours),
           do: %{},
           else: %{"timezone_offset_hours" => timezone_offset_hours}
         )}
      end
    else
      case timezone_updates do
        updates when map_size(updates) > 0 -> {:ok, updates}
        _updates -> {:error, :invalid_timezone_offset_hours}
      end
    end
  end

  defp parse_weekly_review_day("weekly_review", nil, agents) do
    {:ok,
     agents
     |> List.first()
     |> config_value("weekly_review_day_local")
     |> parse_integer(@default_weekly_day)}
  end

  defp parse_weekly_review_day("weekly_review", value, _agents) do
    parse_integer_in_range(value, 1, 7)
  end

  defp parse_weekly_review_day(_briefing_kind, _value, _agents), do: {:ok, nil}

  defp existing_minute(agents, "morning") do
    agents
    |> List.first()
    |> config_value("morning_brief_minute_local")
    |> parse_integer(@default_morning_minute)
  end

  defp existing_minute(agents, "end_of_day") do
    agents
    |> List.first()
    |> config_value("end_of_day_brief_minute_local")
    |> parse_integer(@default_end_of_day_minute)
  end

  defp existing_minute(agents, "weekly_review") do
    agents
    |> List.first()
    |> config_value("weekly_review_minute_local")
    |> parse_integer(@default_weekly_minute)
  end

  defp schedule_config_updates(%Agent{config: config}, updates) when is_map(updates) do
    skill_configs = Map.get(config || %{}, "skill_configs")

    if is_map(skill_configs) do
      Map.put(updates, "skill_configs", merge_schedule_into_skill_configs(skill_configs, updates))
    else
      updates
    end
  end

  defp schedule_config_updates(_agent, updates), do: updates

  defp merge_schedule_into_skill_configs(skill_configs, updates) do
    Map.new(skill_configs, fn
      {skill_id, skill_config} when is_map(skill_config) ->
        {skill_id, Map.merge(skill_config, updates)}

      entry ->
        entry
    end)
  end

  defp list_briefing_agents(user_id) do
    Agents.list_agents(user_id: user_id)
    |> Enum.filter(&briefing_agent?/1)
  end

  defp briefing_agent?(%Agent{behavior: "founder_followthrough_agent"}), do: true

  defp briefing_agent?(%Agent{behavior: "ai_chief_of_staff", config: config}) do
    config
    |> stringify_keys()
    |> Skills.enabled_ids()
    |> Enum.any?(&(&1 in ["briefing", "morning_briefing"]))
  end

  defp briefing_agent?(%Agent{behavior: "manifest_agent", config: config}) do
    config = stringify_keys(config || %{})

    config["source_behavior"] == "ai_chief_of_staff" and
      config
      |> Skills.enabled_ids()
      |> Enum.any?(&(&1 in ["briefing", "morning_briefing"]))
  end

  defp briefing_agent?(%Agent{behavior: behavior}), do: behavior in @briefing_behaviors
  defp briefing_agent?(_agent), do: false

  defp build_update_result(previous, %Agent{} = updated_agent, briefing_kind) do
    current = serialize_agent_schedule(updated_agent)

    {previous_time_local, previous_display_time_local, current_time_local,
     current_display_time_local} =
      schedule_display_fields(previous, current, briefing_kind)

    %{
      id: updated_agent.id,
      name: agent_name(updated_agent),
      behavior: updated_agent.behavior,
      previous_time_local: previous_time_local,
      current_time_local: current_time_local,
      previous_display_time_local: previous_display_time_local,
      current_display_time_local: current_display_time_local,
      timezone_name: current.timezone_name,
      timezone_offset_hours: current.timezone_offset_hours,
      local_timezone: current.local_timezone
    }
  end

  defp serialize_agent_schedule(%Agent{} = agent) do
    timezone_name = timezone_name(agent)
    timezone_offset_hours = timezone_offset_hours(agent)

    morning_hour =
      agent
      |> config_value("morning_brief_hour_local")
      |> parse_integer(@default_morning_hour)

    morning_minute =
      agent
      |> config_value("morning_brief_minute_local")
      |> parse_integer(@default_morning_minute)

    end_of_day_hour =
      agent
      |> config_value("end_of_day_brief_hour_local")
      |> parse_integer(@default_end_of_day_hour)

    end_of_day_minute =
      agent
      |> config_value("end_of_day_brief_minute_local")
      |> parse_integer(@default_end_of_day_minute)

    weekly_day =
      agent
      |> config_value("weekly_review_day_local")
      |> parse_integer(@default_weekly_day)

    weekly_hour =
      agent
      |> config_value("weekly_review_hour_local")
      |> parse_integer(@default_weekly_hour)

    weekly_minute =
      agent
      |> config_value("weekly_review_minute_local")
      |> parse_integer(@default_weekly_minute)

    %{
      id: agent.id,
      name: agent_name(agent),
      behavior: agent.behavior,
      timezone_name: timezone_name,
      timezone_offset_hours: timezone_offset_hours,
      local_timezone: Timezones.label(timezone_name, timezone_offset_hours),
      morning_brief_hour_local: morning_hour,
      morning_brief_minute_local: morning_minute,
      morning_time_local: time_label(morning_hour, morning_minute),
      morning_display_time_local: display_time_label(morning_hour, morning_minute),
      end_of_day_brief_hour_local: end_of_day_hour,
      end_of_day_brief_minute_local: end_of_day_minute,
      end_of_day_time_local: time_label(end_of_day_hour, end_of_day_minute),
      end_of_day_display_time_local: display_time_label(end_of_day_hour, end_of_day_minute),
      weekly_review_day_local: weekly_day,
      weekly_review_hour_local: weekly_hour,
      weekly_review_minute_local: weekly_minute,
      weekly_review_time_local: time_label(weekly_hour, weekly_minute),
      weekly_review_display_time_local: display_time_label(weekly_hour, weekly_minute)
    }
  end

  defp config_value(%Agent{} = agent, key) when is_binary(key) do
    config = stringify_keys(agent.config || %{})

    config[key] ||
      get_in(config, ["skill_configs", "morning_briefing", key]) ||
      get_in(config, ["skill_configs", "briefing", key])
  end

  defp config_value(_agent, _key), do: nil

  defp timezone_name(%Agent{} = agent) do
    config_value(agent, "timezone") || config_value(agent, "timezone_name")
  end

  defp timezone_name(_agent), do: nil

  defp timezone_offset_hours(%Agent{} = agent) do
    agent
    |> config_value("timezone_offset_hours")
    |> parse_integer(@default_timezone_offset_hours)
  end

  defp timezone_offset_hours(_agent), do: @default_timezone_offset_hours

  defp parse_integer(value, _default) when is_integer(value), do: value

  defp parse_integer(value, default) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, ""} -> parsed
      _ -> default
    end
  end

  defp parse_integer(_value, default), do: default

  defp parse_integer_in_range(value, min, max) when is_integer(value) do
    if value in min..max, do: {:ok, value}, else: {:error, :invalid_local_hour}
  end

  defp parse_integer_in_range(value, min, max) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, ""} -> parse_integer_in_range(parsed, min, max)
      _ -> {:error, :invalid_local_hour}
    end
  end

  defp parse_integer_in_range(_value, _min, _max), do: {:error, :invalid_local_hour}

  defp parse_optional_integer_in_range(nil, _min, _max, _error), do: {:ok, nil}
  defp parse_optional_integer_in_range("", _min, _max, _error), do: {:ok, nil}

  defp parse_optional_integer_in_range(value, min, max, error) do
    case parse_integer_in_range(value, min, max) do
      {:ok, parsed} -> {:ok, parsed}
      {:error, _reason} -> {:error, error}
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp agent_name(%Agent{} = agent) do
    get_in(agent.config || %{}, ["name"]) || agent.behavior
  end

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), value} end)
  end

  defp stringify_keys(_map), do: %{}

  defp time_label(hour, minute) when is_integer(hour) and is_integer(minute) do
    hour
    |> Integer.to_string()
    |> String.pad_leading(2, "0")
    |> then(&"#{&1}:#{minute |> Integer.to_string() |> String.pad_leading(2, "0")}")
  end

  defp display_time_label(hour, minute) when is_integer(hour) and is_integer(minute) do
    {display_hour, meridiem} =
      cond do
        hour == 0 -> {12, "AM"}
        hour < 12 -> {hour, "AM"}
        hour == 12 -> {12, "PM"}
        true -> {hour - 12, "PM"}
      end

    "#{display_hour}:#{minute |> Integer.to_string() |> String.pad_leading(2, "0")} #{meridiem}"
  end

  defp weekday_label(1), do: "Monday"
  defp weekday_label(2), do: "Tuesday"
  defp weekday_label(3), do: "Wednesday"
  defp weekday_label(4), do: "Thursday"
  defp weekday_label(5), do: "Friday"
  defp weekday_label(6), do: "Saturday"
  defp weekday_label(7), do: "Sunday"
  defp weekday_label(_value), do: "Friday"

  defp normalize_error(reason) when is_binary(reason), do: reason
  defp normalize_error(reason), do: inspect(reason)

  defp schedule_display_fields(previous, current, "morning") do
    {
      previous.morning_time_local,
      previous.morning_display_time_local,
      current.morning_time_local,
      current.morning_display_time_local
    }
  end

  defp schedule_display_fields(previous, current, "end_of_day") do
    {
      previous.end_of_day_time_local,
      previous.end_of_day_display_time_local,
      current.end_of_day_time_local,
      current.end_of_day_display_time_local
    }
  end

  defp schedule_display_fields(previous, current, "weekly_review") do
    {
      previous.weekly_review_time_local,
      previous.weekly_review_display_time_local,
      current.weekly_review_time_local,
      current.weekly_review_display_time_local
    }
  end

  defp default_summary do
    %{
      configured: false,
      timezone_name: nil,
      timezone_offset_hours: @default_timezone_offset_hours,
      local_timezone: Timezones.offset_label(@default_timezone_offset_hours),
      morning: %{
        hour_local: @default_morning_hour,
        minute_local: @default_morning_minute,
        time_local: time_label(@default_morning_hour, @default_morning_minute),
        display_time_local: display_time_label(@default_morning_hour, @default_morning_minute)
      },
      end_of_day: %{
        hour_local: @default_end_of_day_hour,
        minute_local: @default_end_of_day_minute,
        time_local: time_label(@default_end_of_day_hour, @default_end_of_day_minute),
        display_time_local:
          display_time_label(@default_end_of_day_hour, @default_end_of_day_minute)
      },
      weekly_review: %{
        day_local: @default_weekly_day,
        weekday_local: weekday_label(@default_weekly_day),
        hour_local: @default_weekly_hour,
        minute_local: @default_weekly_minute,
        time_local: time_label(@default_weekly_hour, @default_weekly_minute),
        display_time_local: display_time_label(@default_weekly_hour, @default_weekly_minute)
      },
      agent_count: 0,
      agents: []
    }
  end
end
