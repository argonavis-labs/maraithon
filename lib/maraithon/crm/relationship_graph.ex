defmodule Maraithon.Crm.RelationshipGraph do
  @moduledoc """
  Personalized PageRank over the user's relationship graph.

  `CommunicationScore` measures how much the user talks to each person
  directly. This module adds the network view: people are nodes, shared
  meetings / email threads / group chats are edges, and importance flows
  along those edges from the people the user actually interacts with. The
  person who quietly sits at the center of the meetings and threads that
  matter outranks a high-volume broadcast sender — that distinction is
  impossible with per-person arithmetic alone.

  The walk is personalized and rooted at the user: the user is a node,
  direct interactions are user↔person edges (decayed mass from
  `InteractionEvents`), and the walk teleports back to the user. Mass
  therefore recirculates through the user instead of draining out of the
  people they talk to most — a heavily-contacted friend stays above the
  colleague they share one thread with, while genuine hubs still collect
  lift from every path that flows through them. Ranks evolve every time
  new interactions land.

  Output per person:
    * `crm_people.network_rank` — 0–100 percentile of PageRank mass.
    * `metadata["graph_signals"]` — raw mass, direct vs network share, and
      the person's strongest connections, for explainability.
  """

  import Ecto.Query

  alias Maraithon.Crm.{CommunicationScore, InteractionEvents, Observation}
  alias Maraithon.LocalCalendar.LocalEvent
  alias Maraithon.LocalMessages.LocalMessage
  alias Maraithon.Repo

  require Logger

  @damping 0.85
  @max_iterations 30
  @epsilon 1.0e-8
  @top_connections 5

  @co_attendance_weight 2.0
  @co_participant_weight 1.0
  @group_chat_weight 1.0
  # Direct-handle chats have the counterparty handle as chat_key; group chats
  # get synthetic keys. A chat only counts as a person↔person edge source
  # when at least two distinct non-self people sent messages in it.
  @max_group_members 10

  @doc """
  Recompute `network_rank` + `graph_signals` for every active person.

  Returns `{:ok, %{people: n, ranked: n}}`.
  """
  def refresh_for_user(user_id) when is_binary(user_id) do
    %{
      people: people,
      self_people: self_people,
      own_handles: own_handles,
      handle_index: handle_index,
      events: events
    } = InteractionEvents.gather(user_id)

    now = DateTime.utc_now()
    direct = direct_mass(events, now)
    person_edges = person_edges(user_id, handle_index, own_handles, now)

    # The user is the root node: direct interactions become user↔person
    # edges and the walk teleports back to the user.
    user_edges = Map.new(direct, fn {person_id, mass} -> {{:user, person_id}, mass} end)
    edges = merge_edges(person_edges, user_edges)

    ranks = edges |> then(&pagerank(%{user: 1.0}, &1)) |> Map.delete(:user)

    names = Map.new(people, &{&1.id, &1.display_name})
    percentiles = percentiles(ranks)
    total_mass = ranks |> Map.values() |> Enum.sum()
    total_direct = direct |> Map.values() |> Enum.sum()

    Enum.each(self_people, fn person -> persist(person, 0, nil) end)

    ranked =
      Enum.reduce(people, 0, fn person, count ->
        mass = Map.get(ranks, person.id, 0.0)
        rank = Map.get(percentiles, person.id, 0)

        signals =
          if mass > 0.0 do
            mass_share = if total_mass > 0.0, do: mass / total_mass, else: 0.0

            direct_share =
              if total_direct > 0.0,
                do: Map.get(direct, person.id, 0.0) / total_direct,
                else: 0.0

            %{
              "rank" => rank,
              "mass" => Float.round(mass, 6),
              "direct_share" => Float.round(direct_share, 6),
              "network_lift" => Float.round(mass_share - direct_share, 6),
              "top_connections" => top_connections(person.id, person_edges, names),
              "computed_at" => DateTime.to_iso8601(now)
            }
          end

        case persist(person, rank, signals) do
          :ok -> count + 1
          :skip -> count
        end
      end)

    {:ok, %{people: length(people), ranked: ranked}}
  end

  def refresh_for_user(_user_id), do: {:error, :invalid_user}

  @doc """
  Personalized PageRank. `teleport` is `%{node => mass}` (unnormalized);
  `edges` is `%{{a, b} => weight}` with unordered `{a, b}` pairs (a < b).
  Returns `%{node => probability_mass}` — empty map when there is nothing
  to walk. Pure; exposed for tests.
  """
  def pagerank(teleport, edges) do
    total = teleport |> Map.values() |> Enum.sum()

    if total <= 0.0 do
      %{}
    else
      teleport = Map.new(teleport, fn {node, mass} -> {node, mass / total} end)

      neighbors =
        Enum.reduce(edges, %{}, fn {{a, b}, weight}, acc ->
          acc
          |> Map.update(a, [{b, weight}], &[{b, weight} | &1])
          |> Map.update(b, [{a, weight}], &[{a, weight} | &1])
        end)

      out_weight =
        Map.new(neighbors, fn {node, links} ->
          {node, links |> Enum.map(&elem(&1, 1)) |> Enum.sum()}
        end)

      nodes =
        teleport
        |> Map.keys()
        |> MapSet.new()
        |> MapSet.union(MapSet.new(Map.keys(neighbors)))

      initial = Map.new(nodes, fn node -> {node, Map.get(teleport, node, 0.0)} end)

      iterate(initial, teleport, neighbors, out_weight, nodes, @max_iterations)
    end
  end

  defp iterate(ranks, _teleport, _neighbors, _out_weight, _nodes, 0), do: ranks

  defp iterate(ranks, teleport, neighbors, out_weight, nodes, remaining) do
    # Mass at nodes with no outgoing edges returns through the teleport
    # vector, keeping the distribution stochastic.
    dangling =
      Enum.reduce(ranks, 0.0, fn {node, mass}, acc ->
        if Map.get(out_weight, node, 0.0) > 0.0, do: acc, else: acc + mass
      end)

    flowed =
      Enum.reduce(ranks, %{}, fn {node, mass}, acc ->
        out = Map.get(out_weight, node, 0.0)

        if out > 0.0 do
          neighbors
          |> Map.get(node, [])
          |> Enum.reduce(acc, fn {target, weight}, inner ->
            Map.update(inner, target, mass * weight / out, &(&1 + mass * weight / out))
          end)
        else
          acc
        end
      end)

    next =
      Map.new(nodes, fn node ->
        base = Map.get(teleport, node, 0.0)
        inbound = Map.get(flowed, node, 0.0)
        {node, (1.0 - @damping) * base + @damping * (inbound + dangling * base)}
      end)

    delta =
      Enum.reduce(next, 0.0, fn {node, mass}, acc ->
        acc + abs(mass - Map.get(ranks, node, 0.0))
      end)

    if delta < @epsilon do
      next
    else
      iterate(next, teleport, neighbors, out_weight, nodes, remaining - 1)
    end
  end

  # ---------------------------------------------------------------------------
  # Teleport vector: decayed direct-interaction mass, using the same source
  # weights and direction multipliers as CommunicationScore so both views of
  # a relationship agree on what an interaction is worth.
  # ---------------------------------------------------------------------------

  defp direct_mass(events, now) do
    weights = CommunicationScore.source_weights()
    default = CommunicationScore.default_source_weight()
    outbound = CommunicationScore.outbound_multiplier()

    Enum.reduce(events, %{}, fn event, acc ->
      decay = InteractionEvents.decay(event.at, now)
      weight = Map.get(weights, event.source, default)
      direction = if event.direction == "outbound", do: outbound, else: 1.0
      mass = weight * direction * decay

      Map.update(acc, event.person_id, mass, &(&1 + mass))
    end)
  end

  # ---------------------------------------------------------------------------
  # Person ↔ person edges
  # ---------------------------------------------------------------------------

  defp person_edges(user_id, handle_index, own_handles, now) do
    %{}
    |> merge_edges(co_attendance_edges(user_id, handle_index, own_handles, now))
    |> merge_edges(observation_edges(user_id, now))
    |> merge_edges(group_chat_edges(user_id, handle_index, own_handles, now))
  end

  defp merge_edges(acc, edges) do
    Enum.reduce(edges, acc, fn {pair, weight}, inner ->
      Map.update(inner, pair, weight, &(&1 + weight))
    end)
  end

  defp co_attendance_edges(user_id, handle_index, own_handles, now) do
    cutoff = InteractionEvents.cutoff()
    max_attendees = InteractionEvents.max_event_attendees()

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
      if (event.attendees_count || 0) > max_attendees do
        []
      else
        person_ids =
          ([event.organizer_email | List.wrap(event.attendee_emails)])
          |> resolve_person_ids(handle_index, own_handles)

        pair_edges(person_ids, @co_attendance_weight * InteractionEvents.decay(event.start_at, now))
      end
    end)
  end

  defp observation_edges(user_id, now) do
    cutoff = InteractionEvents.cutoff()

    Observation
    |> where([o], o.user_id == ^user_id and o.occurred_at > ^cutoff)
    |> where([o], fragment("array_length(?, 1) >= 2", o.resolved_person_ids))
    |> select([o], %{occurred_at: o.occurred_at, person_ids: o.resolved_person_ids})
    |> Repo.all()
    |> Enum.flat_map(fn row ->
      pair_edges(
        Enum.uniq(row.person_ids),
        @co_participant_weight * InteractionEvents.decay(row.occurred_at, now)
      )
    end)
  end

  # The message mirror stores senders, not full group membership, so the
  # honest signal is "these people sent messages in the same group chat."
  defp group_chat_edges(user_id, handle_index, own_handles, now) do
    cutoff = InteractionEvents.cutoff()

    LocalMessage
    |> where([m], m.user_id == ^user_id and m.sent_at > ^cutoff)
    |> where([m], m.is_from_me == false)
    |> select([m], %{sent_at: m.sent_at, sender_handle: m.sender_handle, chat_key: m.chat_key})
    |> Repo.all()
    |> Enum.group_by(& &1.chat_key)
    |> Enum.flat_map(fn {chat_key, messages} ->
      person_ids =
        messages
        |> Enum.map(& &1.sender_handle)
        |> resolve_person_ids(handle_index, own_handles)

      # A direct chat resolves to a single person; only real groups edge.
      if chat_key != nil and length(person_ids) >= 2 and length(person_ids) <= @max_group_members do
        latest = messages |> Enum.map(& &1.sent_at) |> Enum.max(DateTime)
        pair_edges(person_ids, @group_chat_weight * InteractionEvents.decay(latest, now))
      else
        []
      end
    end)
  end

  defp resolve_person_ids(handles, handle_index, own_handles) do
    handles
    |> Enum.map(&InteractionEvents.normalize_handle/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.reject(&MapSet.member?(own_handles, &1))
    |> Enum.map(&Map.get(handle_index, &1))
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp pair_edges(person_ids, weight) when length(person_ids) >= 2 do
    for a <- person_ids, b <- person_ids, a < b, do: {{a, b}, weight}
  end

  defp pair_edges(_person_ids, _weight), do: []

  # ---------------------------------------------------------------------------
  # Output shaping
  # ---------------------------------------------------------------------------

  defp percentiles(ranks) do
    positive = ranks |> Enum.filter(fn {_id, mass} -> mass > 0.0 end) |> Enum.sort_by(&elem(&1, 1))

    case length(positive) do
      0 ->
        %{}

      1 ->
        %{elem(hd(positive), 0) => 100}

      count ->
        positive
        |> Enum.with_index()
        |> Map.new(fn {{id, _mass}, index} ->
          {id, round(100 * index / (count - 1))}
        end)
    end
  end

  defp top_connections(person_id, edges, names) do
    edges
    |> Enum.flat_map(fn
      {{^person_id, other}, weight} -> [{other, weight}]
      {{other, ^person_id}, weight} -> [{other, weight}]
      _ -> []
    end)
    |> Enum.sort_by(&elem(&1, 1), :desc)
    |> Enum.take(@top_connections)
    |> Enum.map(fn {other, weight} ->
      %{
        "person_id" => other,
        "name" => Map.get(names, other),
        "weight" => Float.round(weight, 3)
      }
    end)
  end

  defp persist(person, rank, signals) do
    existing_signals = get_in(person.metadata || %{}, ["graph_signals"])
    existing_rank = person.network_rank || 0

    unchanged =
      existing_rank == rank and
        Map.get(existing_signals || %{}, "mass") == Map.get(signals || %{}, "mass") and
        (signals != nil or existing_signals == nil)

    if unchanged do
      :skip
    else
      metadata =
        case signals do
          nil -> Map.delete(person.metadata || %{}, "graph_signals")
          signals -> Map.put(person.metadata || %{}, "graph_signals", signals)
        end

      person
      |> Ecto.Changeset.change(network_rank: rank, metadata: metadata)
      |> Repo.update()
      |> case do
        {:ok, _person} ->
          :ok

        {:error, changeset} ->
          Logger.warning("Relationship graph update failed",
            person_id: person.id,
            reason: inspect(changeset.errors)
          )

          :skip
      end
    end
  end
end
