defmodule Maraithon.Todos.SlackNames do
  @moduledoc "Workspace-scoped Slack names, resolved during background task preparation."

  alias Maraithon.Slack.UserDirectory
  alias Maraithon.Todos.{SourceActions, Todo}

  @fields ~w(title summary next_action notes action_plan owner_label counterparty_label agent_action_label)a
  @labels ~w(person sender_name requested_by contact counterparty_display_name)

  def changes(%Todo{source: "slack"} = todo) do
    %{team: team} = SourceActions.slack_location(todo)
    metadata = todo.metadata || %{}
    saved = directory(todo)

    ids =
      (Enum.map(@fields, &Map.get(todo, &1)) ++ Enum.map(@labels, &metadata[&1]))
      |> Enum.flat_map(&UserDirectory.ids_in_copy/1)
      |> Enum.uniq()

    missing = Enum.reject(ids, &Map.has_key?(saved, &1))

    names =
      UserDirectory.for_workspace(todo.user_id, team, missing, max_users: 8, timeout: 1_500)
      |> Map.merge(saved)

    if map_size(names) == 0 do
      %{}
    else
      changes = replace_fields(todo, @fields, names)
      metadata = Map.merge(metadata, replace_fields(metadata, @labels, names))
      metadata = Map.put(metadata, "slack_user_names", %{"team_id" => team, "names" => names})
      if metadata == todo.metadata, do: changes, else: Map.put(changes, :metadata, metadata)
    end
  end

  def changes(_), do: %{}

  def directory(%Todo{} = todo) do
    team = SourceActions.slack_location(todo).team

    case (todo.metadata || %{})["slack_user_names"] do
      %{"team_id" => ^team, "names" => names} when is_binary(team) and is_map(names) -> names
      _ -> %{}
    end
  end

  defp replace_fields(map, fields, names) do
    Enum.reduce(fields, %{}, fn field, changes ->
      original = Map.get(map, field)
      resolved = UserDirectory.replace_user_ids(original, names)
      if original == resolved, do: changes, else: Map.put(changes, field, resolved)
    end)
  end
end
