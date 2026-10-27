defmodule Maraithon.Runtime.AgentLifecycleConcurrencyTest do
  use ExUnit.Case, async: false

  import Ecto.Query

  alias Ecto.Adapters.SQL.Sandbox
  alias Maraithon.Accounts
  alias Maraithon.Accounts.User
  alias Maraithon.AgentIsolation
  alias Maraithon.AgentIsolation.Binding
  alias Maraithon.AgentSubscriptions
  alias Maraithon.AgentSubscriptions.AgentSubscription
  alias Maraithon.Agents
  alias Maraithon.Agents.Agent
  alias Maraithon.Agents.AgentRun
  alias Maraithon.Agents.AgentRunStep
  alias Maraithon.Repo
  alias Maraithon.Runtime.AgentLifecycleOperation
  alias Maraithon.Runtime.AgentLifecycleOperations
  alias Maraithon.Runtime.AgentLeases
  alias Maraithon.Runtime.AgentRuntimeLease
  alias Maraithon.Runtime.ScheduledJob

  setup do
    agent =
      unboxed(fn ->
        user_id = "lifecycle-race-#{System.unique_integer([:positive])}@example.com"
        {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

        {:ok, agent} =
          Agents.create_agent(%{
            user_id: user_id,
            behavior: "prompt_agent",
            install_status: "enabled",
            status: "running",
            config: %{"revision" => "old"}
          })

        {:ok, _binding} =
          AgentIsolation.grant_binding_consent(
            agent,
            Maraithon.DataCase.binding_consent(agent)
          )

        agent
      end)

    on_exit(fn ->
      unboxed_with_trigger_bypass(fn ->
        Repo.delete_all(from(lease in AgentRuntimeLease, where: lease.agent_id == ^agent.id))

        Repo.delete_all(
          from(operation in AgentLifecycleOperation, where: operation.agent_id == ^agent.id)
        )

        Repo.delete_all(from(step in AgentRunStep, where: step.agent_id == ^agent.id))
        Repo.delete_all(from(run in AgentRun, where: run.agent_id == ^agent.id))
        Repo.delete_all(from(job in ScheduledJob, where: job.agent_id == ^agent.id))
        Repo.delete_all(from(stored in Agent, where: stored.id == ^agent.id))
        Repo.delete_all(from(user in User, where: user.id == ^agent.user_id))
      end)
    end)

    %{agent: agent}
  end

  test "physical start/stop/delete contenders cannot cross an update marker", %{agent: agent} do
    parent = self()
    request = %{"params" => %{"config" => %{"revision" => "new"}}}

    update =
      Task.async(fn ->
        unboxed(fn ->
          AgentLifecycleOperations.begin(agent.id, :update, request, fn locked ->
            send(parent, {:update_prefix_locked, self()})
            receive do: (:release_update_prefix -> :ok)

            %{
              "action" => "update",
              "attrs" => %{
                "behavior" => locked.behavior,
                "config" => Map.put(locked.config || %{}, "revision", "new")
              }
            }
          end)
        end)
      end)

    assert_receive {:update_prefix_locked, update_pid}, 5_000

    start = Task.async(fn -> unboxed(fn -> Agents.claim_agent_start(agent.id) end) end)

    stop =
      Task.async(fn ->
        unboxed(fn ->
          AgentLifecycleOperations.begin(
            agent.id,
            :stop,
            %{"reason" => "concurrent_stop"},
            fn _locked -> %{"action" => "stop"} end
          )
        end)
      end)

    delete =
      Task.async(fn ->
        unboxed(fn ->
          AgentLifecycleOperations.begin(
            agent.id,
            :delete,
            %{"delete" => true},
            fn _locked -> %{"action" => "delete"} end
          )
        end)
      end)

    send(update_pid, :release_update_prefix)
    assert {:ok, fence} = Task.await(update)
    assert {:error, :agent_drain_pending} = Task.await(start)
    assert {:error, :agent_drain_pending} = Task.await(stop)
    assert {:error, :agent_drain_pending} = Task.await(delete)

    assert {:ok, %{status: :finalized, agent: updated}} =
             unboxed(fn ->
               AgentLifecycleOperations.finalize(agent.id, fence.operation_token)
             end)

    assert updated.status == "running"
    assert updated.config["revision"] == "new"

    assert {:ok, successor} = unboxed(fn -> AgentLeases.claim(agent.id) end)
    assert unboxed(fn -> Agents.get_agent(agent.id).config["revision"] end) == "new"

    assert {:error, :termination_proof_required} =
             unboxed(fn -> AgentLeases.release(agent.id, successor.owner_token) end)
  end

  test "a successor claim and schedule occur only after old schedules are cancelled", %{
    agent: agent
  } do
    old_job = unboxed(fn -> scheduled_job(agent.id, "old") end)

    assert {:ok, fence} =
             unboxed(fn ->
               AgentLifecycleOperations.begin(
                 agent.id,
                 :update,
                 %{"params" => %{"config" => %{"revision" => "new"}}},
                 fn locked ->
                   %{
                     "action" => "update",
                     "attrs" => %{
                       "behavior" => locked.behavior,
                       "config" => Map.put(locked.config || %{}, "revision", "new")
                     }
                   }
                 end
               )
             end)

    parent = self()

    blocker =
      Task.async(fn ->
        unboxed(fn ->
          Repo.transaction(fn ->
            _locked =
              Repo.one!(
                from(job in ScheduledJob, where: job.id == ^old_job.id, lock: "FOR UPDATE")
              )

            send(parent, {:old_schedule_locked, self()})
            receive do: (:release_old_schedule -> :ok)
          end)
        end)
      end)

    assert_receive {:old_schedule_locked, blocker_pid}, 5_000

    finalizer =
      Task.async(fn ->
        unboxed(fn -> AgentLifecycleOperations.finalize(agent.id, fence.operation_token) end)
      end)

    assert_finalizer_holds_agent_lock(agent.id, 50)

    successor =
      Task.async(fn ->
        unboxed(fn ->
          with {:ok, lease} <- AgentLeases.claim(agent.id) do
            new_job = scheduled_job(agent.id, "successor")
            {:ok, lease, new_job}
          end
        end)
      end)

    send(blocker_pid, :release_old_schedule)
    assert {:ok, :ok} = Task.await(blocker)
    assert {:ok, %{status: :finalized}} = Task.await(finalizer)
    assert {:ok, lease, new_job} = Task.await(successor)

    assert unboxed(fn -> Repo.reload!(old_job).status end) == "cancelled"
    assert unboxed(fn -> Repo.reload!(new_job).status end) == "pending"
    assert unboxed(fn -> Agents.get_agent(agent.id).config["revision"] end) == "new"

    assert {:error, :termination_proof_required} =
             unboxed(fn -> AgentLeases.release(agent.id, lease.owner_token) end)
  end

  test "new RunStep admission queues behind finalization and rejects the cancelled Run", %{
    agent: agent
  } do
    assert {:ok, run} = unboxed(fn -> Agents.start_agent_run(agent) end)

    request = %{"params" => %{"config" => %{"revision" => "step-fenced"}}}

    assert {:ok, fence} =
             unboxed(fn ->
               AgentLifecycleOperations.begin(agent.id, :update, request, fn locked ->
                 %{
                   "action" => "update",
                   "attrs" => %{
                     "behavior" => locked.behavior,
                     "config" => Map.put(locked.config || %{}, "revision", "step-fenced")
                   }
                 }
               end)
             end)

    parent = self()

    run_blocker =
      Task.async(fn ->
        unboxed(fn ->
          Repo.transaction(fn ->
            _locked =
              Repo.one!(from(stored in AgentRun, where: stored.id == ^run.id, lock: "FOR UPDATE"))

            send(parent, {:run_locked, self()})
            receive do: (:release_run -> :ok)
          end)
        end)
      end)

    assert_receive {:run_locked, blocker_pid}, 5_000

    finalizer =
      Task.async(fn ->
        unboxed(fn -> AgentLifecycleOperations.finalize(agent.id, fence.operation_token) end)
      end)

    assert_finalizer_holds_agent_lock(agent.id, 50)

    step_admission =
      Task.async(fn ->
        unboxed(fn ->
          Agents.record_agent_run_step(run.id, agent.id, %{step_type: "tool_call"})
        end)
      end)

    assert Task.yield(step_admission, 50) == nil
    send(blocker_pid, :release_run)

    assert {:ok, :ok} = Task.await(run_blocker, 5_000)

    assert {:ok, %{status: :finalized}} = Task.await(finalizer, 5_000)

    assert {:error, {:run_not_running, "cancelled"}} =
             Task.await(step_admission, 5_000)

    assert unboxed(fn ->
             Repo.aggregate(
               from(step in AgentRunStep, where: step.agent_run_id == ^run.id),
               :count
             )
           end) == 0
  end

  test "subscription sync cannot resurrect delivery after concurrent consent revocation", %{
    agent: agent
  } do
    topic = "consent-race:#{agent.id}"

    assert {:ok, updated} =
             unboxed(fn ->
               agent.id
               |> Agents.get_agent()
               |> Agents.update_agent(%{config: %{"subscribe" => [topic]}})
             end)

    subscription =
      unboxed(fn -> Repo.get_by!(AgentSubscription, agent_id: agent.id, topic: topic) end)

    assert subscription.status == "active"
    parent = self()

    blocker =
      Task.async(fn ->
        unboxed(fn ->
          Repo.transaction(fn ->
            _locked =
              Repo.one!(
                from(stored in AgentSubscription,
                  where: stored.id == ^subscription.id,
                  lock: "FOR UPDATE"
                )
              )

            send(parent, {:subscription_locked, self()})
            receive do: (:release_subscription -> :ok)
          end)
        end)
      end)

    assert_receive {:subscription_locked, blocker_pid}, 5_000

    sync =
      Task.async(fn ->
        unboxed(fn -> AgentSubscriptions.sync_for_agent(updated) end)
      end)

    assert_finalizer_holds_agent_lock(agent.id, 50)

    revoke =
      Task.async(fn ->
        unboxed(fn -> AgentIsolation.upsert_binding(agent, %{status: "revoked"}) end)
      end)

    assert Task.yield(revoke, 50) == nil
    send(blocker_pid, :release_subscription)

    assert {:ok, :ok} = Task.await(blocker, 5_000)
    assert {:ok, _subscriptions} = Task.await(sync, 5_000)
    assert {:ok, %Binding{status: "revoked"}} = Task.await(revoke, 5_000)

    assert unboxed(fn -> Repo.reload!(subscription).status end) == "inactive"
    assert unboxed(fn -> AgentSubscriptions.list_topics_for_agent(agent.id) end) == []
  end

  defp assert_finalizer_holds_agent_lock(_agent_id, 0),
    do: flunk("finalizer did not acquire the Agent lock")

  defp assert_finalizer_holds_agent_lock(agent_id, attempts) do
    case unboxed(fn ->
           Repo.query!("SET lock_timeout TO '25ms'")

           try do
             Repo.one(from(agent in Agent, where: agent.id == ^agent_id, lock: "FOR UPDATE"))
             :not_locked
           rescue
             error in Postgrex.Error -> {:locked, error}
           after
             Repo.query!("SET lock_timeout TO 0")
           end
         end) do
      {:locked, %Postgrex.Error{postgres: %{code: :lock_not_available}}} ->
        :ok

      :not_locked ->
        assert_finalizer_holds_agent_lock(agent_id, attempts - 1)
    end
  end

  defp scheduled_job(agent_id, generation) do
    %ScheduledJob{}
    |> ScheduledJob.changeset(%{
      agent_id: agent_id,
      job_type: "checkpoint",
      fire_at: DateTime.add(DateTime.utc_now(), 60, :second),
      payload: %{"generation" => generation},
      status: "pending"
    })
    |> Repo.insert!()
  end

  defp unboxed(fun) do
    Sandbox.unboxed_run(Repo, fn ->
      Repo.query!("SET ROLE maraithon_runtime", [], log: false)

      try do
        fun.()
      after
        Repo.query!("RESET ROLE", [], log: false)
      end
    end)
  end

  defp unboxed_with_trigger_bypass(fun) do
    Sandbox.unboxed_run(Repo, fn ->
      Repo.query!("RESET ROLE", [], log: false)

      try do
        Repo.transaction(fn ->
          Repo.query!("SET LOCAL session_replication_role = replica", [], log: false)
          fun.()
        end)
      after
        Repo.query!("RESET ROLE", [], log: false)
      end
    end)
  end
end
