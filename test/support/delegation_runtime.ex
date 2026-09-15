defmodule Maraithon.TestSupport.DelegationRuntime do
  @moduledoc false
  import ExUnit.Assertions
  import ExUnit.Callbacks
  alias Maraithon.Repo

  def run_leased_job(node, partitions, type, fun) do
    alias Maraithon.Runtime.{BackgroundJob, JobAuthority}
    alias Maraithon.Runtime.Coordination.{FairScheduler, TaskClaims, TaskSupervisor}
    job = Repo.get_by!(BackgroundJob, job_type: type) |> BackgroundJob.hydrate_payloads()
    queue = "delegation-eval:#{job.id}"

    job
    |> BackgroundJob.changeset(%{queue: queue, scheduled_at: DateTime.add(DateTime.utc_now(), -1)})
    |> Repo.update!()

    assert {:ok, {reserved, assignment, identity}} =
             FairScheduler.reserve_next(node, partitions, queues: [queue])

    gate = make_ref()

    task =
      Task.Supervisor.async_nolink(TaskSupervisor.task_supervisor(), fn ->
        receive do: ({:bound, ^gate} -> :ok)
        :ok = TaskSupervisor.register_current!(identity)
        {:ok, {job, assignment}} = FairScheduler.activate_job(reserved, assignment)
        {:ok, assignment} = TaskClaims.mark_provider_entered(assignment)
        result = fun.(job)

        assert {:ok, _} =
                 JobAuthority.transaction(job, fn ->
                   TaskClaims.settle_in_transaction(assignment, "completed")

                   job
                   |> BackgroundJob.changeset(%{status: "completed", result: elem(result, 1)})
                   |> Repo.update!()
                 end)

        result
      end)

    assert :ok = TaskSupervisor.bind_task(identity, task.pid)
    send(task.pid, {:bound, gate})
    result = Task.await(task, 10_000)
    assert {:ok, :completion} = TaskSupervisor.terminate_exact(identity)
    result
  end

  def exact_authority(user_id) do
    alias Maraithon.Runtime.Coordination.{Authority, Partitioning, Protocol}
    alias Maraithon.Effects.ProtocolCutover
    system = Maraithon.Runtime.TaskSystemSupervisor
    :ok = Supervisor.terminate_child(Maraithon.Runtime.Supervisor, system)
    start_supervised!(system)
    on_exit(fn -> Supervisor.restart_child(Maraithon.Runtime.Supervisor, system) end)

    evidence = [
      evidence_id: "local-eval:empty-runtime",
      evidence_digest: :crypto.hash(:sha256, "isolated SQL sandbox with no running tasks"),
      activated_by: "local-eval@example.invalid",
      revision: String.duplicate("a", 40)
    ]

    for table <- ~w(delegations delegation_grants) do
      assert {:ok, %{failures: []}} = Maraithon.DurablePayloadVerification.verify_batch(table)
    end

    Repo.query!("SET LOCAL ROLE maraithon_activation_operator", [], log: false)
    assert {:ok, _} = Protocol.attest_effect_activation_evidence(evidence)

    assert {:ok, _} =
             ProtocolCutover.activate(
               [confirmation: ProtocolCutover.activation_confirmation()] ++ evidence
             )

    assert {:ok, _} =
             Protocol.activate([confirmation: Protocol.activation_confirmation()] ++ evidence)

    Repo.query!("SET LOCAL ROLE maraithon_runtime", [], log: false)

    {:ok, node} =
      Authority.register_node(
        revision: String.duplicate("a", 40),
        node_name: "delegation-eval",
        ttl_ms: 300_000
      )

    {:ok, node} = Authority.mark_node_ready(node)
    {:ok, leader} = Authority.acquire_leader(node, 300_000)
    {:ok, leader} = Authority.mark_leader_ready(leader)
    id = Partitioning.partition_for("user:" <> user_id)
    {:ok, _} = Authority.assign_partition(leader, node, id, ttl_ms: 300_000)
    {:ok, partition} = Authority.mark_partition_ready(node, id)
    {node, [partition]}
  end
end
