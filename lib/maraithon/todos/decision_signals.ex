defmodule Maraithon.Todos.DecisionSignals do
  @moduledoc """
  User-facing decision detection for open work surfaces.

  This is deliberately stricter than general attention ranking. "Decision"
  should mean a call, approval, reply, or keep-or-close choice is waiting on
  the operator, not merely that an item is open.
  """

  alias Maraithon.Todos.{AttentionRanker, Todo}

  @decision_terms ~w(
    approve approval approved
    ask asked
    blocked blocking
    call
    choose
    commitment committed
    decide decision
    owe owes owed
    reply replied respond response
    wait waiting
  )
  @decision_directions ~w(i_owe asked_of_me pending_reply user_owes waiting_on_user waiting_on_me)
  @generic_decision_prompts MapSet.new([
                              "handle this now snooze it or dismiss it",
                              "this is still open and needs a clear next decision",
                              "this remains open and reviewable"
                            ])

  def needs_decision?(%Todo{} = todo) do
    todo.status in ["open", "snoozed"] and
      (stale_keep_or_close?(todo) or explicit_direction?(todo.metadata || %{}) or
         decision_text?(text_blob(todo)))
  end

  def needs_decision?(%{} = todo) do
    status = read_value(todo, :status) || read_value(todo, "status")

    status in ["open", "snoozed", nil] and
      (explicit_direction?(read_metadata(todo)) or decision_text?(text_blob(todo)))
  end

  def needs_decision?(_todo), do: false

  def label(%Todo{} = todo) do
    if needs_decision?(todo), do: "Decision"
  end

  def label(_todo), do: nil

  defp stale_keep_or_close?(%Todo{} = todo) do
    todo
    |> AttentionRanker.profile()
    |> read_value("stale_confirmation_candidate") == true
  end

  defp explicit_direction?(metadata) when is_map(metadata) do
    [
      read_value(metadata, "commitment_direction"),
      read_value(metadata, "thread_state"),
      metadata |> read_map("conversation_context") |> read_value("momentum_state"),
      metadata |> read_map("conversation_context") |> read_value("notification_posture")
    ]
    |> Enum.any?(&(&1 in @decision_directions))
  end

  defp explicit_direction?(_metadata), do: false

  defp decision_text?(value) when is_binary(value) do
    normalized = normalize_text(value)

    normalized not in @generic_decision_prompts and
      Enum.any?(@decision_terms, &term_present?(normalized, &1))
  end

  defp decision_text?(_value), do: false

  defp text_blob(%Todo{} = todo) do
    metadata = todo.metadata || %{}

    [
      todo.title,
      todo.summary,
      todo.next_action,
      todo.notes,
      todo.action_plan,
      read_value(metadata, "why_now"),
      read_value(metadata, "why_it_matters"),
      read_value(metadata, "context_brief"),
      read_value(metadata, "thread_state"),
      read_value(metadata, "source_quote"),
      read_value(metadata, "source_excerpt"),
      read_value(metadata, "quote"),
      metadata |> read_map("record") |> read_value("commitment"),
      metadata |> read_map("record") |> read_value("ask")
    ]
    |> Enum.reject(&blank?/1)
    |> Enum.join(" ")
  end

  defp text_blob(%{} = todo) do
    metadata = read_metadata(todo)

    [
      read_value(todo, "title") || read_value(todo, :title),
      read_value(todo, "summary") || read_value(todo, :summary),
      read_value(todo, "next_action") || read_value(todo, :next_action),
      read_value(todo, "notes") || read_value(todo, :notes),
      read_value(todo, "action_plan") || read_value(todo, :action_plan),
      read_value(metadata, "why_now"),
      read_value(metadata, "why_it_matters"),
      read_value(metadata, "context_brief"),
      read_value(metadata, "thread_state"),
      read_value(metadata, "source_quote"),
      read_value(metadata, "source_excerpt"),
      read_value(metadata, "quote")
    ]
    |> Enum.reject(&blank?/1)
    |> Enum.join(" ")
  end

  defp read_metadata(%Todo{metadata: metadata}) when is_map(metadata), do: metadata

  defp read_metadata(%{} = map),
    do: read_value(map, "metadata") || read_value(map, :metadata) || %{}

  defp read_metadata(_value), do: %{}

  defp read_map(map, key) when is_map(map) do
    case read_value(map, key) do
      value when is_map(value) -> value
      _ -> %{}
    end
  end

  defp read_map(_map, _key), do: %{}

  defp read_value(%_{} = struct, key), do: struct |> Map.from_struct() |> read_value(key)

  defp read_value(map, key) when is_map(map) and is_atom(key), do: Map.get(map, key)

  defp read_value(map, key) when is_map(map) and is_binary(key) do
    Map.get(map, key) ||
      Enum.find_value(map, fn
        {map_key, value} when is_atom(map_key) ->
          if Atom.to_string(map_key) == key, do: value

        _ ->
          nil
      end)
  end

  defp read_value(_map, _key), do: nil

  defp term_present?(text, term) do
    Regex.match?(~r/(^|[^a-z0-9])#{Regex.escape(term)}($|[^a-z0-9])/, text)
  end

  defp normalize_text(value) do
    value
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, " ")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(nil), do: true
  defp blank?(_value), do: false
end
