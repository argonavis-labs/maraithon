defmodule Maraithon.Crm.UpcomingMeetings do
  @moduledoc """
  People the user is about to meet, resolved from the calendar mirror.

  "Who am I meeting in the next few weeks and what do I owe them?" is the
  highest-leverage moment for relationship intelligence: there is a concrete
  time, a concrete reason, and usually open context worth prepping. This
  module resolves upcoming small-meeting attendees to CRM people so the
  reconnect surface, briefings, and enrichment can lead with them.
  """

  import Ecto.Query

  alias Maraithon.Crm.{InteractionEvents, Person}
  alias Maraithon.LocalCalendar.LocalEvent
  alias Maraithon.Repo

  @default_days 21
  @max_days 60
  @default_limit 50

  @doc """
  People with a meeting in the next `days` (default #{@default_days}).

  Returns entries sorted by soonest meeting:
  `%{person:, next_meeting_at:, next_meeting_title:, meeting_count:}`.
  """
  def people_meeting_soon(user_id, opts \\ [])

  def people_meeting_soon(user_id, opts) when is_binary(user_id) do
    days = opts |> Keyword.get(:days, @default_days) |> clamp(1, @max_days)
    limit = opts |> Keyword.get(:limit, @default_limit) |> clamp(1, 200)
    now = Keyword.get(opts, :now, DateTime.utc_now())
    horizon = DateTime.add(now, days * 24 * 60 * 60, :second)

    people = active_people(user_id)
    own_handles = own_handles(user_id, people)
    handle_index = InteractionEvents.handle_index(people)
    people_by_id = Map.new(people, &{&1.id, &1})

    user_id
    |> upcoming_events(now, horizon)
    |> Enum.flat_map(fn event ->
      ([event.organizer_email | List.wrap(event.attendee_emails)])
      |> Enum.map(&InteractionEvents.normalize_handle/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
      |> Enum.reject(&MapSet.member?(own_handles, &1))
      |> Enum.map(&Map.get(handle_index, &1))
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
      |> Enum.map(fn person_id ->
        %{person_id: person_id, at: event.start_at, title: event.title}
      end)
    end)
    |> Enum.group_by(& &1.person_id)
    |> Enum.flat_map(fn {person_id, meetings} ->
      case Map.get(people_by_id, person_id) do
        nil ->
          []

        person ->
          soonest = Enum.min_by(meetings, & &1.at, DateTime)

          [
            %{
              person: person,
              next_meeting_at: soonest.at,
              next_meeting_title: normalize_title(soonest.title),
              meeting_count: length(meetings)
            }
          ]
      end
    end)
    |> Enum.sort_by(& &1.next_meeting_at, DateTime)
    |> Enum.take(limit)
  end

  def people_meeting_soon(_user_id, _opts), do: []

  @doc "Same lane indexed by person id, for joining into other surfaces."
  def by_person_id(user_id, opts \\ []) do
    user_id
    |> people_meeting_soon(opts)
    |> Map.new(&{&1.person.id, &1})
  end

  defp upcoming_events(user_id, now, horizon) do
    max_attendees = InteractionEvents.max_event_attendees()

    LocalEvent
    |> where([e], e.user_id == ^user_id)
    |> where([e], e.start_at >= ^now and e.start_at <= ^horizon)
    |> where([e], e.is_all_day != true)
    |> select([e], %{
      start_at: e.start_at,
      title: e.title,
      organizer_email: e.organizer_email,
      attendee_emails: e.attendee_emails,
      attendees_count: e.attendees_count
    })
    |> Repo.all()
    |> Enum.reject(fn event -> (event.attendees_count || 0) > max_attendees end)
  end

  defp active_people(user_id) do
    Person
    |> where([p], p.user_id == ^user_id and p.status == "active")
    |> Repo.all()
  end

  # The user attends their own meetings; their handles (and any person
  # record that is really the user) must not produce meet-soon entries.
  defp own_handles(user_id, people) do
    base = Maraithon.UserIdentity.handle_set(user_id)

    people
    |> Enum.filter(fn person ->
      person |> InteractionEvents.person_handles() |> Enum.any?(&MapSet.member?(base, &1))
    end)
    |> Enum.flat_map(&InteractionEvents.person_handles/1)
    |> Enum.into(base)
  end

  defp normalize_title(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_title(_value), do: nil

  defp clamp(value, min_value, max_value) when is_integer(value),
    do: value |> max(min_value) |> min(max_value)

  defp clamp(_value, min_value, _max_value), do: min_value
end
