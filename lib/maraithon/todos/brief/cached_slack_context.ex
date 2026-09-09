defmodule Maraithon.Todos.Brief.CachedSlackContext do
  @moduledoc """
  Reads original Slack events already ingested for this user. Cached coverage
  stays explicit: these are source messages, not AI summaries or a claim that
  Slack has no newer replies. Detail views do not spend a provider request on
  every open when durable source evidence is already available.
  """
  import Ecto.Query
  alias Maraithon.Crm.Observation
  alias Maraithon.Repo

  def read(user_id, todo) do
    %{team: team, channel: channel, timestamp: timestamp} =
      Maraithon.Todos.SourceActions.slack_location(todo)

    if is_binary(team) and is_binary(channel) and is_binary(timestamp) do
      ids = ["#{team}:#{channel}:#{timestamp}", "#{team}:#{todo.source_item_id}"]

      original =
        Repo.one(
          from o in Observation,
            where: o.user_id == ^user_id and o.source == "slack" and o.source_item_id in ^ids,
            order_by: [asc: o.occurred_at],
            limit: 1
        )

      if original, do: context(user_id, team, channel, timestamp, original)
    end
  rescue
    _ -> nil
  end

  defp context(user_id, team, channel, timestamp, original) do
    root = original.metadata["thread_ts"] || original.metadata["ts"] || timestamp
    lower = DateTime.add(original.occurred_at, -86_400, :second)

    rows =
      Repo.all(
        from o in Observation,
          where: o.user_id == ^user_id and o.source == "slack" and o.occurred_at >= ^lower,
          where: fragment("?->>'team_id'", o.metadata) == ^team,
          where: fragment("?->>'channel'", o.metadata) == ^channel,
          where:
            fragment("?->>'thread_ts'", o.metadata) == ^root or
              fragment("?->>'ts'", o.metadata) == ^root,
          order_by: [desc: o.occurred_at],
          limit: 30
      )

    messages =
      [original | rows]
      |> Enum.uniq_by(& &1.id)
      |> Enum.sort_by(& &1.occurred_at, DateTime)
      |> Enum.map(fn row ->
        author = Enum.find(row.participants || [], &(&1["role"] == "from")) || %{}
        user = get_in(author, ["identifier", "slack_id"])

        %{
          "user_id" => user,
          "from" => author["display_name"] || user,
          "text" => String.slice(row.metadata["text"] || row.excerpt || "", 0, 3_000),
          "at" => DateTime.to_iso8601(row.occurred_at),
          "from_user" => row.direction == "outbound",
          "is_source_message" => row.id == original.id
        }
      end)
      |> Enum.reject(&(&1["text"] == ""))

    if messages != [] do
      %{
        "status" => "cached",
        "provider" => "slack",
        "team_id" => team,
        "thread_ts" => root,
        "messages" => messages,
        "freshness_note" =>
          "Original synced Slack messages. Newer replies, edits or deletions may not be included; check the conversation before acting."
      }
    end
  end
end
