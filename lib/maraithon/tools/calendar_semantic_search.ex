defmodule Maraithon.Tools.CalendarSemanticSearch do
  @moduledoc """
  Semantic search of the user's mirrored macOS Calendar events by
  meaning, not exact substring. Pairs with `calendar_search` — use
  this tool when the user asks "when's the meeting about something
  similar" and won't recall the exact title. Stick to
  `calendar_search` when the user gives an exact phrase or title.
  """

  import Maraithon.Tools.ActionHelpers

  alias Maraithon.LocalCalendar
  alias Maraithon.Tools.LocalCalendarHelpers

  @default_limit 12
  @max_limit 50

  def execute(args) when is_map(args) do
    with {:ok, user_id} <- required_string(args, "user_id"),
         {:ok, query} <- required_string(args, "query"),
         {:ok, since} <- LocalCalendarHelpers.parse_optional_datetime(args, "since") do
      limit = LocalCalendarHelpers.normalize_limit(args, @default_limit, @max_limit)

      opts =
        []
        |> Keyword.put(:limit, limit)
        |> maybe_put(:since, since)

      events = LocalCalendar.semantic_search(user_id, query, opts)

      {:ok,
       %{
         source: "local_calendar",
         query: query,
         search_mode: "semantic",
         count: length(events),
         events: Enum.map(events, &LocalCalendarHelpers.serialize_summary/1)
       }}
    end
  end

  def execute(_args), do: {:error, "invalid_args"}
end
