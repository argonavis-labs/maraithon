defmodule Maraithon.Todos.ActionDrafts do
  @moduledoc """
  Ensures each saved work item has draft material or a clear next step.

  Model-generated todos should provide `action_draft` directly. This module is a
  conservative write-boundary fallback so mobile can show useful prepared
  material as soon as the todo exists, before the user opens the chat pane.
  """

  def ensure(attrs, existing \\ nil)

  def ensure(attrs, existing) when is_map(attrs) do
    if action_draft_present?(read_value(attrs, "action_draft") || read_value(attrs, "draft")) do
      attrs
    else
      put_value(attrs, "action_draft", next_step_draft(attrs, existing))
    end
  end

  def ensure(attrs, _existing), do: attrs

  def preview(%{} = draft) do
    [
      read_string(draft, "body"),
      read_string(draft, "text"),
      read_string(draft, "message"),
      read_string(draft, "reply"),
      read_string(draft, "draft"),
      read_string(draft, "content")
    ]
    |> Enum.find(&present?/1)
  end

  def preview(_draft), do: nil

  defp next_step_draft(attrs, existing) do
    attrs = attrs |> stringify_top_level_keys() |> merge_existing(existing)
    next_action = prepared_next_action(attrs)

    %{
      "kind" => "next_step",
      "label" => "Drafted next step",
      "text" => next_step_text(next_action),
      "source" => "todo_write_boundary",
      "style" => "conversational_next_step"
    }
    |> compact_map()
  end

  defp prepared_next_action(attrs) do
    first_present([
      read_string(attrs, "next_action"),
      read_string(attrs, "action_plan"),
      read_string(attrs, "summary"),
      "Open the source context, confirm the exact ask, and decide whether to reply, delegate, or dismiss it."
    ])
  end

  defp next_step_text(value) when is_binary(value) do
    value = String.trim(value)

    if String.match?(value, ~r/^(next step:|you should\b)/i) do
      value
    else
      "Next step: #{value}"
    end
  end

  defp merge_existing(attrs, nil), do: attrs

  defp merge_existing(attrs, existing) do
    existing_map =
      existing
      |> Map.from_struct()
      |> Enum.map(fn {key, value} -> {Atom.to_string(key), value} end)
      |> Map.new()

    Map.merge(existing_map, attrs)
  rescue
    _ -> attrs
  end

  defp first_present(values), do: Enum.find(values, &present?/1)
  defp present?(value), do: not blank?(value)

  defp action_draft_present?(value) when is_binary(value), do: String.trim(value) != ""

  defp action_draft_present?(values) when is_list(values),
    do: Enum.any?(values, &action_draft_present?/1)

  defp action_draft_present?(value) when is_map(value),
    do: value |> Map.values() |> Enum.any?(&action_draft_present?/1)

  defp action_draft_present?(value), do: not is_nil(value)

  defp compact_map(map) do
    map
    |> Enum.reject(fn {_key, value} -> blank?(value) end)
    |> Map.new()
  end

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?([]), do: true
  defp blank?(%{}), do: true
  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(_value), do: false

  defp read_value(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, to_string(key)) ||
      Map.get(map, String.to_existing_atom(key))
  rescue
    ArgumentError -> Map.get(map, key) || Map.get(map, to_string(key))
  end

  defp put_value(map, key, value) when is_map(map) do
    atom_key =
      try do
        String.to_existing_atom(key)
      rescue
        ArgumentError -> nil
      end

    cond do
      Map.has_key?(map, key) -> Map.put(map, key, value)
      atom_key && Map.has_key?(map, atom_key) -> Map.put(map, atom_key, value)
      atom_key && atom_key_map?(map) -> Map.put(map, atom_key, value)
      true -> Map.put(map, key, value)
    end
  end

  defp atom_key_map?(map) when is_map(map) do
    map != %{} and Enum.all?(Map.keys(map), &is_atom/1)
  end

  defp read_string(map, key) when is_map(map) do
    case Map.get(map, key) || Map.get(map, to_string(key)) do
      value when is_binary(value) ->
        value = String.trim(value)
        if value == "", do: nil, else: value

      values when is_list(values) ->
        values
        |> Enum.filter(&is_binary/1)
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))
        |> Enum.join("; ")
        |> read_non_empty()

      _ ->
        nil
    end
  end

  defp read_string(_map, _key), do: nil

  defp read_non_empty(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  defp stringify_top_level_keys(map) when is_map(map) do
    Map.new(map, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), value}
      {key, value} -> {to_string(key), value}
    end)
  end
end
