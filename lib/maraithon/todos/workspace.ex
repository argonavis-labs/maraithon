defmodule Maraithon.Todos.Workspace do
  @moduledoc """
  Grounded people and next-action projections for every todo surface.
  The existing durable brief job authors the plan; opening a view never runs a model.
  """
  alias Maraithon.Crm

  def candidate_people(user_id, todo, source) do
    evidence = Jason.encode!(%{source: source, title: todo.title, summary: todo.summary})
    linked = Crm.people_for_resource(user_id, "todo", todo.id, limit: 8)

    mentioned =
      Crm.list_people(user_id, limit: 500)
      |> Enum.filter(fn person ->
        mentioned?(evidence, person.display_name) or mentioned?(evidence, person.first_name)
      end)
      |> Enum.sort_by(fn person -> not mentioned?(evidence, person.display_name) end)

    (linked ++ mentioned) |> Enum.uniq_by(& &1.id) |> Enum.take(12)
  end

  def normalize_people(values, context) when is_list(values) do
    evidence = Jason.encode!(%{source: context.source, people: context.people})

    values
    |> Enum.filter(&is_map/1)
    |> Enum.flat_map(fn person ->
      name = text(person["name"], 100)

      known =
        Enum.find(
          context.people,
          &(&1["person_id"] == person["person_id"] && is_binary(person["person_id"]))
        )

      if known || mentioned?(evidence, name) do
        [
          %{
            "id" => if(known, do: known["person_id"], else: "mentioned:" <> to_string(name)),
            "name" => if(known, do: known["name"], else: name),
            "relationship" => if(known, do: known["relationship"]),
            "context" => text(person["context"], 500),
            "last_interaction_at" => if(known, do: known["last_interaction_at"]),
            "verified_profile" => not is_nil(known)
          }
        ]
      else
        []
      end
    end)
    |> Enum.uniq_by(& &1["id"])
    |> Enum.take(6)
  end

  def normalize_people(_, _), do: []

  def normalize_actions(values, people) when is_list(values) do
    values
    |> Enum.filter(&is_map/1)
    |> Enum.filter(&(&1["provider"] in ~w(calendar gmail imessage slack browser)))
    |> Enum.with_index()
    |> Enum.flat_map(fn {action, index} ->
      label = text(action["label"], 100)
      purpose = text(action["purpose"], 500)
      person = Enum.find(people, &(&1["name"] == action["person_name"]))

      if label && purpose do
        [
          %{
            "id" => "action-#{index}",
            "label" => label,
            "provider" => action["provider"],
            "purpose" => purpose,
            "person_name" => if(person, do: person["name"]),
            "prompt" => prompt(action["provider"], purpose, person)
          }
        ]
      else
        []
      end
    end)
    |> Enum.take(4)
  end

  def normalize_actions(_, _), do: []

  defp prompt(provider, purpose, person) do
    target = if person, do: " Involve #{person["name"]} (#{person["context"]}).", else: ""

    case provider do
      "browser" ->
        "Use todo_browser to carry out this next step in background Chrome on my Mac: #{purpose}.#{target} Inspect the live page and prepare any interaction for review."

      "calendar" ->
        "Check my real calendar and prepare a calendar event to move this todo forward: #{purpose}.#{target} Show the actual time and timezone for approval; do not book yet."

      "imessage" ->
        "Prepare an editable iMessage using draft_imessage: #{purpose}.#{target} Resolve the exact recipient from my People or Messages first. Do not send."

      "gmail" ->
        "Prepare an editable email draft for review: #{purpose}.#{target} Check the source, recipient, and sending account. Use the saved draft and approval card. Do not send."

      "slack" ->
        "Prepare a Slack reply for review: #{purpose}.#{target} Verify the workspace and thread. Do not post."

      _ ->
        "Help me carry out this next step: #{purpose}.#{target} Explain the concrete action and open the exact source when available."
    end
  end

  defp mentioned?(text, name) when is_binary(name) and byte_size(name) > 2 do
    Regex.match?(
      Regex.compile!("(?<![\\p{L}\\p{N}])" <> Regex.escape(name) <> "(?![\\p{L}\\p{N}])", "iu"),
      text
    )
  end

  defp mentioned?(_, _), do: false

  defp text(value, limit) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      text -> String.slice(text, 0, limit)
    end
  end

  defp text(_, _), do: nil
end
