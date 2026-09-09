defmodule Maraithon.PeopleNetwork.Aggregate do
  @moduledoc "Streaming activity aggregation. Calendar and open work never become messages."
  alias Maraithon.PeopleNetwork.Identity

  @windows [30, 90, 180]
  def windows, do: @windows

  def new(identity, now) do
    %{
      identity: identity,
      now: now,
      nodes: identity.nodes,
      seen: MapSet.new(),
      sources: %{},
      warnings: [],
      upcoming: %{},
      direct_peers: %{},
      windows: Map.new(@windows, &{&1, %{stats: %{}, contexts: %{}}})
    }
  end

  def add(nil, acc), do: acc

  def add(event, acc) do
    if MapSet.size(acc.seen) >= 100_000 or map_size(acc.nodes) > 15_000,
      do: throw(:people_network_budget_exceeded)

    if MapSet.member?(acc.seen, event.key) do
      acc
    else
      participants =
        if event.source == "slack" and event.from_user, do: [], else: event.participants

      resolved =
        participants
        |> Enum.flat_map(fn p ->
          case Identity.resolve(acc.identity, p) do
            nil -> []
            node -> [{node, p.role}]
          end
        end)
        |> Enum.uniq_by(fn {node, _role} -> node.id end)

      nodes =
        Enum.reduce(resolved, acc.nodes, fn {node, _}, nodes ->
          Map.put_new(nodes, node.id, node)
        end)

      peers =
        case Map.get(event, :peer_key) do
          nil ->
            acc.direct_peers

          key ->
            Map.update(
              acc.direct_peers,
              key,
              MapSet.new(resolved, fn {node, _} -> node.id end),
              &Enum.reduce(resolved, &1, fn {node, _}, peers -> MapSet.put(peers, node.id) end)
            )
        end

      acc = %{
        acc
        | nodes: nodes,
          direct_peers: peers,
          seen: MapSet.put(acc.seen, event.key),
          sources: Map.update(acc.sources, event.source, 1, &(&1 + 1))
      }

      if event.kind == "upcoming" do
        %{
          acc
          | upcoming:
              Enum.reduce(resolved, acc.upcoming, fn {node, _}, map ->
                Map.update(map, node.id, [event.evidence], fn meetings ->
                  [event.evidence | meetings]
                  |> Enum.uniq_by(&{&1.at, &1.title})
                  |> earliest(5)
                end)
              end)
        }
      else
        days_old = DateTime.diff(acc.now, event.at, :second) / 86_400

        windows =
          Map.new(acc.windows, fn {days, window} ->
            {days,
             if(days_old <= days,
               do: add_window(window, event, resolved, acc.identity),
               else: window
             )}
          end)

        %{acc | windows: windows}
      end
    end
  end

  defp add_window(window, event, resolved, identity) do
    direct? = direct?(event, identity)
    ids = Enum.map(resolved, fn {node, _} -> node.id end)

    stats =
      Enum.reduce(resolved, window.stats, fn {node, role}, stats ->
        direction = direction(event, role)
        stat = Map.get(stats, node.id, empty_stat())
        updated = add_stat(stat, event, direction, direct?)
        Map.put(stats, node.id, updated)
      end)

    context =
      Map.get(window.contexts, event.context, %{
        ids: MapSet.new(),
        outbound: 0,
        at: event.at,
        source: event.source,
        peer_key: Map.get(event, :peer_key),
        direct?: direct?,
        calendar?: event.kind == "calendar",
        evidence: [],
        large?: Map.get(event, :large?, false)
      })

    context = %{
      context
      | ids: Enum.into(ids, context.ids),
        outbound: context.outbound + if(event.from_user, do: 1, else: 0),
        at: latest(context.at, event.at),
        evidence:
          newest([Map.put(event.evidence, :from_user, event.from_user) | context.evidence], 3),
        large?: context.large? or Map.get(event, :large?, false)
    }

    %{window | stats: stats, contexts: Map.put(window.contexts, event.context, context)}
  end

  def empty_stat do
    %{
      messages: 0,
      inbound: 0,
      outbound: 0,
      shared: 0,
      calendar: 0,
      days: MapSet.new(),
      channels: %{},
      last_at: nil,
      history: [],
      direct_evidence: [],
      shared_evidence: [],
      daily: %{}
    }
  end

  defp add_stat(stat, %{kind: "calendar"} = event, _direction, _direct?) do
    %{
      stat
      | calendar: stat.calendar + 1,
        history:
          newest(
            [Map.merge(event.evidence, %{kind: "calendar", direction: "shared"}) | stat.history],
            8
          )
    }
  end

  defp add_stat(stat, event, direction, direct?) do
    day = DateTime.to_date(event.at)

    evidence =
      Map.merge(event.evidence, %{
        kind: if(direct?, do: "direct", else: "shared"),
        direction: Atom.to_string(direction)
      })

    bucket = {day, event.source}
    daily = Map.get(stat.daily, bucket, %{inbound: 0, outbound: 0, at: event.at})

    daily =
      if direct? and direction in [:inbound, :outbound] do
        daily |> Map.update!(direction, &(&1 + 1)) |> Map.put(:at, latest(daily.at, event.at))
      else
        daily
      end

    %{
      stat
      | messages: stat.messages + 1,
        inbound: stat.inbound + if(direction == :inbound, do: 1, else: 0),
        outbound: stat.outbound + if(direction == :outbound, do: 1, else: 0),
        shared: stat.shared + if(direct?, do: 0, else: 1),
        days: MapSet.put(stat.days, day),
        channels: Map.update(stat.channels, event.source, 1, &(&1 + 1)),
        last_at: latest(stat.last_at, event.at),
        direct_evidence:
          if(direct?,
            do: newest([evidence | stat.direct_evidence], 3),
            else: stat.direct_evidence
          ),
        shared_evidence:
          if(direct?,
            do: stat.shared_evidence,
            else: newest([evidence | stat.shared_evidence], 3)
          ),
        daily: Map.put(stat.daily, bucket, daily),
        history:
          newest(
            [
              Map.merge(event.evidence, %{
                kind: if(direct?, do: "direct", else: "shared"),
                direction: Atom.to_string(direction)
              })
              | stat.history
            ],
            8
          )
    }
  end

  defp direct?(%{kind: "direct"}, _identity), do: true
  defp direct?(%{kind: "candidate_direct", source: "slack"}, _identity), do: true

  defp direct?(%{kind: "candidate_direct"} = event, identity) do
    others =
      event.participants
      |> Enum.map(& &1.handle)
      |> Enum.reject(&(is_nil(&1) or MapSet.member?(identity.own, &1)))
      |> Enum.uniq()

    addressed_to_user =
      Enum.any?(
        event.participants,
        &(&1.role == "to" and MapSet.member?(identity.own, &1.handle))
      )

    length(others) == 1 and (event.from_user or addressed_to_user)
  end

  defp direct?(_event, _identity), do: false

  defp direction(%{source: "gmail", from_user: true}, role),
    do: if(role == "to", do: :outbound, else: :shared)

  defp direction(%{source: "gmail", from_user: false}, role),
    do: if(role == "from", do: :inbound, else: :shared)

  defp direction(%{from_user: true}, _role), do: :outbound
  defp direction(_event, _role), do: :inbound

  def newest(items, limit),
    do:
      items |> Enum.uniq_by(&{&1.type, &1.id}) |> Enum.sort_by(& &1.at, :desc) |> Enum.take(limit)

  defp earliest(items, limit),
    do: items |> Enum.uniq_by(&{&1.type, &1.id}) |> Enum.sort_by(& &1.at) |> Enum.take(limit)

  def latest(nil, right), do: right
  def latest(left, right), do: if(DateTime.compare(left, right) == :lt, do: right, else: left)
end
