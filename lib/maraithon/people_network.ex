defmodule Maraithon.PeopleNetwork do
  @moduledoc "Independent, asynchronously materialized People network."
  import Ecto.Query
  alias Maraithon.Accounts.User
  alias Maraithon.PeopleNetwork.{Generation, Profile, Snapshot}
  alias Maraithon.Repo
  alias Maraithon.Runtime.BackgroundJobs

  @queue "people_network"
  def queue, do: @queue

  def enqueue(user_id) when is_binary(user_id) do
    BackgroundJobs.enqueue("people_network_refresh", %{
      user_id: user_id,
      queue: @queue,
      partition_key: user_id,
      rate_limit_key: "people_network",
      dedupe_key: "people_network:#{user_id}",
      max_attempts: 2
    })
  end

  def discover do
    cutoff = DateTime.add(DateTime.utc_now(), -10, :minute)

    users =
      Repo.all(
        from u in User,
          left_join: s in Snapshot,
          on: s.user_id == u.id,
          left_join: g in Generation,
          on: g.id == s.generation_id,
          where: is_nil(u.privacy_erasure_requested_at),
          where:
            is_nil(s.refreshed_at) or s.refreshed_at < ^cutoff or not is_nil(g.invalidated_at),
          order_by: [asc_nulls_first: s.refreshed_at, asc: u.id],
          limit: 25,
          select: u.id
      )

    Enum.reduce_while(users, {:ok, %{enqueued: 0}}, fn user_id, {:ok, summary} ->
      case enqueue(user_id) do
        {:ok, _} -> {:cont, {:ok, %{enqueued: summary.enqueued + 1}}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  def view(user_id, opts \\ []) do
    days = window_days(Keyword.get(opts, :days, 30))
    query = clean_query(Keyword.get(opts, :query))
    focus = Keyword.get(opts, :focus)

    case current(user_id) do
      nil ->
        %{
          status: "preparing",
          window_days: days,
          nodes: [],
          edges: [],
          meetings: [],
          people_count: 0
        }

      generation ->
        base = profiles_query(user_id, generation.id, days)
        ranked = base |> search(query) |> order_by([p], desc: p.rank, asc: p.display_name)
        rows = Repo.all(from p in ranked, limit: 60, select: p.profile)
        rows = expand_focus(base, rows, focus)
        ids = MapSet.new(rows, & &1["id"])

        meetings =
          Repo.all(
            from p in base,
              where: fragment("jsonb_array_length(?->'next_meetings') > 0", p.profile),
              order_by: fragment("?->'next_meetings'->0->>'at'", p.profile),
              limit: 30,
              select: p.profile
          )

        %{
          status: "ready",
          generation_id: generation.id,
          as_of: generation.as_of,
          refreshed_at: generation.completed_at,
          window_days: days,
          query: query,
          people_count: generation.summary["people"] || 0,
          sources: generation.summary["sources"] || %{},
          warnings: generation.summary["warnings"] || [],
          nodes:
            Enum.map(
              rows,
              &Map.drop(
                &1,
                ~w(history handles connections next_meetings communication_signals graph_signals direct_evidence shared_evidence)
              )
            ),
          edges: edges(rows, ids),
          meetings: meetings_summary(meetings),
          matches_shown: length(rows)
        }
    end
  end

  def person(user_id, node_id, opts \\ []) do
    with %Generation{} = generation <- current(user_id),
         %Profile{} = row <-
           Repo.one(
             from p in profiles_query(
                    user_id,
                    generation.id,
                    window_days(Keyword.get(opts, :days, 30))
                  ),
                  where: p.node_id == ^node_id
           ) do
      {:ok, row.profile}
    else
      _ -> {:error, :not_found}
    end
  end

  def current(user_id) do
    Repo.one(
      from s in Snapshot,
        join: g in Generation,
        on: g.id == s.generation_id,
        where:
          s.user_id == ^user_id and g.user_id == ^user_id and not is_nil(g.completed_at) and
            is_nil(g.invalidated_at),
        select: g
    )
  end

  def invalidate(user_id) do
    Repo.update_all(
      from(g in Generation, where: g.user_id == ^user_id and is_nil(g.invalidated_at)),
      set: [invalidated_at: DateTime.utc_now()]
    )

    :ok
  end

  def window_days(value) when value in [30, "30"], do: 30
  def window_days(value) when value in [90, "90"], do: 90
  def window_days(value) when value in [180, "180"], do: 180
  def window_days(_value), do: 30

  defp profiles_query(user_id, generation_id, days) do
    from p in Profile,
      where:
        p.user_id == ^user_id and p.generation_id == ^generation_id and p.window_days == ^days
  end

  defp search(query, nil), do: where(query, [p], p.rank > 0)

  defp search(query, term) do
    pattern = "%" <> String.replace(term, ["%", "_", "\\"], " ") <> "%"

    where(
      query,
      [p],
      ilike(p.display_name, ^pattern) or ilike(fragment("?->>'subtitle'", p.profile), ^pattern)
    )
  end

  defp expand_focus(_base, rows, value) when value in [nil, ""], do: rows

  defp expand_focus(base, rows, id) do
    case Repo.one(from p in base, where: p.node_id == ^id, select: p.profile) do
      nil ->
        rows

      node ->
        ids = Enum.map(node["connections"] || [], & &1["node_id"])
        neighbors = Repo.all(from p in base, where: p.node_id in ^ids, select: p.profile)
        Enum.uniq_by([node | neighbors] ++ rows, & &1["id"])
    end
  end

  defp edges(nodes, visible_ids) do
    direct =
      Enum.flat_map(nodes, fn node ->
        weight = node["direct_weight"] || 0
        shared = node["shared_weight"] || 0

        if weight + shared > 0 do
          [
            %{
              id: "you:#{node["id"]}",
              from: "you",
              to: node["id"],
              weight: weight + shared,
              kind: if(weight > 0, do: "direct", else: "shared"),
              evidence:
                if(weight > 0,
                  do: node["direct_evidence"] || [],
                  else: node["shared_evidence"] || []
                )
            }
          ]
        else
          []
        end
      end)

    shared =
      Enum.flat_map(nodes, fn node ->
        Enum.flat_map(node["connections"] || [], fn edge ->
          other = edge["node_id"]

          if MapSet.member?(visible_ids, other) do
            [a, b] = Enum.sort([node["id"], other])

            [
              %{
                id: "#{a}:#{b}",
                from: a,
                to: b,
                weight: edge["weight"],
                kind: "shared",
                evidence: edge["evidence"]
              }
            ]
          else
            []
          end
        end)
      end)

    Enum.uniq_by(direct ++ shared, & &1.id)
  end

  defp meetings_summary(profiles) do
    profiles
    |> Enum.flat_map(fn node ->
      Enum.map(
        node["next_meetings"] || [],
        &Map.put(&1, "person", Map.take(node, ~w(id name subtitle person_id)))
      )
    end)
    |> Enum.group_by(& &1["id"])
    |> Enum.map(fn {_id, entries} ->
      entries
      |> hd()
      |> Map.delete("person")
      |> Map.put("people", Enum.map(entries, & &1["person"]))
    end)
    |> Enum.sort_by(& &1["at"])
    |> Enum.take(12)
  end

  defp clean_query(value) when is_binary(value) do
    case value |> String.trim() |> String.slice(0, 160) do
      "" -> nil
      term -> term
    end
  end

  defp clean_query(_value), do: nil
end
