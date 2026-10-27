defmodule Maraithon.Tools.CalendarEventsForPerson do
  @moduledoc """
  Find macOS Calendar events that involve a specific person (matched by
  email or name substring against the attendee list, organizer email,
  and event title).

  Args:
    * `user_id`             (required)
    * `email_or_substring`  (required)
    * `since`               — ISO-8601 datetime (default: 30 days ago)
    * `limit`               — integer (default: 20, max: 100)
  """

  import Maraithon.Tools.ActionHelpers

  alias Maraithon.LocalCalendar
  alias Maraithon.Tools.LocalCalendarHelpers

  @default_limit 20
  @max_limit 100

  def execute(args) when is_map(args) do
    with {:ok, user_id} <- required_string(args, "user_id"),
         {:ok, needle} <- required_string(args, "email_or_substring"),
         {:ok, since} <- LocalCalendarHelpers.parse_optional_datetime(args, "since") do
      limit = LocalCalendarHelpers.normalize_limit(args, @default_limit, @max_limit)

      opts =
        []
        |> Keyword.put(:limit, limit)
        |> maybe_put(:since, since)

      events = LocalCalendar.events_for_attendee(user_id, needle, opts)

      {:ok,
       %{
         source: "local_calendar",
         query: needle,
         count: length(events),
         events: Enum.map(events, &LocalCalendarHelpers.serialize_summary/1)
       }}
    end
  end

  def execute(_args), do: {:error, "invalid_args"}
end
