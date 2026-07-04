defmodule Maraithon.Tools.CalendarCancelEvent do
  @moduledoc """
  Cancels (deletes) a Maraithon-managed time block on the user's primary
  Google Calendar (SPEC 12 R9), e.g. when the linked todo is resolved.

  Runs only through the prepare -> confirm -> execute prepared-action
  pipeline, and verifies the SPEC 12 R8 ownership markers before deleting —
  Maraithon never deletes a calendar event it did not create (R11).

  Cancel is idempotent: an event the user already deleted in Google Calendar
  (404/410 on GET or DELETE) is a successful no-op, not an error.
  """

  alias Maraithon.Connectors.GoogleCalendar
  alias Maraithon.Tools.CalendarCreateEvent, as: Shared
  alias Maraithon.Tools.CalendarUpdateEvent

  def execute(args) when is_map(args) do
    with {:ok, user_id} <- Shared.required_string(args, "user_id"),
         {:ok, event_id} <- Shared.required_string(args, "event_id") do
      case CalendarUpdateEvent.verify_ownership(
             user_id,
             event_id,
             Shared.optional_string(args, "todo_id")
           ) do
        :ok ->
          delete(user_id, event_id)

        {:error, :event_gone} ->
          {:ok, already_gone(event_id)}

        {:error, reason} ->
          {:error, Shared.translate_error(reason, "cancel the calendar block")}
      end
    else
      {:error, reason} -> {:error, Shared.translate_error(reason, "cancel the calendar block")}
    end
  end

  defp delete(user_id, event_id) do
    case GoogleCalendar.delete_event(user_id, event_id) do
      {:ok, :deleted} ->
        {:ok, %{source: "google_calendar", event_id: event_id, cancelled: true}}

      {:ok, :already_gone} ->
        {:ok, already_gone(event_id)}

      {:error, reason} ->
        {:error, Shared.translate_error(reason, "cancel the calendar block")}
    end
  end

  defp already_gone(event_id) do
    %{
      source: "google_calendar",
      event_id: event_id,
      cancelled: true,
      already_gone: true
    }
  end
end
