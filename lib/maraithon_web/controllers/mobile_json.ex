defmodule MaraithonWeb.MobileJSON do
  @moduledoc false

  alias Maraithon.Accounts.{User, UserSession}
  alias Maraithon.Crm.Person
  alias Maraithon.Todos.Todo

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

  def todo(%Todo{} = todo) do
    %{
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
      owner_user_id: todo.owner_user_id,
      owner_label: todo.owner_label,
      priority: todo.priority,
      status: todo.status,
      snoozed_until: json_value(todo.snoozed_until),
      closed_at: json_value(todo.closed_at),
      source_item_id: todo.source_item_id,
      source_occurred_at: json_value(todo.source_occurred_at),
      dedupe_key: todo.dedupe_key,
      metadata: todo.metadata || %{},
      inserted_at: json_value(todo.inserted_at),
      updated_at: json_value(todo.updated_at)
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
      relationship_strength: person.relationship_strength,
      affinity_score: person.affinity_score,
      last_interaction_at: json_value(person.last_interaction_at),
      status: person.status,
      notes: person.notes,
      metadata: person.metadata || %{},
      inserted_at: json_value(person.inserted_at),
      updated_at: json_value(person.updated_at)
    }
  end

  def error(reason) do
    %{error: format_error(reason)}
  end

  defp json_value(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp json_value(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  defp json_value(value), do: value

  defp format_error(reason) when is_atom(reason), do: reason |> Atom.to_string()
  defp format_error(reason), do: inspect(reason)
end
