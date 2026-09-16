defmodule Maraithon.Delegations.Coordinator do
  @moduledoc "Bounded reduction under the coordinator's existing directive lease. No provider I/O."
  import Ecto.Query
  alias Maraithon.{Repo, Delegations}
  alias Maraithon.Delegations.{Delegation, Event, Turn, Outbox, StateMachine, Commands}

  def drain(user_id, agent_id, now, opts \\ []) do
    unless Repo.in_transaction?(),
      do: raise(ArgumentError, "coordinator requires runtime authority")

    limit = Keyword.get(opts, :limit, 25) |> min(25) |> max(1)

    rows =
      Repo.all(
        candidates(user_id, agent_id, now)
        |> limit(^limit)
        |> lock("FOR UPDATE OF d0 SKIP LOCKED")
      )

    {cursor, changed, pending?} =
      Enum.reduce(rows, {0, [], false}, fn
        %{ready: false}, acc ->
          acc

        %{row: row, ready: true}, {cursor, ids, pending?} ->
          {last, more?} = drain_delegation(Delegation.hydrate(row), now)
          {max(cursor, last), [row.id | ids], pending? or more?}
      end)

    more? = pending? or (length(rows) == limit and List.last(rows).ready)
    cap = DateTime.add(now, 6, :hour)

    next_wake =
      Enum.reduce(rows, cap, fn
        %{ready: false, row: %{next_wake_at: wake}}, acc when not is_nil(wake) ->
          earlier(wake, acc)

        _, acc ->
          acc
      end)

    # A changed row may have scheduled a follow-up earlier than the cap.
    next_wake = if changed == [], do: next_wake, else: next_due(user_id, agent_id, next_wake)
    %{cursor: cursor, more?: more?, next_wake: next_wake, changed: changed}
  end

  defp drain_delegation(d, now) do
    if d.next_wake_at && DateTime.compare(d.next_wake_at, now) != :gt do
      Outbox.append!(
        d,
        "timer_due",
        "timer:#{d.current_grant_id}:#{d.source_revision}:#{DateTime.to_iso8601(d.next_wake_at)}",
        %{},
        %{
          occurred_at: now
        }
      )
    end

    events =
      Repo.all(
        from e in Event,
          where:
            e.user_id == ^d.user_id and e.delegation_id == ^d.id and e.wake_state != "consumed",
          order_by: e.seq,
          limit: 26,
          lock: "FOR UPDATE"
      )
      |> Enum.map(&Event.hydrate/1)

    {_d, last} =
      Enum.reduce(Enum.take(events, 25), {d, 0}, fn event, {current, last} ->
        grant = Delegations.current_grant(current)

        next =
          if acceptable?(current, grant, event),
            do: reduce!(current, grant, event, now),
            else: current

        event |> Event.changeset(%{wake_state: "consumed"}) |> Repo.update!()
        {next, max(last, event.seq)}
      end)

    {last, length(events) > 25}
  end

  # Includes the earliest future row, so a quiet six-hour wake is one query.
  defp candidates(user_id, agent_id, now) do
    ready =
      dynamic(
        [d],
        (not is_nil(d.next_wake_at) and d.next_wake_at <= ^now) or
          exists(
            from e in Event,
              where:
                e.delegation_id == parent_as(:delegation).id and
                  e.wake_state != "consumed",
              select: 1
          )
      )

    from d in Delegation,
      as: :delegation,
      where:
        d.user_id == ^user_id and d.agent_id == ^agent_id and
          d.schema_version == 1 and d.state not in ^Delegation.terminal_states(),
      order_by: ^[desc: ready, asc_nulls_last: :next_wake_at, asc: :id],
      select: ^%{row: dynamic([d], d), ready: ready}
  end

  defp next_due(user_id, agent_id, cap) do
    case Repo.one(
           from d in Delegation,
             where:
               d.user_id == ^user_id and d.agent_id == ^agent_id and
                 d.schema_version == 1 and d.state not in ^Delegation.terminal_states(),
             select: min(d.next_wake_at)
         ) do
      nil -> cap
      wake -> earlier(wake, cap)
    end
  end

  defp earlier(a, b), do: if(DateTime.compare(a, b) == :lt, do: a, else: b)

  defp acceptable?(d, grant, event) do
    worker? =
      event.kind in ~w(sync_result decision send_receipt send_unknown failure capacity_hold)

    cond do
      d.schema_version != 1 ->
        false

      event.kind == "user_action" ->
        event.data["grant_version"] == grant.version

      event.kind in ~w(send_receipt send_unknown reconciliation_exhausted) or
          (event.kind == "failure" and is_binary(event.data["action_id"])) ->
        Maraithon.Delegations.Receipts.valid_event?(d, event) and current_turn?(d, event)

      worker? ->
        current_turn?(d, event)

      true ->
        true
    end
  end

  defp current_turn?(d, event) do
    case Ecto.UUID.cast(event.data["turn_id"]) do
      {:ok, id} ->
        case Repo.get_by(Turn, id: id, delegation_id: d.id, user_id: d.user_id)
             |> Turn.hydrate() do
          nil ->
            false

          turn ->
            event.data["grant_version"] == turn.grant_version and
              ((event.kind in ~w(send_receipt send_unknown failure reconciliation_exhausted) and
                  is_binary(turn.prepared_action_id) and
                  turn.prepared_action_id == event.data["action_id"]) or
                 (turn.status in ~w(deciding validated dispatched) and
                    turn.source_revision == d.source_revision and
                    turn.grant_version == Delegations.current_grant(d).version))
        end

      _ ->
        false
    end
  end

  defp reduce!(d, grant, event, now) do
    case transition(d, grant, event) do
      {:error, _} ->
        d

      {next, commands} ->
        next = Commands.apply(next, grant, event, commands, now)

        changes =
          Map.take(next, Delegation.payload_binding_spec().bound_fields ++ [:data])
          |> Map.put(:revision, d.revision + 1)

        saved = d |> Delegation.changeset(changes) |> Repo.update!()
        record_transition(d, saved, grant, event, now)
        saved
    end
  end

  # Record applied outcomes in the same fenced transaction. A model's decision
  # alone is not evidence that workflow changes succeeded. These rows never wake work.
  defp record_transition(before, saved, grant, event, now) do
    if before.state != saved.state do
      Outbox.append!(
        saved,
        "state_changed",
        "state:#{saved.revision}",
        %{
          "state" => saved.state,
          "previous_state" => before.state,
          "revision" => saved.revision,
          "grant_version" => grant.version,
          "turn_id" => event.data["turn_id"],
          "action_id" => event.data["action_id"],
          "question" => saved.data["question"],
          "outcome" =>
            if(saved.state == "completed", do: get_in(saved.data, ["ledger", "latest_outcome"]))
        },
        %{occurred_at: now}
      )
      |> Event.changeset(%{wake_state: "consumed"})
      |> Repo.update!()
    end
  end

  # A receipt still settles its original turn after a control change. It cannot
  # apply an old workflow decision over a newer grant. A resumed conversation
  # first refreshes its sources once the earlier send is proven.
  defp transition(d, grant, %{kind: "send_receipt", data: %{"grant_version" => version}})
       when version != grant.version do
    if d.state == "reconciling" and grant.control_state == "active",
      do: {%{d | state: "ready", next_wake_at: nil}, [:enqueue_sync]},
      else: {d, []}
  end

  defp transition(d, _grant, event), do: StateMachine.apply(d, event)
end
