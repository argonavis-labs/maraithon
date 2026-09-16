defmodule Maraithon.LocalCalendar.Availability do
  @moduledoc "One replaceable availability window per authenticated companion. No history or model work."
  import Ecto.Query
  alias Maraithon.Companion.Device
  alias Maraithon.LocalCalendar.AvailabilitySnapshot
  alias Maraithon.PrivacyErasure.WriteFence
  alias Maraithon.Repo

  def ingest(%Device{} = device, snapshot) do
    with :ok <- AvailabilitySnapshot.validate(snapshot, DateTime.utc_now()) do
      Repo.transaction(fn ->
        WriteFence.lock_user_writable!(device.user_id)

        current =
          Repo.one(
            from d in Device,
              where: d.id == ^device.id and d.user_id == ^device.user_id,
              select: {d.token_hash, d.revoked_at, d.calendar_availability},
              lock: "FOR UPDATE"
          )

        case current do
          {hash, nil, ^snapshot} when hash == device.token_hash ->
            :duplicate

          {hash, nil, prior} when hash == device.token_hash ->
            {:ok, captured} = AvailabilitySnapshot.timestamp(snapshot["captured_at"])

            case AvailabilitySnapshot.timestamp(prior["captured_at"]) do
              {:ok, previous} ->
                if DateTime.compare(captured, previous) != :gt,
                  do: Repo.rollback(:stale_calendar_availability)

              :error ->
                :ok
            end

            Repo.update_all(from(d in Device, where: d.id == ^device.id),
              set: [calendar_availability: snapshot]
            )

            :ok

          _ ->
            Repo.rollback(:device_revoked)
        end
      end)
    end
  end

  def clear(user_id, device_id) do
    Repo.update_all(
      from(d in Device, where: d.user_id == ^user_id and d.device_id == ^device_id),
      set: [calendar_availability: %{}]
    )
  end
end
