defmodule Maraithon.Tools.CalendarUpdateEvent do
  @moduledoc """
  Updates a Maraithon-managed time block on the user's primary Google
  Calendar (SPEC 12 R9), e.g. when a linked todo's due date moves.

  Runs only through the prepare -> confirm -> execute prepared-action
  pipeline. Before touching anything it fetches the event and verifies the
  SPEC 12 R8 ownership markers (`maraithon_managed == "true"` and, when a
  `todo_id` is supplied, a matching `maraithon_todo_id`) — Maraithon never
  edits a calendar event it did not create, even if the local
  `Todo.metadata` pointer is stale or was hand-edited (R11).

  A 404/410 (the user already deleted the event in Google Calendar) is
  reported as `calendar_event_already_gone`, which downstream copy turns
  into "already gone — propose a fresh block", never a crash.
  """

  alias Maraithon.Connectors.GoogleCalendar
  alias Maraithon.Tools.CalendarCreateEvent, as: Shared

  def execute(args) when is_map(args) do
    with {:ok, user_id} <- Shared.required_string(args, "user_id"),
         {:ok, event_id} <- Shared.required_string(args, "event_id"),
         :ok <- verify_ownership(user_id, event_id, Shared.optional_string(args, "todo_id")),
         {:ok, attrs} <- update_attrs(args),
         {:ok, event} <- GoogleCalendar.update_event(user_id, event_id, attrs) do
      {:ok, %{source: "google_calendar", event: Shared.event_payload(event)}}
    else
      {:error, reason} -> {:error, Shared.translate_error(reason, "update the calendar block")}
    end
  end

  @doc """
  R8 enforcement: GET the event and require `maraithon_managed == "true"`
  (and a matching `maraithon_todo_id` when acting for a specific todo and
  the stored marker names one).
  """
  def verify_ownership(user_id, event_id, todo_id) do
    case GoogleCalendar.get_event(user_id, event_id) do
      {:ok, event} ->
        private = Map.get(event, :private_properties) || %{}

        cond do
          Map.get(private, "maraithon_managed") != "true" ->
            {:error, :calendar_event_not_managed}

          todo_mismatch?(private, todo_id) ->
            {:error, :calendar_event_not_managed}

          true ->
            :ok
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp todo_mismatch?(private, todo_id) when is_binary(todo_id) do
    case Map.get(private, "maraithon_todo_id") do
      stored when is_binary(stored) and stored != "" -> stored != todo_id
      _ -> false
    end
  end

  defp todo_mismatch?(_private, _todo_id), do: false

  defp update_attrs(args) do
    attrs =
      %{}
      |> maybe_put(:summary, Shared.optional_string(args, "title"))
      |> maybe_put(:description, Shared.optional_string(args, "description"))

    case {Shared.optional_string(args, "start_at"), Shared.optional_string(args, "end_at")} do
      {nil, nil} ->
        if attrs == %{}, do: {:error, :empty_event_update}, else: {:ok, attrs}

      {_start, _end} ->
        with {:ok, start_at, end_at} <- Shared.required_window(args),
             {:ok, timezone} <- Shared.required_string(args, "timezone") do
          {:ok, Map.merge(attrs, %{start: start_at, end: end_at, timezone: timezone})}
        end
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
