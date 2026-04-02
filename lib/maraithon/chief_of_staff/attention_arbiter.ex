defmodule Maraithon.ChiefOfStaff.AttentionArbiter do
  @moduledoc """
  Assistant-layer emit and metadata arbitration for one Chief of Staff cycle.
  """

  def finalize_emit(nil, _skill_emits, _cycle_id, _telemetry), do: nil

  def finalize_emit({event_type, payload}, skill_emits, cycle_id, telemetry)
      when is_atom(event_type) and is_map(payload) do
    payload = stringify_keys(payload)
    ranked_skills = rank_skill_emits(skill_emits)

    {
      event_type,
      payload
      |> maybe_put("assistant_cycle_id", cycle_id)
      |> maybe_put_map("assistant_fetch_telemetry", compact_fetch_telemetry(telemetry))
      |> maybe_put_map("assistant_attention_plan", %{
        "merged_skill_count" => length(ranked_skills),
        "skills" => ranked_skills,
        "interrupting_outputs" => Enum.count(ranked_skills, &(&1["interrupting"] == true)),
        "digest_outputs" => Enum.count(ranked_skills, &(&1["interrupting"] == false))
      })
    }
  end

  def merge_artifact_metadata(metadata, context) when is_map(metadata) and is_map(context) do
    if chief_of_staff_context?(context) do
      metadata
      |> stringify_keys()
      |> maybe_put("assistant_behavior", "ai_chief_of_staff")
      |> maybe_put("assistant_cycle_id", context[:assistant_cycle_id])
      |> maybe_put("origin_skill_id", context[:assistant_origin_skill_id])
      |> maybe_put("arbitration_rank", context[:assistant_origin_skill_rank])
      |> maybe_put("arbitration_reason", arbitration_reason(context))
      |> maybe_put_map(
        "assistant_fetch",
        compact_fetch_telemetry(context[:assistant_fetch_telemetry])
      )
    else
      stringify_keys(metadata)
    end
  end

  def merge_artifact_metadata(metadata, _context) when is_map(metadata),
    do: stringify_keys(metadata)

  def merge_artifact_metadata(_metadata, context) when is_map(context),
    do: merge_artifact_metadata(%{}, context)

  def merge_artifact_metadata(_metadata, _context), do: %{}

  defp rank_skill_emits(skill_emits) when is_list(skill_emits) do
    skill_emits
    |> Enum.with_index(1)
    |> Enum.map(fn {%{skill_id: skill_id, event_type: event_type}, index} ->
      %{
        "skill_id" => skill_id,
        "event_type" => to_string(event_type),
        "rank" => index,
        "interrupting" => event_type in [:insights_recorded, :insight_error]
      }
    end)
  end

  defp rank_skill_emits(_skill_emits), do: []

  defp compact_fetch_telemetry(telemetry) when is_map(telemetry) do
    %{
      "sources" => stringify_keys(Map.get(telemetry, "sources", %{})),
      "fetch_count" => telemetry |> Map.get("fetches", []) |> length()
    }
  end

  defp compact_fetch_telemetry(_telemetry), do: %{}

  defp arbitration_reason(context) when is_map(context) do
    case context[:assistant_origin_skill_rank] do
      rank when is_integer(rank) -> "chief_of_staff_skill_order_#{rank}"
      _ -> nil
    end
  end

  defp chief_of_staff_context?(context) when is_map(context) do
    is_binary(context[:assistant_cycle_id]) or is_binary(context[:assistant_origin_skill_id])
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, ""), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp maybe_put_map(map, _key, %{}), do: map
  defp maybe_put_map(map, _key, nil), do: map
  defp maybe_put_map(map, key, value), do: Map.put(map, key, value)

  defp stringify_keys(%_{} = struct), do: struct

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn
      {key, value} when is_map(value) -> {to_string(key), stringify_keys(value)}
      {key, value} when is_list(value) -> {to_string(key), Enum.map(value, &stringify_keys/1)}
      {key, value} -> {to_string(key), value}
    end)
  end

  defp stringify_keys(value), do: value
end
