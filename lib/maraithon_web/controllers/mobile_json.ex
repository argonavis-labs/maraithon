defmodule MaraithonWeb.MobileJSON do
  @moduledoc false

  alias Maraithon.ActionCards
  alias Maraithon.Accounts.{User, UserSession}
  alias Maraithon.Crm
  alias Maraithon.Crm.Person
  alias Maraithon.Crm.RelationshipPresentation
  alias Maraithon.Todos.{ActivityEvent, PublicMetadata, SourceActions, Todo, UserFacingCopy}
  alias MaraithonWeb.ApiErrorCopy

  def user(%User{} = user, %UserSession{} = session) do
    %{
      id: user.id,
      email: user.email,
      is_admin: user.is_admin,
      confirmed_at: json_value(user.confirmed_at),
      session_expires_at: json_value(session.expires_at)
    }
  end

  def user(%User{} = user, expires_at) do
    %{
      id: user.id,
      email: user.email,
      is_admin: user.is_admin,
      confirmed_at: json_value(user.confirmed_at),
      session_expires_at: json_value(expires_at)
    }
  end

  def todo(%Todo{} = todo, opts \\ []) do
    todo = UserFacingCopy.polish_attrs(todo)

    base = %{
      id: todo.id,
      source: todo.source,
      kind: todo.kind,
      attention_mode: todo.attention_mode,
      title: todo.title,
      summary: todo.summary,
      next_action: todo.next_action,
      due_at: json_value(todo.due_at),
      notes: todo.notes,
      action_plan: todo.action_plan,
      owner_label: todo.owner_label,
      priority: todo.priority,
      status: todo.status,
      snoozed_until: json_value(todo.snoozed_until),
      closed_at: json_value(todo.closed_at),
      source_occurred_at: json_value(todo.source_occurred_at),
      metadata: public_todo_metadata(todo.metadata || %{}),
      related_people: related_people(todo),
      inserted_at: json_value(todo.inserted_at),
      updated_at: json_value(todo.updated_at)
    }

    if Keyword.get(opts, :include_card, false) do
      Map.put(base, :action_card, action_card(todo, opts))
    else
      base
    end
  end

  def todo_activity_event(%ActivityEvent{} = event) do
    %{
      id: event.id,
      event_type: event.event_type,
      actor_type: event.actor_type,
      actor_id: event.actor_id,
      actor_label: event.actor_label,
      todo_id: event.todo_id,
      todo_title: event.todo_title,
      todo_source: event.todo_source,
      metadata: event.metadata || %{},
      occurred_at: json_value(event.occurred_at),
      inserted_at: json_value(event.inserted_at)
    }
  end

  def person(%Person{} = person) do
    %{
      id: person.id,
      first_name: person.first_name,
      last_name: person.last_name,
      display_name: person.display_name,
      contact_details: person.contact_details || %{},
      preferred_communication_method: person.preferred_communication_method,
      relationship: person.relationship,
      communication_frequency: person.communication_frequency,
      interaction_count: person.interaction_count,
      relationship_health: RelationshipPresentation.health_level(person.relationship_strength),
      relationship_warmth: RelationshipPresentation.warmth_level(person.affinity_score),
      last_interaction_at: json_value(person.last_interaction_at),
      status: person.status,
      notes: person.notes,
      metadata: public_person_metadata(person.metadata || %{}),
      inserted_at: json_value(person.inserted_at),
      updated_at: json_value(person.updated_at)
    }
  end

  def public_person_metadata(metadata), do: PublicMetadata.person(metadata)

  def error(reason) do
    ApiErrorCopy.mobile(reason)
  end

  defp action_card(%Todo{} = todo, opts) do
    card =
      ActionCards.for_todo(
        todo,
        Keyword.put_new(opts, :include_disconnected, true)
      )

    %{
      id: card["id"],
      kind: card["kind"],
      headline: card["headline"],
      decision_prompt: card["decision_prompt"],
      why_now: card["why_now"],
      rank_reason: card["rank_reason"],
      attention_mode: card["attention_mode"],
      context_items: ActionCards.context_items(card),
      evidence_excerpt: ActionCards.evidence_excerpt(card),
      next_best_action: card["next_best_action"],
      draft_preview: ActionCards.draft_preview(card),
      prepared_actions: card["prepared_actions"] || [],
      available_buttons: format_buttons(card["available_buttons"] || []),
      estimated_effort: card["estimated_effort"],
      source_context: source_context(card),
      source_action: SourceActions.for_todo(todo)
    }
  end

  defp format_buttons(buttons) do
    buttons
    |> List.wrap()
    |> Enum.reject(&is_nil/1)
    |> Enum.map(fn action ->
      action = to_string(action)
      %{action: action, label: button_label(action)}
    end)
  end

  defp button_label(action) do
    case action do
      "done" -> "Done"
      "dismiss" -> "Dismiss"
      "snooze" -> "Snooze"
      "important" -> "Keep active"
      "not_important" -> "Less useful"
      "not_helpful" -> "Less useful"
      "helpful" -> "Helpful"
      "keep_active" -> "Keep active"
      "see_less" -> "Show less"
      "more_context" -> "More context"
      "open_dashboard" -> "Open Maraithon"
      other -> other |> String.replace("_", " ") |> String.capitalize()
    end
  end

  defp source_context(card) when is_map(card) do
    ActionCards.source_health_note(card)
  end

  defp source_context(_card), do: nil

  def public_todo_metadata(metadata), do: PublicMetadata.todo(metadata)

  defp related_people(%Todo{user_id: user_id, id: todo_id})
       when is_binary(user_id) and is_binary(todo_id) do
    user_id
    |> Crm.people_for_resource("todo", todo_id, limit: 5)
    |> Enum.map(fn %Person{} = person ->
      %{
        id: person.id,
        display_name: person.display_name,
        relationship: person.relationship
      }
    end)
  end

  defp related_people(_todo), do: []

  defp json_value(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp json_value(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  defp json_value(value), do: value
end
