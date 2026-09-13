defmodule Maraithon.Todos.Brief.SearchedSlackContext do
  @moduledoc """
  Recovers one original Slack message when thread history is unavailable.
  Search results must match both the saved channel and exact timestamp. This
  is partial source coverage; it never claims to have checked later replies.
  """
  alias Maraithon.Connectors.Slack
  alias Maraithon.Tools
  alias Maraithon.Tools.SlackHelpers
  alias Maraithon.Todos.SourceActions

  def read(user_id, todo) do
    %{team: team, channel: channel, timestamp: timestamp} = SourceActions.slack_location(todo)

    with true <- is_binary(team) and is_binary(channel) and is_binary(timestamp),
         {seconds, _} <- Integer.parse(timestamp),
         {:ok, at} <- DateTime.from_unix(seconds),
         name when is_binary(name) <- channel_name(user_id, team, channel, todo.metadata || %{}),
         day = DateTime.to_date(at),
         query = "in:#{name} after:#{Date.add(day, -1)} before:#{Date.add(day, 2)}",
         {:ok, %{matches: matches}} <-
           Tools.execute(
             "slack_search_messages",
             %{"user_id" => user_id, "team_id" => team, "query" => query, "count" => 100},
             %{surface: "internal", user_id: user_id}
           ),
         %{} = message <- Enum.find(matches, &(&1.channel_id == channel and &1.ts == timestamp)) do
      %{
        "status" => "excerpt_only",
        "provider" => "slack",
        "team_id" => team,
        "thread_ts" => timestamp,
        "channel_name" => message.channel_name,
        "permalink" => message.permalink,
        "conversation" => [
          %{
            "user_id" => message.user,
            "from" => message.user,
            "text" => String.slice(message.text || "", 0, 6_000),
            "at" => DateTime.to_iso8601(at),
            "is_source_message" => true
          }
        ],
        "freshness_note" =>
          "Original message recovered from Slack search. Full thread history is unavailable; check the conversation for newer replies before acting."
      }
    else
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp channel_name(user_id, team, channel, metadata) do
    case metadata["slack_channel_name"] || metadata["channel_name"] do
      name when is_binary(name) and name != "" ->
        name

      _ ->
        with {:ok, token} <- SlackHelpers.resolve_access_token(user_id, team),
             {:ok, %{"channel" => %{"name" => name}}} <-
               Slack.get_channel_info(token.access_token, channel) do
          name
        else
          _ -> nil
        end
    end
  end
end
