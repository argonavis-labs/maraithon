defmodule Maraithon.Delegations.Outbox do
  @moduledoc "Conversation events and idempotent, post-commit Agent wakes."
  import Ecto.Query
  alias Maraithon.{Repo, Runtime.AgentDirectives, Runtime.DatabaseClock}
  alias Maraithon.Delegations.{Delegation, Event}

  @doc "Append under the caller's authority and delegation lock, in its result transaction."
  def append!(%Delegation{} = delegation, kind, key, data, attrs \\ %{}) do
    unless Repo.in_transaction?(), do: raise(ArgumentError, "event append requires a transaction")

    case Repo.get_by(Event, delegation_id: delegation.id, event_key: key) do
      nil ->
        attrs = Map.take(attrs, [:source_ref, :source_revision, :occurred_at])

        %Event{user_id: delegation.user_id}
        |> Event.changeset(
          Map.merge(attrs, %{
            delegation_id: delegation.id,
            kind: kind,
            event_key: key,
            data: data,
            occurred_at: Map.get_lazy(attrs, :occurred_at, &DatabaseClock.now!/0),
            wake_state: if(Delegation.live?(delegation), do: "pending", else: "consumed")
          })
        )
        |> Repo.insert!()

      existing ->
        Event.hydrate(existing)
    end
  end

  @doc "Republish a bounded batch after commit. Failed publications remain pending."
  def publish_pending(user_id, limit \\ 25) when is_binary(user_id) and limit in 1..100 do
    if Repo.in_transaction?() do
      {:error, :publish_requires_commit}
    else
      ids =
        Repo.all(
          from e in Event,
            join: d in Delegation,
            on: d.id == e.delegation_id and d.user_id == e.user_id,
            where: e.user_id == ^user_id and e.wake_state == "pending" and not is_nil(d.agent_id),
            order_by: e.seq,
            limit: ^limit,
            select: e.id
        )

      {:ok, Enum.count(ids, &match?({:ok, _}, publish(user_id, &1)))}
    end
  end

  defp publish(user_id, event_id) do
    event = Repo.get_by!(Event, id: event_id, user_id: user_id) |> Event.hydrate()

    delegation =
      Repo.get_by!(Delegation, id: event.delegation_id, user_id: user_id) |> Delegation.hydrate()

    payload = %{
      "job_type" => "delegation_event",
      "job_id" => event.id,
      "payload" => %{"delegation_id" => delegation.id}
    }

    result =
      Repo.transaction(fn ->
        # The directive's Agent/Binding/Guard/Lease prefix is acquired before
        # conversation rows. Never call this inside an ingestion/job transaction.
        with {:ok, directive} <-
               AgentDirectives.enqueue_in_transaction(
                 delegation.agent_id,
                 user_id,
                 "background_job",
                 payload,
                 "delegation-event:#{event.id}"
               ) do
          current =
            Repo.one!(
              from d in Delegation,
                where: d.id == ^delegation.id and d.user_id == ^user_id,
                lock: "FOR UPDATE"
            )
            |> Delegation.hydrate()

          if current.agent_id != delegation.agent_id, do: Repo.rollback(:coordinator_changed)

          locked =
            Repo.one!(
              from e in Event,
                where: e.id == ^event.id and e.user_id == ^user_id,
                lock: "FOR UPDATE"
            )
            |> Event.hydrate()

          if locked.wake_state == "pending" do
            locked |> Event.changeset(%{wake_state: "dispatched"}) |> Repo.update!()
          end

          directive
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end)

    case result do
      {:ok, directive} ->
        AgentDirectives.notify_committed(directive)
        result

      error ->
        error
    end
  rescue
    Ecto.NoResultsError -> {:error, :event_removed}
  end
end
