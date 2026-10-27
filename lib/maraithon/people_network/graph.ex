defmodule Maraithon.PeopleNetwork.Graph do
  @moduledoc "Personalized PageRank over direct contact and observed shared context."
  alias Maraithon.PeopleNetwork.Aggregate

  def profiles(aggregate, days) do
    window = Map.fetch!(aggregate.windows, days)

    {stats, shared_mass} =
      complete_conversations(window.stats, window.contexts, aggregate.now, aggregate.direct_peers)

    direct = Map.new(stats, fn {id, stat} -> {id, direct_mass(stat, aggregate.now)} end)
    root_mass = Map.merge(direct, shared_mass, fn _id, a, b -> a + b end)
    connections = connections(window.contexts, aggregate.now)
    edges = Map.new(connections, fn {pair, value} -> {pair, value.weight} end)

    edges =
      Enum.reduce(root_mass, edges, fn {id, weight}, acc ->
        if weight > 0, do: Map.put(acc, {:user, id}, weight), else: acc
      end)

    # The existing pure solver has no database/runtime side effects.
    ranks = Maraithon.Crm.RelationshipGraph.pagerank(%{user: 1.0}, edges) |> Map.delete(:user)
    max_rank = Enum.max(Map.values(ranks), fn -> 1.0 end)
    neighbors = neighbors(connections, aggregate.nodes)
    total_mass = Enum.sum(Map.values(ranks))
    total_direct = Enum.sum(Map.values(direct))

    aggregate.nodes
    |> Enum.map(fn {id, node} ->
      stat = Map.get(stats, id, Aggregate.empty_stat())
      mass = Map.get(ranks, id, 0.0)
      direct_mass = Map.get(direct, id, 0.0)
      rank = if max_rank > 0, do: 100.0 * mass / max_rank, else: 0.0
      {x, y} = position(id, rank)

      %{
        id: id,
        person_id: node.person_id,
        name: node.name,
        subtitle: node.subtitle,
        handles: node.handles,
        rank: Float.round(rank, 3),
        rank_mass: mass,
        direct_score: round(100 * direct_mass / (direct_mass + 12)),
        direct_weight: Float.round(direct_mass, 3),
        shared_weight: Float.round(Map.get(shared_mass, id, 0.0), 3),
        active_days: MapSet.size(stat.days),
        message_count: stat.messages,
        inbound: stat.inbound,
        outbound: stat.outbound,
        shared_count: stat.shared,
        calendar_count: stat.calendar,
        last_at: if(stat.last_at, do: DateTime.to_iso8601(stat.last_at)),
        channels:
          Enum.map(Enum.sort(stat.channels), fn {source, count} ->
            %{source: source, count: count}
          end),
        communication_signals: communication_signals(stat, direct_mass, aggregate.now),
        graph_signals: %{
          rank: round(rank),
          mass: mass,
          direct_share: if(total_direct > 0, do: direct_mass / total_direct, else: 0.0),
          network_lift:
            if(total_mass > 0, do: mass / total_mass, else: 0.0) -
              if(total_direct > 0, do: direct_mass / total_direct, else: 0.0),
          computed_at: DateTime.to_iso8601(aggregate.now),
          top_connections:
            Enum.take(Map.get(neighbors, id, []), 5)
            |> Enum.map(fn edge ->
              %{person_id: edge.node_id, name: edge.name, weight: edge.weight}
            end)
        },
        history: stat.history,
        direct_evidence: stat.direct_evidence,
        shared_evidence: stat.shared_evidence,
        next_meetings: Map.get(aggregate.upcoming, id, []),
        connections: Map.get(neighbors, id, []),
        x: x,
        y: y
      }
    end)
  end

  defp complete_conversations(stats, contexts, now, direct_peers) do
    Enum.reduce(contexts, {stats, %{}}, fn {_key, context}, {stats, shared} ->
      ids = Map.get(direct_peers, context.peer_key, context.ids) |> MapSet.to_list()

      cond do
        context.source == "slack" and context.direct? and context.outbound > 0 and
            length(ids) == 1 ->
          id = hd(ids)
          stat = Map.get(stats, id, Aggregate.empty_stat())
          key = {DateTime.to_date(context.at), "slack"}
          daily = Map.get(stat.daily, key, %{inbound: 0, outbound: 0, at: context.at})
          daily = %{daily | outbound: daily.outbound + context.outbound}

          stat = %{
            stat
            | messages: stat.messages + context.outbound,
              outbound: stat.outbound + context.outbound,
              daily: Map.put(stat.daily, key, daily),
              channels:
                Map.update(stat.channels, "slack", context.outbound, &(&1 + context.outbound)),
              days: MapSet.put(stat.days, DateTime.to_date(context.at))
          }

          stat = %{
            stat
            | last_at: Aggregate.latest(stat.last_at, context.at),
              direct_evidence:
                Aggregate.newest(
                  stat.direct_evidence ++
                    (context.evidence
                     |> Enum.filter(& &1.from_user)
                     |> Enum.map(&Map.merge(&1, %{kind: "direct", direction: "outbound"}))),
                  3
                ),
              history:
                Aggregate.newest(
                  stat.history ++
                    Enum.map(
                      Enum.filter(context.evidence, & &1.from_user),
                      &Map.merge(&1, %{kind: "direct", direction: "outbound"})
                    ),
                  8
                )
          }

          {Map.put(stats, id, stat), shared}

        not context.calendar? and not context.direct? and context.outbound > 0 and
            length(ids) <= 10 ->
          mass = 0.2 * decay(context.at, now)

          {stats,
           Enum.reduce(ids, shared, &Map.update(&2, &1, mass, fn prior -> prior + mass end))}

        true ->
          {stats, shared}
      end
    end)
  end

  defp direct_mass(stat, now) do
    raw =
      Enum.reduce(stat.daily, 0.0, fn {_key, daily}, total ->
        # Distinct active days carry more weight than message bursts.
        volume = min(daily.inbound + daily.outbound * 1.5, 8)
        total + :math.log(1 + volume) * decay(daily.at, now)
      end)

    inbound = Enum.any?(stat.daily, fn {_key, daily} -> daily.inbound > 0 end)
    outbound = Enum.any?(stat.daily, fn {_key, daily} -> daily.outbound > 0 end)

    cond do
      inbound and outbound -> raw * 1.3
      not outbound -> raw * 0.15
      true -> raw
    end
  end

  defp communication_signals(stat, mass, now) do
    days =
      stat.daily
      |> Enum.filter(fn {_, d} -> d.inbound + d.outbound > 0 end)
      |> Enum.map(fn {{day, _}, _} -> day end)
      |> Enum.uniq()
      |> Enum.sort(Date)

    gaps =
      days
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.map(fn [a, b] -> Date.diff(b, a) end)
      |> Enum.sort()

    cadence = if length(days) >= 3, do: Enum.at(gaps, div(length(gaps), 2))
    score = round(100 * mass / (mass + 12))
    since = if stat.last_at, do: max(DateTime.diff(now, stat.last_at, :day), 0)

    %{
      score: score,
      events: stat.messages,
      inbound: stat.inbound,
      outbound: stat.outbound,
      mutual: 0,
      channels: stat.channels,
      last_event_at: if(stat.last_at, do: DateTime.to_iso8601(stat.last_at)),
      days_since_last: since,
      cadence_days: cadence,
      overdue:
        score >= 40 and is_number(cadence) and is_number(since) and
          since > max(7, round(cadence * 1.5)),
      computed_at: DateTime.to_iso8601(now)
    }
  end

  defp connections(contexts, now) do
    Enum.reduce(contexts, %{}, fn {_key, context}, edges ->
      ids = context.ids |> MapSet.to_list() |> Enum.sort()

      if length(ids) in 2..10 and not context.large? do
        kind = if context.calendar?, do: "calendar", else: "conversation"
        weight = decay(context.at, now) * if(context.calendar?, do: 0.25, else: 0.5)
        pairs = for a <- ids, b <- ids, a < b, do: {a, b}

        Enum.reduce(pairs, edges, fn pair, map ->
          Map.update(
            map,
            pair,
            %{
              weight: weight,
              sources: %{context.source => 1},
              evidence: Enum.map(context.evidence, &Map.put(&1, :kind, kind))
            },
            fn value ->
              %{
                value
                | weight: value.weight + weight,
                  sources: Map.update(value.sources, context.source, 1, &(&1 + 1)),
                  evidence:
                    Aggregate.newest(
                      value.evidence ++ Enum.map(context.evidence, &Map.put(&1, :kind, kind)),
                      3
                    )
              }
            end
          )
        end)
      else
        edges
      end
    end)
  end

  defp neighbors(connections, nodes) do
    Enum.reduce(connections, %{}, fn {{a, b}, value}, acc ->
      Enum.reduce([{a, b}, {b, a}], acc, fn {id, other}, map ->
        connection = %{
          node_id: other,
          name: Map.fetch!(nodes, other).name,
          weight: Float.round(value.weight, 3),
          sources: value.sources,
          evidence: value.evidence
        }

        Map.update(map, id, [connection], &[connection | &1])
      end)
    end)
    |> Map.new(fn {id, edges} ->
      {id, edges |> Enum.sort_by(& &1.weight, :desc) |> Enum.take(24)}
    end)
  end

  defp position(id, rank) do
    <<angle::unsigned-32, _::binary>> = :crypto.hash(:sha256, id)
    radians = angle / 4_294_967_296 * 2 * :math.pi()
    radius = 0.3 + 0.65 * (1 - :math.sqrt(rank / 100))
    {Float.round(:math.cos(radians) * radius, 5), Float.round(:math.sin(radians) * radius, 5)}
  end

  defp decay(at, now), do: :math.exp(-max(DateTime.diff(now, at, :second), 0) / 86_400 / 45)
end
