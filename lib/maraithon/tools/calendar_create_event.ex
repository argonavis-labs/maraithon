defmodule Maraithon.Tools.CalendarCreateEvent do
  @moduledoc """
  Creates a Maraithon-managed time block on the user's primary Google
  Calendar (SPEC 12).

  This tool is only ever executed through the prepare -> confirm -> execute
  prepared-action pipeline (`prepare_external_action` with
  `action_type: "calendar_create_event"`) — the runner injects the
  deterministic `client_event_id` derived from the prepared action (R7) and
  performs the fresh double-booking recheck (R10) before dispatching here.

  Every created event carries the R8 ownership markers in
  `extendedProperties.private` (`maraithon_managed` / `maraithon_todo_id` /
  `maraithon_client_key`) so later update/cancel actions can prove the event
  is Maraithon's own before touching it.
  """

  alias Maraithon.Connectors.GoogleCalendar
  alias Maraithon.Tools.ToolErrorCopy

  def execute(args) when is_map(args) do
    with {:ok, user_id} <- required_string(args, "user_id"),
         {:ok, title} <- required_string(args, "title"),
         {:ok, start_at, end_at} <- required_window(args),
         {:ok, timezone} <- required_string(args, "timezone"),
         {:ok, client_event_id} <- required_string(args, "client_event_id"),
         {:ok, event} <-
           GoogleCalendar.create_event(user_id, %{
             client_event_id: client_event_id,
             summary: title,
             description: optional_string(args, "description"),
             start: start_at,
             end: end_at,
             timezone: timezone,
             extended_private_properties: %{
               "maraithon_managed" => "true",
               "maraithon_todo_id" => optional_string(args, "todo_id") || "",
               "maraithon_client_key" => client_event_id
             }
           }) do
      {:ok, %{source: "google_calendar", event: event_payload(event)}}
    else
      {:error, reason} -> {:error, translate_error(reason, "create the calendar block")}
    end
  end

  @doc false
  def translate_error(reason, action) do
    case reason do
      :calendar_write_scope_required ->
        "calendar_write_scope_required"

      :no_token ->
        "google_account_not_connected"

      :no_refresh_token ->
        "google_account_reauth_required"

      :reauth_required ->
        "google_account_reauth_required"

      :unauthorized ->
        "google_account_reauth_required"

      :event_gone ->
        "calendar_event_already_gone"

      :calendar_event_id_conflict ->
        "calendar_event_id_conflict"

      {:missing_arg, key} ->
        "#{key} is required"

      :invalid_event_time ->
        "start_at and end_at must be ISO-8601 datetimes"

      :invalid_event_window ->
        "end_at must be after start_at"

      :missing_timezone ->
        "timezone is required"

      :invalid_client_event_id ->
        "client_event_id is invalid"

      :missing_client_event_id ->
        "client_event_id is required"

      :empty_event_update ->
        "no calendar event changes were provided"

      other ->
        ToolErrorCopy.safe_message(
          normalize_reason(other),
          ToolErrorCopy.action_failed("Google Calendar", action)
        )
    end
  end

  @doc false
  def event_payload(event) when is_map(event) do
    %{
      event_id: Map.get(event, :event_id),
      summary: Map.get(event, :summary),
      start: Map.get(event, :start),
      end: Map.get(event, :end),
      status: Map.get(event, :status),
      html_link: Map.get(event, :html_link)
    }
  end

  @doc false
  def required_string(args, key) do
    case Map.get(args, key) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> {:error, {:missing_arg, key}}
          trimmed -> {:ok, trimmed}
        end

      _ ->
        {:error, {:missing_arg, key}}
    end
  end

  @doc false
  def optional_string(args, key) do
    case required_string(args, key) do
      {:ok, value} -> value
      _ -> nil
    end
  end

  @doc false
  def required_window(args) do
    with {:ok, start_raw} <- required_string(args, "start_at"),
         {:ok, end_raw} <- required_string(args, "end_at"),
         {:ok, start_at, _} <- parse_datetime(start_raw),
         {:ok, end_at, _} <- parse_datetime(end_raw) do
      if DateTime.compare(start_at, end_at) == :lt do
        {:ok, start_at, end_at}
      else
        {:error, :invalid_event_window}
      end
    else
      {:error, {:missing_arg, _key} = reason} -> {:error, reason}
      _ -> {:error, :invalid_event_time}
    end
  end

  defp parse_datetime(value), do: DateTime.from_iso8601(value)

  defp normalize_reason(reason) when is_binary(reason), do: reason
  defp normalize_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp normalize_reason(reason), do: inspect(reason)
end
