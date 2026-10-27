defmodule Maraithon.Todos.SlackNames do
  @moduledoc "Workspace-scoped Slack names, resolved during background task preparation."

  alias Maraithon.Slack.UserDirectory
  alias Maraithon.Todos.{SlackSourceIdentity, Todo}

  @fields ~w(title summary next_action notes action_plan owner_label counterparty_label agent_action_label)a
  @labels ~w(person sender_name requested_by contact counterparty_display_name)
  @generic ~r/\b(?:(?:your|the|a)\s+)?(?:teammate|colleague|coworker|co-worker|sender)\b/i
  @qualified_generic ~r/\byour\s+(?:(?!(?:a|the|your|from|for|with|to|of|and|needs|requires|ask)\b)[\p{L}\p{N}_-]+\s+){1,3}(?:teammate|colleague|coworker|co-worker)\b/i

  def needed?(%Todo{source: "slack"} = todo) do
    Enum.any?(@fields, fn field ->
      text = Map.get(todo, field)
      (field != :owner_label and generic?(text)) or copy_ids(text) != []
    end) or
      Enum.any?(@labels, fn field ->
        text = (todo.metadata || %{})[field]
        generic?(text) or copy_ids(text) != []
      end)
  end

  def needed?(_), do: false

  def changes(%Todo{source: "slack"} = todo) do
    metadata = todo.metadata || %{}

    author =
      if Enum.any?(@fields, &generic?(Map.get(todo, &1))) or
           Enum.any?(@labels, &generic?(metadata[&1])),
         do: SlackSourceIdentity.resolve(todo)

    team = (author && author["team_id"]) || SlackSourceIdentity.location(todo).team
    saved = directory(todo)

    ids =
      (Enum.map(@fields, &Map.get(todo, &1)) ++ Enum.map(@labels, &metadata[&1]))
      |> Enum.flat_map(&UserDirectory.ids_in_copy/1)
      |> then(&Enum.uniq(List.wrap(author && author["user_id"]) ++ &1))

    missing = Enum.reject(ids, &Map.has_key?(saved, &1))

    names =
      UserDirectory.for_workspace(todo.user_id, team, missing, max_users: 8, timeout: 10_000)
      |> Map.merge(saved)

    if map_size(names) == 0 do
      %{}
    else
      author_name =
        if author && author["inbound"],
          do: UserDirectory.display_name(names, author["user_id"])

      changes = replace_fields(todo, @fields, names, author_name)
      metadata = Map.merge(metadata, replace_fields(metadata, @labels, names, author_name))
      metadata = Map.put(metadata, "slack_user_names", %{"team_id" => team, "names" => names})

      metadata =
        if author && author_name,
          do:
            metadata
            |> Map.put("slack_source_author", Map.put(author, "display_name", author_name))
            |> Map.put_new("team_id", team),
          else: metadata

      if metadata == todo.metadata, do: changes, else: Map.put(changes, :metadata, metadata)
    end
  end

  def changes(_), do: %{}

  def directory(%Todo{} = todo) do
    team = SlackSourceIdentity.location(todo).team

    case (todo.metadata || %{})["slack_user_names"] do
      %{"team_id" => ^team, "names" => names} when is_binary(team) and is_map(names) -> names
      _ -> %{}
    end
  end

  defp replace_fields(map, fields, names, author_name) do
    Enum.reduce(fields, %{}, fn field, changes ->
      original = Map.get(map, field)
      resolved = UserDirectory.replace_user_ids(original, names)

      resolved =
        cond do
          field == :owner_label ->
            resolved

          field == :counterparty_label and generic?(original) and is_binary(author_name) ->
            author_name

          true ->
            replace_generic(resolved, author_name)
        end

      if original == resolved, do: changes, else: Map.put(changes, field, resolved)
    end)
  end

  defp generic?(text) when is_binary(text), do: Regex.match?(@generic, without_links(text))
  defp generic?(_), do: false
  defp copy_ids(text) when is_binary(text), do: UserDirectory.ids_in_copy(without_links(text))
  defp copy_ids(_), do: []
  defp without_links(text), do: Regex.replace(~r/https?:\/\/[^\s<>]+/, text, "")

  defp replace_generic(text, name) when is_binary(text) and is_binary(name) do
    ~r/https?:\/\/[^\s<>]+/
    |> Regex.split(text, include_captures: true)
    |> Enum.map_join(fn part ->
      if String.starts_with?(part, ["http://", "https://"]),
        do: part,
        else:
          part
          |> then(&Regex.replace(@qualified_generic, &1, fn _ -> name end))
          |> then(&Regex.replace(@generic, &1, fn _ -> name end))
    end)
  end

  defp replace_generic(text, _), do: text
end
