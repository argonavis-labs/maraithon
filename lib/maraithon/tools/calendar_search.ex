defmodule Maraithon.Tools.CalendarSearch do
  @moduledoc """
  Substring-search the user's macOS Calendar events on title, notes, and
  location. Reads from `Maraithon.LocalCalendar`.

  Args:
    * `user_id` (required)
    * `query`   (required)
    * `since`   — ISO-8601 datetime (default: 90 days ago)
    * `limit`   — integer (default: 20, max: 100)
  """

  import Maraithon.Tools.ActionHelpers

  alias Maraithon.LocalCalendar
  alias Maraithon.Tools.LocalCalendarHelpers

  @default_limit 20
  @max_limit 100

  def execute(args) when is_map(args) do
    with {:ok, user_id} <- required_string(args, "user_id"),
         {:ok, query} <- required_string(args, "query"),
         {:ok, since} <- LocalCalendarHelpers.parse_optional_datetime(args, "since") do
      limit = LocalCalendarHelpers.normalize_limit(args, @default_limit, @max_limit)

      opts =
        []
        |> Keyword.put(:limit, limit)
        |> maybe_put(:since, since)

      events = LocalCalendar.search(user_id, query, opts)

      {:ok,
       %{
         source: "local_calendar",
         query: query,
         count: length(events),
         events: Enum.map(events, &LocalCalendarHelpers.serialize_summary/1)
       }}
    end
  end

  def execute(_args), do: {:error, "invalid_args"}
end
