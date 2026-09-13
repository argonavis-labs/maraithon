defmodule Maraithon.PeopleNetwork.Calendar do
  @moduledoc "Fetches bounded upcoming Google events on the People worker, never on a UI request."
  import Ecto.Query
  alias Maraithon.Accounts.ConnectedAccount
  alias Maraithon.PeopleNetwork.{Aggregate, Identity, ReadRepo}

  def add_upcoming(user_id, now, aggregate) do
    providers =
      ReadRepo.all(
        from a in ConnectedAccount,
          where:
            a.user_id == ^user_id and (a.provider == "google" or like(a.provider, "google:%")),
          select: a.provider,
          limit: 10
      )

    deadline = System.monotonic_time(:millisecond) + 20_000

    Enum.reduce(providers, aggregate, fn provider, acc ->
      remaining = deadline - System.monotonic_time(:millisecond)

      result =
        if remaining > 0 do
          task =
            Task.async(fn ->
              Maraithon.Tools.GoogleCalendarHelpers.list_events(user_id,
                provider: provider,
                time_min: DateTime.to_iso8601(now),
                time_max: DateTime.to_iso8601(DateTime.add(now, 21, :day)),
                max_results: 100
              )
            end)

          case Task.yield(task, remaining) || Task.shutdown(task, :brutal_kill) do
            {:ok, result} -> result
            _ -> {:error, :calendar_timeout}
          end
        else
          {:error, :calendar_timeout}
        end

      case result do
        {:ok, events} ->
          Enum.reduce(events, acc, fn event, current ->
            Aggregate.add(event(event, now), current)
          end)

        {:error, _} ->
          %{acc | warnings: Enum.uniq(["calendar_unavailable" | acc.warnings])}
      end
    end)
  end

  defp event(%{start: %DateTime{} = start} = event, now) do
    attendees = Enum.reject(event.attendees || [], &(&1.response_status == "declined"))
    declined = Enum.any?(event.attendees || [], &(&1.self and &1.response_status == "declined"))

    if event.status != "cancelled" and not declined and DateTime.compare(start, now) == :gt do
      participants =
        Enum.map(attendees, fn person ->
          %{handle: Identity.normalize(person.email), name: person.display_name, role: "attendee"}
        end)

      participants = [
        %{handle: Identity.normalize(event.organizer), name: nil, role: "organizer"}
        | participants
      ]

      key = "google_calendar:#{event.google_provider}:#{event.event_id}"

      %{
        key: key,
        at: start,
        source: "calendar",
        kind: "upcoming",
        from_user: false,
        participants: participants,
        context: key,
        evidence: %{
          id: key,
          type: "calendar",
          title: event.summary,
          at: DateTime.to_iso8601(start),
          source: "calendar"
        }
      }
    end
  end

  defp event(_event, _now), do: nil
end
