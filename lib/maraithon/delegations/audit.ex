defmodule Maraithon.Delegations.Audit do
  @moduledoc "Committed, redacted conversation traces. Events are durable; log delivery is best effort."
  import Ecto.Query
  require Logger
  alias Maraithon.Repo
  alias Maraithon.Delegations.{Event, Outbox}

  @buffer {__MODULE__, :events}
  @limit 256
  @fields ~w(agent_id job_id job_type assignment_id grant_id grant_version policy_version provider
    revision source_revision workflow_revision schema_version turn_id run_id action_id input_event_id
    duration_ms cost_micro_usd reserved_micro_usd model actual_model model_stage prompt_version
    input_tokens output_tokens failure_code attempt effect_type)a
  @kinds ~w(user_action inbound_message timer_due sync_result decision failure capacity_hold source_gap
    send_entry send_receipt send_unknown send_deferred reconciliation_exhausted state_changed
    event_accepted event_ignored model_entry model_receipt turn_started)

  # This outer scope never supplies authority. It only remembers bounded IDs,
  # then re-reads committed rows after the caller's transactions have ended.
  def capture(metadata, fun) do
    if Process.get(@buffer) do
      fun.()
    else
      Process.put(@buffer, %{metadata: metadata, ids: [], count: 0})

      try do
        fun.()
      after
        pending = Process.delete(@buffer)
        emit_committed(pending.ids)
      end
    end
  end

  def enrich(d, data) do
    metadata =
      case Process.get(@buffer) do
        %{metadata: metadata} -> metadata
        _ -> %{}
      end

    audit =
      Map.merge(Map.take(metadata, ~w(job_id job_type assignment_id)), %{
        "agent_id" => d.agent_id,
        "provider" => d.provider,
        "revision" => d.revision,
        "source_revision" => d.source_revision,
        "workflow_revision" => d.workflow_revision,
        "schema_version" => d.schema_version
      })

    Map.put(data, "audit", audit)
  end

  def track(%Event{} = event) do
    case Process.get(@buffer) do
      %{count: count} = pending when count < @limit ->
        Process.put(@buffer, %{
          pending
          | ids: [{event.user_id, event.id} | pending.ids],
            count: count + 1
        })

      _ ->
        :ok
    end

    event
  end

  @doc "Record an observation under the caller's existing fence without waking new work."
  def note!(d, kind, key, data, attrs \\ %{}),
    do: Outbox.append!(d, kind, key, data, Map.put(attrs, :wake?, false))

  @doc "Read at most 100 redacted events, newest first, including records missed by process logs."
  def page(user_id, delegation_id, before \\ nil)
      when is_nil(before) or (is_integer(before) and before > 0) do
    query =
      from e in Event,
        where: e.user_id == ^user_id and e.delegation_id == ^delegation_id,
        order_by: [desc: e.seq],
        limit: 101

    query = if before, do: where(query, [e], e.seq < ^before), else: query
    rows = Repo.all(query)
    page = Enum.take(rows, 100)

    %{
      events: Enum.map(page, &(Event.hydrate(&1) |> project())),
      next_before: if(length(rows) > 100, do: List.last(page).seq)
    }
  end

  defp emit_committed([]), do: :ok

  defp emit_committed(ids) do
    # Nested callers defer to the outer capture. Never turn uncommitted data into a log receipt.
    unless Repo.in_transaction?() do
      ids
      |> Enum.uniq()
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
      |> Enum.each(fn {user, ids} ->
        Repo.all(from(e in Event, where: e.user_id == ^user and e.id in ^ids, order_by: e.seq),
          timeout: 2_000
        )
        |> Enum.each(fn row ->
          Logger.info("Delegation event", row |> Event.hydrate() |> project() |> Map.to_list())
        end)
      end)
    end
  rescue
    _ ->
      Logger.warning("Delegation trace remains available in its durable events",
        failure_code: "audit_log_unavailable"
      )
  catch
    _, _ -> :ok
  end

  defp project(event) do
    data = event.data
    fields = Map.merge(data["audit"] || %{}, Map.take(data, Enum.map(@fields, &Atom.to_string/1)))

    @fields
    |> Enum.reduce(%{}, fn key, result ->
      case fields[Atom.to_string(key)] do
        nil ->
          result

        value ->
          safe =
            value
            |> Maraithon.Redaction.redact()
            |> then(&Maraithon.Redaction.log_metadata_value(key, &1))

          Map.put(result, key, safe)
      end
    end)
    |> Map.merge(%{
      event_type: "delegation.#{operation(event)}",
      event_id: event.id,
      event_seq: event.seq,
      delegation_id: event.delegation_id,
      occurred_at: DateTime.to_iso8601(event.occurred_at)
    })
  end

  defp operation(%{kind: "user_action", data: %{"action" => action}})
       when action in ~w(start pause resume take_over stop answer),
       do: action

  defp operation(%{kind: "failure", data: %{"failure_code" => "policy_review_required"}}),
    do: "policy_hold"

  defp operation(%{kind: "send_receipt", data: %{"receipt" => %{"reconciled" => true}}}),
    do: "reconciled"

  defp operation(%{kind: "state_changed", data: %{"state" => state}})
       when state in ~w(completed paused stopped expired waiting_reply),
       do: state

  defp operation(%{kind: "turn_started", data: %{"reminder" => true}}), do: "follow_up"
  defp operation(%{kind: kind}) when kind in @kinds, do: kind
  defp operation(_), do: "other"
end
