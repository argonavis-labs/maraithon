defmodule Maraithon.Delegations.EvaluationCalendar do
  @moduledoc "Read-only production check of the controlled user's actual scheduling sources."
  import Ecto.Query
  alias Maraithon.Delegations.{Evaluation, Preferences, Scheduling}
  alias Maraithon.LocalCalendar.{AvailabilitySnapshot, Mirror}
  alias Maraithon.Repo

  def run do
    user_id = Evaluation.scenarios()["owner"]["email"]
    prefs = Preferences.get(user_id)
    now = DateTime.utc_now()
    first = DateTime.add(now, 1, :day)
    last = DateTime.add(first, 7, :day)
    bindings = prefs["calendar_mirror_bindings"]

    devices =
      Repo.all(
        from d in Maraithon.Companion.Device,
          where: d.user_id == ^user_id and is_nil(d.revoked_at),
          order_by: [desc: d.last_seen_at, asc: d.id],
          limit: 10,
          select: map(d, [:id, :calendar_availability])
      )

    result =
      case Scheduling.propose_slots(user_id, %{window: {first, last}}) do
        {:ok, result} ->
          %{coverage: result["coverage"], slot_count: length(result["slots"])}

        {:error, reason} ->
          %{error: Maraithon.Redaction.error_class(reason)}
      end

    %{
      checked_at: now,
      calendar_account_ids: prefs["calendar_account_ids"],
      binding_count: map_size(bindings),
      bindings_valid: Mirror.valid_bindings?(user_id, bindings),
      selected_calendars: Enum.filter(Mirror.choices(user_id), &(&1.id in Map.values(bindings))),
      snapshots:
        Enum.map(devices, fn device ->
          snapshot = device.calendar_availability || %{}

          %{
            device_id: device.id,
            captured_at: snapshot["captured_at"],
            validation:
              case AvailabilitySnapshot.validate(snapshot, now) do
                :ok -> "fresh"
                {:error, reason} -> to_string(reason)
              end,
            calendar_count: length(snapshot["calendars"] || []),
            event_count: length(snapshot["events"] || [])
          }
        end),
      scheduling: result,
      messages_sent: 0,
      events_created: 0
    }
  end
end
