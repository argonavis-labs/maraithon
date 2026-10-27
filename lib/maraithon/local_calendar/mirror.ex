defmodule Maraithon.LocalCalendar.Mirror do
  @moduledoc "Explicit user-owned calendar bindings; fresh complete windows for slot proposals only."
  import Ecto.Query
  alias Maraithon.Companion.Device
  alias Maraithon.Delegations.Preferences
  alias Maraithon.LocalCalendar.AvailabilitySnapshot
  alias Maraithon.Repo
  alias Maraithon.TelegramAssistant.PreparedAction

  def choices(user_id), do: Enum.map(choice_rows(user_id), &Map.take(&1, [:id, :label]))

  defp choice_rows(user_id) do
    Enum.flat_map(devices(user_id), fn device ->
      Enum.map(device.calendar_availability["calendars"] || [], fn calendar ->
        %{
          id: choice_id(device, calendar),
          device_id: device.id,
          label:
            "#{calendar["name"]} · #{calendar["source_name"]} · #{device.device_name || "Mac"}"
        }
      end)
    end)
  end

  def valid_bindings?(user_id, bindings) when is_map(bindings) and map_size(bindings) <= 10 do
    accounts = MapSet.new(Preferences.calendar_accounts(user_id), &to_string(&1.id))
    rows = choice_rows(user_id)
    available = MapSet.new(rows, & &1.id)
    selected = Map.values(bindings)
    devices = rows |> Enum.filter(&(&1.id in selected)) |> Enum.map(& &1.device_id) |> Enum.uniq()

    Enum.all?(bindings, fn {account, choice} ->
      MapSet.member?(accounts, account) and MapSet.member?(available, choice)
    end) and length(Enum.uniq(selected)) == map_size(bindings) and length(devices) <= 1
  end

  def valid_bindings?(_, _), do: false

  def read(user_id, ids, first, last, prefs) do
    bindings = prefs["calendar_mirror_bindings"] || %{}
    selected = Enum.map(ids, &bindings[to_string(&1)])

    if nil in selected or selected == [] do
      :unavailable
    else
      Enum.find_value(devices(user_id), :unavailable, fn device ->
        snapshot = device.calendar_availability
        calendars = snapshot["calendars"] || []
        chosen = Enum.filter(calendars, &(choice_id(device, &1) in selected))

        with true <- length(chosen) == length(selected),
             :ok <- AvailabilitySnapshot.validate(snapshot, DateTime.utc_now()),
             {:ok, from} <- AvailabilitySnapshot.timestamp(snapshot["from"]),
             {:ok, until} <- AvailabilitySnapshot.timestamp(snapshot["until"]),
             true <-
               DateTime.compare(from, first) != :gt and DateTime.compare(until, last) != :lt,
             {:ok, captured} <- AvailabilitySnapshot.timestamp(snapshot["captured_at"]),
             false <- calendar_write_since?(user_id, captured) do
          calendars = MapSet.new(chosen, &{&1["id"], &1["source_id"]})

          events =
            snapshot["events"]
            |> Enum.filter(fn event ->
              state = event["source_state"]
              MapSet.member?(calendars, {state["calendar_id"], state["source_id"]})
            end)
            |> Enum.map(&event/1)

          {:ok, events,
           %{
             "source" => "companion",
             "captured_at" => snapshot["captured_at"],
             "snapshot_from" => snapshot["from"],
             "snapshot_until" => snapshot["until"],
             "calendar_bindings" => Map.take(bindings, Enum.map(ids, &to_string/1))
           }}
        else
          _ -> nil
        end
      end)
    end
  end

  defp devices(user_id) do
    Repo.all(
      from d in Device,
        where: d.user_id == ^user_id and is_nil(d.revoked_at),
        order_by: [desc: d.last_seen_at, asc: d.id],
        limit: 10,
        select: map(d, [:id, :device_name, :calendar_availability])
    )
  end

  defp choice_id(device, calendar),
    do:
      :crypto.hash(:sha256, Jason.encode!([device.id, calendar["source_id"], calendar["id"]]))
      |> Base.encode16(case: :lower)

  # Do not offer slots from a snapshot predating an app write or while a write
  # is unresolved. Booking itself always rechecks Google, even with a mirror.
  defp calendar_write_since?(user_id, captured) do
    Repo.exists?(
      from a in PreparedAction,
        where: a.user_id == ^user_id,
        where:
          a.action_type in ~w(calendar_create_event calendar_update_event calendar_cancel_event),
        where: a.status in ~w(confirmed execution_unknown) or a.updated_at >= ^captured
    )
  end

  defp event(row) do
    state = row["source_state"]

    %{
      event_id: row["guid"],
      # EventKit identifies copies and recurring masters with this server ID.
      # Keep its namespace separate from Google's iCal UID; dates distinguish occurrences.
      occurrence_key:
        if(state["external_id"] not in [nil, ""], do: {:eventkit, state["external_id"]}),
      status: state["event_status"],
      transparency: if(state["availability"] == "free", do: "transparent", else: "opaque"),
      attendees: [%{self: true, response_status: state["self_response"]}],
      start: if(row["is_all_day"], do: %{date: row["start_date"]}, else: row["start_at"]),
      end: if(row["is_all_day"], do: %{date: row["end_date"]}, else: row["end_at"])
    }
  end
end
