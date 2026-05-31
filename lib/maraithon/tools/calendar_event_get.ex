defmodule Maraithon.Tools.CalendarEventGet do
  @moduledoc """
  Fetch one macOS Calendar event using an `event_id` returned by
  calendar search or event-list tools.

  Args:
    * `user_id`  (required)
    * `event_id` (required)
  """

  import Maraithon.Tools.ActionHelpers

  alias Maraithon.LocalCalendar
  alias Maraithon.Tools.LocalCalendarHelpers

  def execute(args) when is_map(args) do
    with {:ok, user_id} <- required_string(args, "user_id"),
         {:ok, event_id} <- required_string(args, "event_id") do
      case LocalCalendar.get_by_guid(user_id, event_id) do
        nil ->
          {:error, "calendar_event_not_found"}

        event ->
          {:ok,
           %{
             source: "local_calendar",
             event: LocalCalendarHelpers.serialize_full(event)
           }}
      end
    end
  end

  def execute(_args), do: {:error, "invalid_args"}
end
