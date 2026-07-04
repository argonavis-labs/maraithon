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

  Event gathering is shared with `Maraithon.Crm.RelationshipGraph` via
  `Maraithon.Crm.InteractionEvents`. The arithmetic here is deliberately
  deterministic and inspectable; semantic judgment about relationships stays
  with RelationshipIntelligence.
  """

  alias Maraithon.Crm.InteractionEvents
  alias Maraithon.Repo

  require Logger

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

  def source_weights, do: @source_weights
  def default_source_weight, do: @default_source_weight
  def outbound_multiplier, do: @outbound_multiplier

  @doc """
  Recomputes communication scores for every active person of a user.

  Returns `{:ok, %{people: n, scored: n}}`.
  """
  def refresh_for_user(user_id) when is_binary(user_id) do
    %{people: people, self_people: self_people, events: events} =
      InteractionEvents.gather(user_id)

    events_by_person = Enum.group_by(events, & &1.person_id)
    now = DateTime.utc_now()

    # A person record holding one of the user's own handles is the user;
    # their own traffic must not rank them in their own CRM.
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
  # Scoring
  # ---------------------------------------------------------------------------

  defp score_person([], _now), do: %{score: 0, signals: nil}

  defp score_person(events, now) do
    raw =
      Enum.reduce(events, 0.0, fn event, acc ->
        decay = InteractionEvents.decay(event.at, now)
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
end
