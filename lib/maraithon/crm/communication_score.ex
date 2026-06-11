defmodule Maraithon.Crm.CommunicationScore do
  @moduledoc """
  Ranks CRM people by real communication activity.

  The CRM's job is keeping the user in touch with people who matter. This
  module folds actual communications — iMessage/WhatsApp threads, meetings
  attended together, Gmail/Slack observations, and todos linked to a person
  — into a 0-100 `communication_score` with recency decay, so active
  relationships rise and one-way noise (newsletters, notification senders)
  sinks. It also learns each person's usual contact cadence and flags
  important relationships that have drifted past it ("keep in touch").

  The arithmetic is deliberately deterministic and inspectable; semantic
  judgment about relationships stays with RelationshipIntelligence.
  """

  import Ecto.Query

  alias Maraithon.Crm.{Observation, Person, PersonLink}
  alias Maraithon.LocalCalendar.LocalEvent
  alias Maraithon.LocalMessages.LocalMessage
  alias Maraithon.Repo

  require Logger

  @window_days 180
  @half_life_days 45
  @max_event_attendees 10

  @source_weights %{
    "imessage" => 3.0,
    "whatsapp" => 3.0,
    "messages" => 3.0,
    "calendar" => 4.0,
    "gmail" => 1.2,
    "slack" => 1.5,
    "telegram" => 1.5,
    "todo" => 5.0
  }
  @default_source_weight 1.0
  @outbound_multiplier 1.5
  @reciprocity_multiplier 1.3
  # Inbound-only senders with volume are broadcasts, not relationships.
  @one_way_inbound_multiplier 0.25
  @one_way_inbound_threshold 4

  @doc """
  Recomputes communication scores for every active person of a user.

  Returns `{:ok, %{people: n, scored: n}}`.
  """
  def refresh_for_user(user_id) when is_binary(user_id) do
    people = active_people(user_id)
    own_handles = own_handles(user_id)

    # A person record holding one of the user's own handles is the user;
    # their own traffic must not rank them in their own CRM. Their handles
    # also extend the own-handle set (personal phone, personal email).
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

    events_by_person = Enum.group_by(events, & &1.person_id)
    now = DateTime.utc_now()

    Enum.each(self_people, fn person ->
      persist(person, %{score: 0, signals: nil}, now)
    end)

    scored =
      people
      |> Enum.map(fn person ->
        person_events = Map.get(events_by_person, person.id, [])
        {person, score_person(person_events, now)}
      end)
      |> Enum.reduce(0, fn {person, result}, count ->
        case persist(person, result, now) do
          :ok -> count + 1
          :skip -> count
        end
      end)

    {:ok, %{people: length(people), scored: scored}}
  end

  def refresh_for_user(_user_id), do: {:error, :invalid_user}

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
        ([event.organizer_email | List.wrap(event.attendee_emails)])
        |> Enum.map(&normalize_handle/1)
        |> Enum.reject(&is_nil/1)
        |> Enum.uniq()
        |> Enum.reject(&MapSet.member?(own_handles, &1))
        |> Enum.flat_map(fn handle ->
          case Map.get(handle_index, handle) do
            nil ->
              []

            person_id ->
              [%{person_id: person_id, at: event.start_at, source: "calendar", direction: "mutual"}]
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
  # Scoring
  # ---------------------------------------------------------------------------

  defp score_person([], _now), do: %{score: 0, signals: nil}

  defp score_person(events, now) do
    raw =
      Enum.reduce(events, 0.0, fn event, acc ->
        age_days = max(DateTime.diff(now, event.at, :day), 0)
        decay = :math.exp(-age_days / @half_life_days)
        weight = Map.get(@source_weights, event.source, @default_source_weight)
        direction = if event.direction == "outbound", do: @outbound_multiplier, else: 1.0

        acc + weight * direction * decay
      end)

    inbound = Enum.count(events, &(&1.direction == "inbound"))
    outbound = Enum.count(events, &(&1.direction == "outbound"))
    mutual = Enum.count(events, &(&1.direction == "mutual"))

    raw =
      cond do
        outbound > 0 and inbound > 0 ->
          raw * @reciprocity_multiplier

        outbound == 0 and mutual == 0 and inbound >= @one_way_inbound_threshold ->
          raw * @one_way_inbound_multiplier

        true ->
          raw
      end

    score = round(100 * raw / (raw + 30))
    last_at = events |> Enum.map(& &1.at) |> Enum.max(DateTime)
    cadence = cadence_days(events)
    days_since = max(DateTime.diff(now, last_at, :day), 0)

    overdue =
      score >= 40 and is_number(cadence) and
        days_since > max(7, round(cadence * 1.5))

    %{
      score: min(score, 100),
      signals: %{
        "score" => min(score, 100),
        "events" => length(events),
        "inbound" => inbound,
        "outbound" => outbound,
        "mutual" => mutual,
        "channels" => events |> Enum.frequencies_by(& &1.source),
        "last_event_at" => DateTime.to_iso8601(last_at),
        "days_since_last" => days_since,
        "cadence_days" => cadence,
        "overdue" => overdue,
        "computed_at" => DateTime.to_iso8601(now)
      }
    }
  end

  # Median gap between interactions, in days — the person's natural rhythm.
  defp cadence_days(events) when length(events) < 3, do: nil

  defp cadence_days(events) do
    gaps =
      events
      |> Enum.map(& &1.at)
      |> Enum.sort(DateTime)
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.map(fn [a, b] -> DateTime.diff(b, a, :day) end)
      |> Enum.reject(&(&1 == 0))
      |> Enum.sort()

    case gaps do
      [] -> nil
      gaps -> Enum.at(gaps, div(length(gaps), 2))
    end
  end

  # ---------------------------------------------------------------------------
  # Persistence
  # ---------------------------------------------------------------------------

  defp persist(person, %{score: score, signals: signals}, _now) do
    existing_signals = get_in(person.metadata || %{}, ["communication_signals"])

    if person.communication_score == score and signals == nil and existing_signals == nil do
      :skip
    else
      metadata =
        case signals do
          nil -> Map.delete(person.metadata || %{}, "communication_signals")
          signals -> Map.put(person.metadata || %{}, "communication_signals", signals)
        end

      person
      |> Ecto.Changeset.change(communication_score: score, metadata: metadata)
      |> Repo.update()
      |> case do
        {:ok, _person} ->
          :ok

        {:error, changeset} ->
          Logger.warning("Communication score update failed",
            person_id: person.id,
            reason: inspect(changeset.errors)
          )

          :skip
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Handle resolution
  # ---------------------------------------------------------------------------

  defp handle_index(people) do
    Enum.reduce(people, %{}, fn person, index ->
      person
      |> person_handles()
      |> Enum.reduce(index, fn handle, acc -> Map.put_new(acc, handle, person.id) end)
    end)
  end

  defp person_handles(person) do
    details = person.contact_details || %{}

    emails = details |> Map.get("emails") |> List.wrap()
    phones = details |> Map.get("phones") |> List.wrap()

    (emails ++ phones)
    |> Enum.map(&normalize_handle/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  # The user's own addresses must never count as a counterparty.
  defp own_handles(user_id) do
    oauth_emails =
      try do
        user_id
        |> Maraithon.OAuth.list_user_tokens()
        |> Enum.flat_map(fn token ->
          [
            provider_email(token.provider),
            get_in(token.metadata || %{}, ["email"]),
            get_in(token.metadata || %{}, ["account_email"]),
            get_in(token.metadata || %{}, ["google_account_email"])
          ]
        end)
      rescue
        _ -> []
      end

    [user_id | oauth_emails]
    |> Enum.map(&normalize_handle/1)
    |> Enum.reject(&is_nil/1)
    |> MapSet.new()
  end

  defp provider_email("google:" <> email), do: email
  defp provider_email(_provider), do: nil

  defp normalize_handle(value) when is_binary(value) do
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

  defp normalize_handle(_value), do: nil

  defp cutoff do
    DateTime.add(DateTime.utc_now(), -@window_days * 24 * 60 * 60, :second)
  end
end
