defmodule Maraithon.Delegations.Reports do
  @moduledoc "Bounded, read-only brief reporting from the durable conversation and spend ledgers."
  import Ecto.Query
  alias Maraithon.{Delegations, Repo}
  alias Maraithon.Delegations.{Delegation, Turn}
  alias Maraithon.Todos.Todo

  @limit 8

  def brief(user_id, now, since) do
    cutoff = DateTime.add(now, -30, :day)

    rows =
      Repo.all(
        from d in Delegation,
          join: t in Todo,
          on: t.id == d.todo_id and t.user_id == d.user_id,
          where: d.user_id == ^user_id and is_nil(d.payload_purged_at),
          where: d.state == "needs_user" or d.updated_at >= ^since,
          order_by: [desc: d.state == "needs_user", desc: d.updated_at, asc: d.id],
          limit: @limit + 1,
          select: {d, t.title}
      )

    selected = Enum.take(rows, @limit)
    ids = Enum.map(selected, fn {d, _} -> d.id end)

    costs =
      from(t in Turn, where: t.user_id == ^user_id and t.delegation_id in ^ids)
      |> cost_query(cutoff)
      |> group_by([t], t.delegation_id)
      |> select_merge([t], %{delegation_id: t.delegation_id})
      |> Repo.all()
      |> Map.new(&{&1.delegation_id, cost_fields(&1)})

    window =
      from(t in Turn, where: t.user_id == ^user_id)
      |> cost_query(cutoff)
      |> Repo.one()
      |> cost_fields()
      |> Map.take(~w(recorded_30d_micro_usd unresolved_micro_usd))

    %{
      "as_of" => DateTime.to_iso8601(now),
      "window_start" => DateTime.to_iso8601(cutoff),
      "cost" => window,
      "more" => length(rows) > @limit,
      "items" =>
        Enum.map(selected, fn {row, title} ->
          d = Delegation.hydrate(row)

          d
          |> Delegations.summary()
          |> Map.take(~w(state actor_label status_line last_action question))
          |> Map.new(fn {key, value} -> {key, plain(value)} end)
          |> Map.merge(%{
            "todo_id" => d.todo_id,
            "title" => plain(title),
            "owner_label" => plain(get_in(d.data, ["task_owner", "label"])),
            "cost" => Map.get(costs, d.id, cost_fields(%{}))
          })
        end)
    }
  end

  # Match the existing budget's conservative window: the last settlement/update
  # of a turn counts its recorded spend. Unresolved reservations never age out.
  defp cost_query(query, cutoff) do
    select(query, [t], %{
      turns: count(t.id),
      model_calls: sum(t.model_calls),
      lifetime_micro_usd: sum(t.cost_micro_usd),
      recorded_30d_micro_usd: filter(sum(t.cost_micro_usd), t.updated_at >= ^cutoff),
      unresolved_micro_usd: sum(t.reserved_micro_usd)
    })
  end

  defp cost_fields(values) do
    fields = ~w(turns model_calls lifetime_micro_usd recorded_30d_micro_usd unresolved_micro_usd)a
    cost = Map.new(fields, &{Atom.to_string(&1), integer(Map.get(values, &1))})

    Map.put(
      cost,
      "average_per_turn_micro_usd",
      if(cost["turns"] > 0, do: div(cost["lifetime_micro_usd"], cost["turns"]))
    )
  end

  def section(%{"items" => items, "cost" => cost} = report) do
    if items == [] and cost["recorded_30d_micro_usd"] == 0 and
         cost["unresolved_micro_usd"] == 0 do
      nil
    else
      lines = Enum.map(items, &item_line/1)
      more = if report["more"], do: ["More conversations are available in Tasks."], else: []

      Enum.join(
        ["## Delegated conversations"] ++
          lines ++
          more ++
          [
            "Recorded LLM spend, last 30 days: #{money(cost["recorded_30d_micro_usd"])}." <>
              unresolved(cost)
          ],
        "\n"
      )
    end
  end

  def section(_), do: nil

  defp item_line(item) do
    cost = item["cost"]
    owner = item["owner_label"]
    question = if item["state"] == "needs_user", do: item["question"]

    details =
      [
        item["actor_label"],
        item["status_line"],
        if(item["state"] == "needs_user" and item["status_line"] != "Needs your decision",
          do: "Needs your decision"
        ),
        if(owner not in [nil, ""], do: "Owner: #{owner}"),
        item["last_action"],
        question
      ]
      |> Enum.reject(&(&1 in [nil, ""]))
      |> Enum.map(&text/1)
      |> Enum.join(". ")

    average =
      if cost["turns"] > 0,
        do:
          " Average #{money(cost["average_per_turn_micro_usd"])} per turn (#{cost["turns"]} turns).",
        else: ""

    "- #{text(item["title"])}: #{details}. LLM cost: #{money(cost["lifetime_micro_usd"])}." <>
      average <> unresolved(cost)
  end

  defp unresolved(%{"unresolved_micro_usd" => amount}) when amount > 0,
    do: " #{money(amount)} reserved; final provider cost is pending."

  defp unresolved(_), do: ""
  defp integer(%Decimal{} = value), do: Decimal.to_integer(value)
  defp integer(nil), do: 0
  defp integer(value), do: value

  defp money(micro),
    do:
      "US$" <> Decimal.to_string(Decimal.div(Decimal.new(micro), Decimal.new(1_000_000)), :normal)

  defp plain(value) when is_binary(value) do
    value
    |> String.replace(~r/\s+/u, " ")
    |> String.slice(0, 180)
  end

  defp plain(_), do: ""

  defp text(value),
    do: String.replace(plain(value), ~r/[\\`*_\[\]<>]/, fn char -> "\\" <> char end)
end
