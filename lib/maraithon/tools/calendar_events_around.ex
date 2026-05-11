defmodule Maraithon.Tools.CalendarEventsAround do
  @moduledoc """
  List the user's macOS Calendar events that overlap a given date window.

  Reads from `Maraithon.LocalCalendar`, which mirrors the macOS
  Calendar.app store. Because Calendar.app aggregates every calendar
  account the user has added (iCloud, Exchange, Google CalDAV, etc.),
  this is the user's full cross-account schedule.

  Args:
    * `user_id` (required)
    * `since`   — ISO-8601 datetime (default: now)
    * `until`   — ISO-8601 datetime (default: now + 7 days)
    * `limit`   — integer (default: 30, max: 100)
  """

  import Maraithon.Tools.ActionHelpers

  alias Maraithon.LocalCalendar
  alias Maraithon.Tools.LocalCalendarHelpers

  @default_limit 30
  @max_limit 100

  def execute(args) when is_map(args) do
    with {:ok, user_id} <- required_string(args, "user_id"),
         {:ok, since} <- LocalCalendarHelpers.parse_optional_datetime(args, "since"),
         {:ok, until} <- LocalCalendarHelpers.parse_optional_datetime(args, "until") do
      limit = LocalCalendarHelpers.normalize_limit(args, @default_limit, @max_limit)

      opts =
        []
        |> Keyword.put(:limit, limit)
        |> maybe_put(:since, since)
        |> maybe_put(:until, until)

      events = LocalCalendar.events_around(user_id, opts)

      {:ok,
       %{
         source: "local_calendar",
         count: length(events),
         events: Enum.map(events, &LocalCalendarHelpers.serialize_summary/1)
       }}
    end
  end

  def execute(_args), do: {:error, "invalid_args"}
end
