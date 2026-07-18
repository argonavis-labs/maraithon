defmodule Maraithon.Crm.InteractionEvents do
  @moduledoc """
  Shared gathering of a user's interaction events across sources.

  `CommunicationScore` (per-person direct scoring) and `RelationshipGraph`
  (network-wide PageRank) both fold the same raw material — iMessage/WhatsApp
  messages, calendar attendance, Gmail/Slack/Telegram observations, and todo
  links — into per-person events. This module owns that gathering plus the
  handle-normalization helpers, so the two scorers can never drift apart on
  what counts as an interaction.

  Every event is `%{person_id:, at:, source:, direction:}` with direction in
  `"inbound" | "outbound" | "mutual"`.
  """

  import Ecto.Query

  alias Maraithon.Crm.{Observation, Person, PersonLink}
  alias Maraithon.LocalCalendar.LocalEvent
  alias Maraithon.LocalMessages.LocalMessage
  alias Maraithon.Repo

  @window_days 180
  @half_life_days 45
  @max_event_attendees 10

  def window_days, do: @window_days
  def half_life_days, do: @half_life_days
  def max_event_attendees, do: @max_event_attendees

  @doc """
  Gather everything the scorers need for a user in one pass.

  Returns `%{people:, self_people:, own_handles:, handle_index:, events:}`.
  People holding one of the user's own handles are split out as
  `self_people` (they are the user, not counterparties) and their handles
  extend `own_handles`.
  """
  def gather(user_id) when is_binary(user_id) do
    people = active_people(user_id)
    own_handles = Maraithon.UserIdentity.handle_set(user_id)

    {self_people, people} =
      Enum.split_with(people, fn person ->
        person |> person_handles() |> Enum.any?(&MapSet.member?(own_handles, &1))
      end)

    own_handles =
      self_people
      |> Enum.flat_map(&person_handles/1)
      |> Enum.into(own_handles)

    handle_index = handle_index(people)

    events =
      observation_events(user_id) ++
        message_events(user_id, handle_index, own_handles) ++
        calendar_events(user_id, handle_index, own_handles) ++
        todo_link_events(user_id)

    %{
      people: people,
      self_people: self_people,
      own_handles: own_handles,
      handle_index: handle_index,
      events: events
    }
  end

  @doc "Exponential recency decay shared by both scorers."
  def decay(%DateTime{} = at, %DateTime{} = now) do
    age_days = max(DateTime.diff(now, at, :day), 0)
    :math.exp(-age_days / @half_life_days)
  end

  # ---------------------------------------------------------------------------
  # Event gathering
  # ---------------------------------------------------------------------------

  defp active_people(user_id) do
    Person
    |> where([p], p.user_id == ^user_id and p.status == "active")
    |> Repo.all()
  end

  # Observations already carry resolved person ids and direction — the
  # highest-fidelity signal for Gmail/Slack/Telegram.
  defp observation_events(user_id) do
    cutoff = cutoff()

    Observation
    |> where([o], o.user_id == ^user_id and o.occurred_at > ^cutoff)
    |> where([o], o.resolved_person_ids != [])
    |> select([o], %{
      occurred_at: o.occurred_at,
      source: o.source,
      direction: o.direction,
      person_ids: o.resolved_person_ids
    })
    |> Repo.all()
    |> Enum.flat_map(fn row ->
      Enum.map(row.person_ids, fn person_id ->
        %{
          person_id: person_id,
          at: row.occurred_at,
          source: row.source || "gmail",
          direction: row.direction || "inbound"
        }
      end)
    end)
  end

  defp message_events(user_id, handle_index, own_handles) do
    cutoff = cutoff()

    LocalMessage
    |> where([m], m.user_id == ^user_id and m.sent_at > ^cutoff)
    |> select([m], %{
      sent_at: m.sent_at,
      source: m.source,
      sender_handle: m.sender_handle,
      chat_key: m.chat_key,
      is_from_me: m.is_from_me
    })
    |> Repo.all()
    |> Enum.flat_map(fn message ->
      handle =
        if message.is_from_me do
          # Outbound: attribute to the counterparty when the chat key is a
          # direct handle (group chats have synthetic keys and are skipped).
          message.chat_key
        else
          message.sender_handle
        end

      with normalized when is_binary(normalized) <- normalize_handle(handle),
           false <- MapSet.member?(own_handles, normalized),
           person_id when is_binary(person_id) <- Map.get(handle_index, normalized) do
        [
          %{
            person_id: person_id,
            at: message.sent_at,
            source: message.source || "imessage",
            direction: if(message.is_from_me, do: "outbound", else: "inbound")
          }
        ]
      else
        _ -> []
      end
    end)
  end

  defp calendar_events(user_id, handle_index, own_handles) do
    cutoff = cutoff()

    LocalEvent
    |> where([e], e.user_id == ^user_id and e.start_at > ^cutoff)
    |> where([e], e.is_all_day != true)
    |> select([e], %{
      start_at: e.start_at,
      organizer_email: e.organizer_email,
      attendee_emails: e.attendee_emails,
      attendees_count: e.attendees_count
    })
    |> Repo.all()
    |> Enum.flat_map(fn event ->
      # Huge events are broadcasts, not relationship touchpoints.
      if (event.attendees_count || 0) > @max_event_attendees do
        []
      else
        [event.organizer_email | List.wrap(event.attendee_emails)]
        |> Enum.map(&normalize_handle/1)
        |> Enum.reject(&is_nil/1)
        |> Enum.uniq()
        |> Enum.reject(&MapSet.member?(own_handles, &1))
        |> Enum.flat_map(fn handle ->
          case Map.get(handle_index, handle) do
            nil ->
              []

            person_id ->
              [
                %{
                  person_id: person_id,
                  at: event.start_at,
                  source: "calendar",
                  direction: "mutual"
                }
              ]
          end
        end)
      end
    end)
  end

  # A person showing up in the user's todos is a strong "this relationship
  # has open work" signal.
  defp todo_link_events(user_id) do
    cutoff = cutoff()

    PersonLink
    |> where([l], l.user_id == ^user_id and l.inserted_at > ^cutoff)
    |> where([l], l.resource_type == "todo")
    |> select([l], %{person_id: l.person_id, inserted_at: l.inserted_at})
    |> Repo.all()
    |> Enum.map(fn link ->
      %{person_id: link.person_id, at: link.inserted_at, source: "todo", direction: "mutual"}
    end)
  end

  # ---------------------------------------------------------------------------
  # Handle resolution
  # ---------------------------------------------------------------------------

  @doc "Map of normalized handle → person id for a list of people."
  def handle_index(people) when is_list(people) do
    Enum.reduce(people, %{}, fn person, index ->
      person
      |> person_handles()
      |> Enum.reduce(index, fn handle, acc -> Map.put_new(acc, handle, person.id) end)
    end)
  end

  @doc "All normalized handles (emails + phones) for a person."
  def person_handles(%Person{} = person) do
    details = person.contact_details || %{}

    emails = details |> Map.get("emails") |> List.wrap()
    phones = details |> Map.get("phones") |> List.wrap()

    (emails ++ phones)
    |> Enum.map(&normalize_handle/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  @doc """
  Normalize a raw handle to a comparable form: lower-cased extracted email,
  or the last 10 digits of a phone number.
  """
  def normalize_handle(value) when is_binary(value) do
    value = String.trim(value)

    cond do
      value == "" ->
        nil

      String.contains?(value, "@") ->
        case Regex.run(~r/[A-Z0-9._%+\-]+@[A-Z0-9.\-]+\.[A-Z]{2,}/i, value) do
          [email] -> String.downcase(email)
          _ -> nil
        end

      true ->
        digits = String.replace(value, ~r/[^0-9]/, "")

        cond do
          String.length(digits) >= 10 -> String.slice(digits, -10, 10)
          String.length(digits) >= 7 -> digits
          true -> nil
        end
    end
  end

  def normalize_handle(_value), do: nil

  def cutoff do
    DateTime.add(DateTime.utc_now(), -@window_days * 24 * 60 * 60, :second)
  end
end
