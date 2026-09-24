defmodule Maraithon.Todos.SlackSourceIdentity do
  @moduledoc "Resolves the author of the exact source message, scoped to its user and workspace."

  import Ecto.Query
  alias Maraithon.{OAuth, Repo}
  alias Maraithon.Connectors.Slack
  alias Maraithon.Crm.Observation
  alias Maraithon.Tools.SlackHelpers
  alias Maraithon.Todos.Todo

  def resolve(%Todo{source: "slack"} = todo) do
    location = location(todo)

    with true <- is_binary(location.channel) and is_binary(location.timestamp) do
      case cached_author(todo, location) || observed_author(todo, location) do
        %{"inbound" => false, "team_id" => team} = author ->
          fetched_author(todo, %{location | team: team}) || author

        %{} = author ->
          author

        _ ->
          fetched_author(todo, location)
      end
    else
      _ -> nil
    end
  end

  def resolve(_), do: nil

  def location(%Todo{} = todo) do
    metadata = todo.metadata || %{}
    ref = metadata["source_ref"] || ""

    {team, channel, timestamp} =
      case Regex.run(~r/^slack[: ](T[A-Z0-9]+):([CDG][A-Z0-9]+):(\d+\.\d+)$/, ref) do
        [_, team, channel, timestamp] -> {team, channel, timestamp}
        _ -> {nil, nil, nil}
      end

    {item_channel, item_ts} =
      case Regex.run(~r/(?:^|:)([CDG][A-Z0-9]+):(\d+\.\d+)$/, todo.source_item_id || "") do
        [_, channel, timestamp] -> {channel, timestamp}
        _ -> {nil, nil}
      end

    %{
      team: team || metadata["team_id"],
      channel: item_channel || channel || metadata["channel_id"] || metadata["channel"],
      timestamp: item_ts || timestamp || metadata["message_ts"] || metadata["ts"]
    }
  end

  defp cached_author(todo, location) do
    case (todo.metadata || %{})["slack_source_author"] do
      %{
        "team_id" => team,
        "channel_id" => channel,
        "message_ts" => ts,
        "user_id" => user,
        "inbound" => inbound,
        "verified" => true
      } = author
      when is_binary(team) and is_binary(user) and is_boolean(inbound) ->
        if channel == location.channel and ts == location.timestamp and
             (is_nil(location.team) or team == location.team),
           do: author

      _ ->
        nil
    end
  end

  defp observed_author(todo, location) do
    suffix = "%:#{location.channel}:#{location.timestamp}"
    item = "#{location.channel}:#{location.timestamp}"

    query =
      from o in Observation,
        where: o.user_id == ^todo.user_id and o.source == "slack",
        where: o.source_item_id == ^item or like(o.source_item_id, ^suffix),
        limit: 2

    query =
      if location.team,
        do: where(query, [o], fragment("?->>'team_id'", o.metadata) == ^location.team),
        else: query

    case Repo.all(query) do
      [observation] ->
        authors = observation.participants |> Enum.filter(&(&1["role"] == "from"))
        team = observation.metadata["team_id"] || location.team

        case authors do
          [author] ->
            identity(
              team,
              location,
              get_in(author, ["identifier", "slack_id"]),
              observation.direction == "inbound"
            )

          _ ->
            nil
        end

      _ ->
        nil
    end
  end

  defp fetched_author(todo, %{team: team} = location) when is_binary(team) do
    with {:ok, access} <- SlackHelpers.resolve_access_token(todo.user_id, team),
         {:ok, message} <- fetch_source_message(todo, access, location) do
      own_ids =
        OAuth.list_user_tokens(todo.user_id)
        |> Enum.flat_map(fn token ->
          case String.split(token.provider, ":") do
            ["slack", ^team, "user", id] -> [id]
            _ -> []
          end
        end)

      # Without a connected human identity, do not reinterpret generic prose
      # as somebody else's request; still resolve the author's bare Slack ID.
      inbound = own_ids != [] and message["user"] not in own_ids

      if inbound do
        identity(team, location, message["user"], true)
      else
        counterparty = counterparty(access, location, message, own_ids)

        if counterparty do
          identity(team, location, counterparty, true)
          |> Map.put("role", "counterparty")
          |> Map.put("source_author_id", message["user"])
        else
          identity(team, location, message["user"], false)
        end
      end
    else
      _ -> nil
    end
  end

  defp fetched_author(_, _), do: nil

  defp fetch_source_message(todo, access, location) do
    case source_message(access, location, todo.metadata || %{}) do
      {:ok, _} = found -> found
      _ -> search_source_message(todo.user_id, location)
    end
  end

  # History omits thread replies when older candidates lost their root ID.
  # Search is bounded, and only the exact channel and timestamp may match.
  defp search_source_message(user_id, location) do
    with {:ok, access} <-
           SlackHelpers.resolve_access_token(user_id, location.team,
             token_preference: "user",
             required_scopes: ["search:read"]
           ),
         {seconds, _} <- Integer.parse(location.timestamp),
         {:ok, at} <- DateTime.from_unix(seconds) do
      day = DateTime.to_date(at)
      query = "in:#{location.channel} after:#{Date.add(day, -1)} before:#{Date.add(day, 1)}"

      Enum.reduce_while(1..2, {:error, :source_message_unavailable}, fn page, _ ->
        case Slack.search_messages(access, query,
               count: 100,
               page: page,
               sort: "timestamp",
               sort_dir: "asc"
             ) do
          {:ok, %{"messages" => %{"matches" => messages}}} ->
            case Enum.find(
                   messages,
                   &(&1["ts"] == location.timestamp and
                       get_in(&1, ["channel", "id"]) == location.channel)
                 ) do
              %{} = message -> {:halt, {:ok, message}}
              _ when length(messages) < 100 -> {:halt, {:error, :source_message_unavailable}}
              _ -> {:cont, {:error, :source_message_unavailable}}
            end

          _ ->
            {:halt, {:error, :source_message_unavailable}}
        end
      end)
    else
      _ -> {:error, :source_message_unavailable}
    end
  end

  defp counterparty(_access, _location, _message, []), do: nil

  defp counterparty(access, location, message, own_ids) do
    mentioned = Maraithon.Slack.UserDirectory.user_ids_from_text(message["text"]) -- own_ids

    case mentioned do
      [id] ->
        id

      _ ->
        if String.starts_with?(location.channel, "D") do
          case Slack.get_channel_info(access, location.channel) do
            {:ok, %{"channel" => %{"is_im" => true, "user" => id}}} ->
              if id not in own_ids, do: id

            _ ->
              nil
          end
        else
          thread_counterparty(access, location, message["thread_ts"], own_ids)
        end
    end
  end

  defp thread_counterparty(access, location, root, own_ids) when is_binary(root) do
    case Slack.get_thread_replies(access, location.channel, root, limit: 30) do
      {:ok, %{"messages" => messages, "has_more" => false}} ->
        case messages
             |> Enum.map(& &1["user"])
             |> Enum.reject(&is_nil/1)
             |> Enum.uniq()
             |> Kernel.--(own_ids) do
          [id] -> id
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp thread_counterparty(_, _, _, _), do: nil

  defp source_message(access, location, metadata) do
    opts = [oldest: location.timestamp, latest: location.timestamp, inclusive: true, limit: 1]

    response =
      case metadata["thread_ts"] do
        root when is_binary(root) and root != location.timestamp ->
          Slack.get_thread_replies(access, location.channel, root, opts)

        _ ->
          Slack.get_conversation_history(access, location.channel, opts)
      end

    with {:ok, %{"messages" => messages}} <- response,
         %{} = message <- Enum.find(messages, &(&1["ts"] == location.timestamp)) do
      {:ok, message}
    else
      _ -> {:error, :source_message_unavailable}
    end
  end

  defp identity(team, location, user, inbound) when is_binary(team) and is_binary(user) do
    if Regex.match?(~r/^[UW][A-Z0-9]+$/, user) do
      %{
        "team_id" => team,
        "channel_id" => location.channel,
        "message_ts" => location.timestamp,
        "user_id" => user,
        "inbound" => inbound,
        "verified" => true
      }
    end
  end

  defp identity(_, _, _, _), do: nil
end
