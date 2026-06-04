defmodule Maraithon.AssistantChat.TodoThreadPrimer do
  @moduledoc """
  Seeds mobile todo-detail chat threads with chief-of-staff context.

  The primer is intentionally idempotent and read-only. Draft material must
  already live on the todo; opening the chat pane should not create it.
  """

  import Ecto.Query

  alias Maraithon.ActionCards
  alias Maraithon.Repo
  alias Maraithon.TelegramConversations
  alias Maraithon.TelegramConversations.{Conversation, Turn}
  alias Maraithon.Todos
  alias Maraithon.Todos.{ActionDrafts, Todo}

  @primer_version 2

  def ensure(%Conversation{} = conversation, %Todo{} = todo) do
    card = ActionCards.for_todo(todo, include_disconnected: true)
    draft = draft_for(todo, card)
    text = primer_text(todo, card, draft)
    attrs = primer_turn_attrs(todo, card, draft, text)

    case primer_turn(conversation, todo.id) do
      %Turn{} = turn ->
        update_primer_turn(turn, attrs)
        {:ok, conversation}

      nil ->
        case TelegramConversations.append_turn(conversation, attrs) do
          {:ok, {updated_conversation, _turn}} -> {:ok, updated_conversation}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  def ensure(_conversation, _todo), do: {:error, :invalid_todo_thread}

  defp primer_turn_attrs(%Todo{} = todo, card, draft, text) do
    %{
      "role" => "assistant",
      "delivery_state" => "delivered",
      "text" => text,
      "turn_kind" => "assistant_reply",
      "origin_type" => "system",
      "origin_id" => primer_origin_id(todo.id),
      "structured_data" => %{
        "message_class" => "todo_chat_primer",
        "todo_chat_primer_version" => @primer_version,
        "linked_todo" => Todos.serialize_for_prompt(todo),
        "todo_action_card" => public_card(card),
        "drafted_next_step" => draft
      }
    }
  end

  defp update_primer_turn(%Turn{} = turn, attrs) do
    current_version = get_in(turn.structured_data || %{}, ["todo_chat_primer_version"])

    if current_version == @primer_version do
      {:ok, turn}
    else
      turn
      |> Turn.changeset(attrs)
      |> Repo.update()
    end
  end

  defp primer_turn(%Conversation{turns: turns}, todo_id) when is_list(turns) do
    Enum.find(turns, &primer_turn?(&1, todo_id))
  end

  defp primer_turn(%Conversation{id: conversation_id}, todo_id) do
    Turn
    |> where([turn], turn.conversation_id == ^conversation_id)
    |> where(
      [turn],
      turn.origin_id == ^primer_origin_id(todo_id) or
        fragment("?->>'message_class' = ?", turn.structured_data, "todo_chat_primer")
    )
    |> order_by([turn], desc: turn.inserted_at)
    |> limit(1)
    |> Repo.one()
  end

  defp primer_turn?(
         %Turn{origin_id: origin_id, structured_data: structured_data},
         todo_id
       ) do
    origin_id == primer_origin_id(todo_id) or
      get_in(structured_data || %{}, ["message_class"]) == "todo_chat_primer"
  end

  defp primer_origin_id(todo_id), do: "todo-chat-primer:#{todo_id}"

  defp draft_for(%Todo{} = todo, card) do
    existing = ActionCards.draft_preview(card) || ActionDrafts.preview(todo.action_draft || %{})

    if present?(existing) do
      %{
        "kind" => read_string(todo.action_draft || %{}, "kind") || "prepared_next_step",
        "label" => read_string(todo.action_draft || %{}, "label") || "Drafted next step",
        "text" => existing,
        "source" => read_string(todo.action_draft || %{}, "source") || "todo_action_draft",
        "style" => read_string(todo.action_draft || %{}, "style") || "already_available"
      }
      |> compact_map()
    else
      next_step =
        first_present([
          read_string(card, "next_best_action"),
          todo.next_action,
          "Open the source context, confirm the exact ask, and decide whether to reply, delegate, or dismiss it."
        ])

      %{
        "kind" => "next_step",
        "label" => "Next step",
        "text" => "Next step: #{next_step}",
        "source" => "existing_todo_context",
        "style" => "read_only_context"
      }
      |> compact_map()
    end
  end

  defp primer_text(%Todo{} = todo, card, draft) do
    [
      "I’ve got this work item in context.",
      read_line("My read", read_string(card, "decision_prompt") || read_string(card, "headline")),
      read_line("Why now", read_string(card, "why_now")),
      draft_section(draft),
      "I can tighten the wording, prepare the connected action for approval, or mark it done once you’ve handled it."
    ]
    |> Enum.reject(&blank?/1)
    |> Enum.join("\n\n")
    |> then(fn text ->
      if present?(todo.title), do: text, else: "I’ve got this work item in context.\n\n#{text}"
    end)
  end

  defp read_line(_label, nil), do: nil
  defp read_line(label, value), do: "#{label}: #{value}"

  defp first_present(values), do: Enum.find(values, &present?/1)

  defp draft_section(%{"label" => label, "text" => text} = draft) when is_binary(text) do
    case read_string(draft, "subject") do
      nil -> "#{label}:\n#{text}"
      subject -> "#{label}:\nSubject: #{subject}\n\n#{text}"
    end
  end

  defp draft_section(_draft), do: nil

  defp public_card(card) when is_map(card) do
    %{
      "headline" => read_string(card, "headline"),
      "decision_prompt" => read_string(card, "decision_prompt"),
      "why_now" => read_string(card, "why_now"),
      "next_best_action" => read_string(card, "next_best_action"),
      "draft_preview" => ActionCards.draft_preview(card),
      "evidence_excerpt" => ActionCards.evidence_excerpt(card),
      "source_context" => ActionCards.source_health_note(card),
      "prepared_action" => ActionCards.prepared_action_hint(card)
    }
    |> compact_map()
  end

  defp public_card(_card), do: %{}

  defp present?(value), do: not blank?(value)

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?([]), do: true
  defp blank?(%{}), do: true
  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(_value), do: false

  defp compact_map(map) do
    map
    |> Enum.reject(fn {_key, value} -> blank?(value) end)
    |> Map.new()
  end

  defp read_string(map, key) when is_map(map) do
    case Map.get(map, key) || Map.get(map, to_string(key)) do
      value when is_binary(value) ->
        value = String.trim(value)
        if value == "", do: nil, else: value

      value when is_atom(value) ->
        value |> Atom.to_string() |> read_non_empty()

      value when is_integer(value) ->
        Integer.to_string(value)

      _ ->
        nil
    end
  end

  defp read_string(_map, _key), do: nil

  defp read_non_empty(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end
end
