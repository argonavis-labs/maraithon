defmodule Maraithon.Delegations.Lifecycle do
  @moduledoc "One supervised coordinator per user, only while conversations need it."
  import Ecto.Query
  alias Maraithon.{Repo, Runtime, DurablePayload}
  alias Maraithon.Delegations.{Delegation, Outbox}
  alias Maraithon.PrivacyErasure.WriteFence
  alias Maraithon.Agents.Agent
  alias Maraithon.Runtime.{AgentRestartGuard, BackgroundJob, DatabaseClock}

  @doc "Candidates only. Retirement rechecks under the lifecycle and user locks."
  def idle_coordinators(now) do
    cutoff = DateTime.add(now, -7, :day)

    from a in Agent,
      as: :idle_coordinator,
      left_join: g in AgentRestartGuard,
      on: g.agent_id == a.id,
      where:
        a.behavior == "delegation_coordinator" and a.install_status == "enabled" and
          a.status in ~w(running degraded) and a.inserted_at <= ^cutoff and
          (is_nil(a.started_at) or a.started_at <= ^cutoff),
      where: is_nil(g.agent_id) or (not g.tripped and not g.needs_recovery),
      where:
        not exists(
          from d in Delegation,
            where:
              d.user_id == parent_as(:idle_coordinator).user_id and
                (d.state not in ^Delegation.terminal_states() or d.updated_at > ^cutoff),
            select: 1
        ),
      where:
        not exists(
          from t in Maraithon.Delegations.Turn,
            where:
              t.user_id == parent_as(:idle_coordinator).user_id and
                t.status in ~w(deciding validated dispatched),
            select: 1
        ),
      where:
        not exists(
          from p in Maraithon.TelegramAssistant.PreparedAction,
            where:
              p.user_id == parent_as(:idle_coordinator).user_id and
                p.authorization_kind == "delegation_grant" and
                p.status not in ~w(executed rejected expired failed),
            select: 1
        )
  end

  @doc false
  def retirement_plan(%Agent{} = agent, now) do
    WriteFence.lock_user_writable!(agent.user_id)

    if Repo.exists?(from a in idle_coordinators(now), where: a.id == ^agent.id) do
      # Existing soft removal stops the process, revokes its binding and cancels
      # timers only after drain proof. History stays; ensure creates the next Agent.
      %{"action" => "remove"}
    else
      {:error, :coordinator_not_idle}
    end
  end

  def ensure(user_id, opts \\ []) do
    if Repo.exists?(
         from d in Delegation,
           where: d.user_id == ^user_id and d.state not in ^Delegation.terminal_states()
       ) do
      with {:ok, agent} <- Runtime.ensure_delegation_coordinator(user_id, consent(user_id), opts),
           {:ok, _} <-
             Repo.transaction(fn ->
               if job = Keyword.get(opts, :job), do: Maraithon.Runtime.JobAuthority.fence!(job)
               DurablePayload.require_current_mutation!()
               WriteFence.lock_user_writable!(user_id)

               Repo.all(
                 from d in Delegation,
                   where:
                     d.user_id == ^user_id and d.state not in ^Delegation.terminal_states() and
                       (is_nil(d.agent_id) or d.agent_id != ^agent.id),
                   lock: "FOR UPDATE",
                   limit: 100
               )
               |> Enum.each(fn row ->
                 row
                 |> Delegation.hydrate()
                 |> Delegation.changeset(%{agent_id: agent.id})
                 |> Repo.update!()
               end)
             end) do
        Outbox.publish_pending(user_id)
        {:ok, agent}
      end
    else
      retire_idle(user_id, Keyword.get(opts, :job))
    end
  end

  defp retire_idle(user_id, %BackgroundJob{} = job) do
    agent_id =
      Repo.one(
        from a in idle_coordinators(DatabaseClock.now!()),
          where: a.user_id == ^user_id,
          order_by: a.inserted_at,
          limit: 1,
          select: a.id
      )

    if agent_id,
      do: Runtime.retire_delegation_coordinator(agent_id, job),
      else: {:ok, :no_live_conversations}
  end

  defp retire_idle(_, _), do: {:ok, :no_live_conversations}

  defp consent(user_id) do
    %{
      "actor_id" => user_id,
      "user_id" => user_id,
      "identity_key" => "delegations:#{Ecto.UUID.generate()}",
      "credential_refs" => %{},
      "connector_scope" => %{},
      "memory_scope" => %{},
      "tool_policy" => %{"allowed_tools" => []},
      "routing_bindings" => %{},
      "metadata" => %{"authority" => "versioned_delegation_grants"}
    }
  end
end
