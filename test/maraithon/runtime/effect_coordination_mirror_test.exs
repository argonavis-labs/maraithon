defmodule Maraithon.Runtime.EffectCoordinationMirrorTest do
  use Maraithon.DataCase, async: false

  alias Maraithon.Accounts
  alias Maraithon.AgentIsolation
  alias Maraithon.Agents
  alias Maraithon.Effects.Effect
  alias Maraithon.Effects.ProtocolCutover
  alias Maraithon.Runtime.AgentRuntimeLease
  alias Maraithon.Runtime.BootGate
  alias Maraithon.Runtime.Coordination.Authority
  alias Maraithon.Runtime.Coordination.Partitioning
  alias Maraithon.Runtime.Coordination.Protocol
  alias Maraithon.Runtime.Coordination.Session
  alias Maraithon.Runtime.Coordination.TaskClaims
  alias Maraithon.Runtime.DatabaseClock
  alias Maraithon.Runtime.EffectRunner
  alias Maraithon.Runtime.Effects.LLMRateLimiter

  @revision "abcdef0"
  @evidence_id "fly:machines-destroyed:effect-coordination-test"
  @activated_by "operator@example.test"
  @evidence_digest Base.encode16(:crypto.hash(:sha256, "effect-coordination-test-evidence"))

  defmodule BoundaryProvider do
    @moduledoc false

    def complete(params) do
      test_pid = Application.fetch_env!(:maraithon, :effect_coordination_test_pid)
      mode = Application.fetch_env!(:maraithon, :effect_coordination_provider_mode)
      send(test_pid, {:coordination_provider_entered, self(), params})

      case mode do
        :success ->
          receive do
            :release ->
              {:ok,
               %{
                 content: "coordinated",
                 model: "coordination-test-v1",
                 tokens_in: 1,
                 tokens_out: 1,
                 finish_reason: "stop",
                 usage: %{}
               }}
          end

        :crash ->
          Process.exit(self(), :kill)
      end
    end
  end

  setup do
    context = active_effect_authority!()
    configure_provider!(:success)
    BootGate.open()
    LLMRateLimiter.reset()
    {:ok, context}
  end

  test "the final entry transaction is durable before blocking provider invocation",
       context do
    effect = insert_pending_effect!(context, "completion")
    runner = start_runner!()
    send(runner, :poll)

    assert_receive {:coordination_provider_entered, worker, _params}, 2_000

    claimed = Repo.get!(Effect, effect.id)
    assert claimed.status == "executing"
    assert is_binary(claimed.coordination_task_assignment_id)

    entered = TaskClaims.get(claimed.coordination_task_assignment_id)
    assert entered.state == "running"
    assert entered.provider_boundary == "entered"
    assert outcome_evidence_count(entered.id) == 0

    worker_ref = Process.monitor(worker)
    send(worker, :release)
    assert_receive {:DOWN, ^worker_ref, :process, ^worker, :normal}, 2_000

    _ = :sys.get_state(runner)
    completed = Repo.get!(Effect, effect.id)
    settled = TaskClaims.get(claimed.coordination_task_assignment_id)

    assert completed.status == "completed"
    assert settled.state == "settled"

    assert completed.result["content"] == "coordinated"
    assert settled.provider_boundary == "outcome_known"
    assert settled.outcome == "completed"
    assert outcome_evidence_count(settled.id) == 1
    assert [["completed"]] = outcome_evidence(settled.id)
  end

  test "deterministic command preflight refusals never enter the provider boundary", context do
    runner = start_runner!()

    refusals = [
      {"unknown-command",
       %{
         effect_type: "unknown_effect_type",
         params: %{"__maraithon_effect_protocol" => 2}
       }},
      {"invalid-llm-request",
       %{
         params: %{
           "__maraithon_effect_protocol" => 2,
           "messages" => "not-a-message-list"
         }
       }},
      {"unknown-tool",
       %{
         effect_type: "tool_call",
         params: %{
           "__maraithon_effect_protocol" => 2,
           "tool" => "definitely_not_a_registered_tool",
           "args" => %{}
         }
       }},
      {"policy-refusal",
       %{
         effect_type: "tool_call",
         params: %{
           "__maraithon_effect_protocol" => 2,
           "tool" => "gmail_send_message",
           "args" => %{
             "to" => "recipient@example.test",
             "subject" => "must not send",
             "body" => "preflight must refuse this unconfirmed action"
           }
         }
       }}
    ]

    Enum.each(refusals, fn {suffix, overrides} ->
      effect = insert_pending_effect!(context, suffix, overrides)
      send(runner, :poll)

      {failed, settled} =
        after_runner_barrier(runner, fn ->
          stored = Repo.get!(Effect, effect.id)

          assignment =
            if stored.coordination_task_assignment_id,
              do: TaskClaims.get(stored.coordination_task_assignment_id)

          if stored.status == "failed" and match?(%{state: "settled"}, assignment),
            do: {:ok, {stored, assignment}},
            else: :retry
        end)

      assert failed.status == "failed"
      assert settled.provider_boundary == "not_entered"
      assert settled.outcome == "cancelled_before_provider"
      assert outcome_evidence_count(settled.id) == 0
      assert termination_proof_count(settled.id) == 0
      refute_receive {:coordination_provider_entered, _worker, _params}, 10
    end)
  end

  test "a crash before physical binding requeues with cancelled-before-provider evidence",
       context do
    effect = insert_pending_effect!(context, "before-entry-crash")
    test_pid = self()

    starter = fn _claimed, _writer, _sleeper ->
      Task.Supervisor.async_nolink(Maraithon.Runtime.ExactEffectTaskSupervisor, fn ->
        send(test_pid, {:before_entry_task_started, self()})

        receive do
          :release_before_entry_crash -> exit(:before_provider_entry)
        end
      end)
    end

    runner = start_runner!(task_starter: starter)
    send(runner, :poll)
    assert_receive {:before_entry_task_started, worker}, 2_000

    claimed = Repo.get!(Effect, effect.id)
    assignment_id = claimed.coordination_task_assignment_id
    assert claimed.status == "claimed"
    assert TaskClaims.get(assignment_id).state == "reserved"

    worker_ref = Process.monitor(worker)
    send(worker, :release_before_entry_crash)
    assert_receive {:DOWN, ^worker_ref, :process, ^worker, :before_provider_entry}, 2_000

    {pending, settled} =
      after_runner_barrier(runner, fn ->
        stored = Repo.get!(Effect, effect.id)
        assignment = TaskClaims.get(assignment_id)

        if stored.status == "pending" and match?(%{state: "settled"}, assignment),
          do: {:ok, {stored, assignment}},
          else: :retry
      end)

    assert is_nil(pending.claim_token)
    assert is_nil(pending.coordination_task_assignment_id)
    assert is_nil(pending.cancellation_state)
    assert settled.provider_boundary == "not_entered"
    assert settled.outcome == "cancelled_before_provider"
    assert outcome_evidence_count(settled.id) == 0
    assert termination_proof_count(settled.id) == 1
  end

  test "a crash after the entry commit remains provider-outcome ambiguous", context do
    configure_provider!(:crash)
    effect = insert_pending_effect!(context, "entered-crash")
    runner = start_runner!()
    send(runner, :poll)

    assert_receive {:coordination_provider_entered, _worker, _params}, 2_000

    {failed, ambiguous} =
      after_runner_barrier(runner, fn ->
        stored = Repo.get!(Effect, effect.id)

        assignment =
          if stored.coordination_task_assignment_id,
            do: TaskClaims.get(stored.coordination_task_assignment_id)

        if stored.status == "failed" and match?(%{state: "outcome_ambiguous"}, assignment),
          do: {:ok, {stored, assignment}},
          else: :retry
      end)

    assert failed.error == "effect_outcome_ambiguous"
    assert failed.cancellation_state == "settled"
    assert ambiguous.provider_boundary == "outcome_unknown"
    assert ambiguous.outcome == "provider_outcome_ambiguous"
    assert outcome_evidence_count(ambiguous.id) == 0
    assert termination_proof_count(ambiguous.id) == 1
  end

  defp active_effect_authority! do
    assert {:ok, :activated} =
             ProtocolCutover.activate(confirmation: ProtocolCutover.activation_confirmation())

    assert {:ok, :attested} =
             as_activation_operator(fn ->
               Protocol.attest_effect_activation_evidence(
                 Keyword.delete(coordination_activation_opts(), :confirmation)
               )
             end)

    Repo.query!(
      "ALTER TABLE public.background_jobs VALIDATE CONSTRAINT background_jobs_partition_shape",
      []
    )

    Repo.query!(
      "ALTER TABLE public.scheduled_jobs VALIDATE CONSTRAINT scheduled_jobs_partition_shape",
      []
    )

    assert {:ok, :activated} = Protocol.activate(coordination_activation_opts())

    user_id = "coord-effect-#{System.unique_integer([:positive])}@example.test"
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

    {:ok, agent} =
      Agents.create_agent(%{
        user_id: user_id,
        behavior: "prompt_agent",
        status: "running",
        started_at: DateTime.utc_now(),
        config: %{"name" => "coord-effect", "prompt" => "test", "subscribe" => [], "tools" => []}
      })

    {:ok, _binding} = AgentIsolation.grant_binding_consent(agent, binding_consent(agent))

    node =
      Authority.register_node(
        revision: @revision,
        node_name: "coord-effect-test",
        ttl_ms: 300_000
      )
      |> ok!()
      |> Authority.mark_node_ready()
      |> ok!()

    leader =
      Authority.acquire_leader(node, 300_000)
      |> ok!()
      |> Authority.mark_leader_ready()
      |> ok!()

    partition_id = Partitioning.partition_for("user:" <> user_id)

    partition =
      Authority.assign_partition(leader, node, partition_id, ttl_ms: 300_000)
      |> ok!()

    partition = Authority.mark_partition_ready(node, partition.partition_id) |> ok!()

    old_runtime = Application.get_env(:maraithon, Maraithon.Runtime, [])
    on_exit(fn -> Application.put_env(:maraithon, Maraithon.Runtime, old_runtime) end)

    session =
      start_supervised!({Session, tick_ms: 600_000, required_workers: []})

    _ = :sys.get_state(session)

    Application.put_env(
      :maraithon,
      Maraithon.Runtime,
      Keyword.put(old_runtime, :multinode_coordination_enabled, true)
    )

    :sys.replace_state(session, fn state ->
      %{state | phase: :ready, session: node, leader: leader}
    end)

    now = DatabaseClock.now!()
    owner_generation = Ecto.UUID.generate()

    %AgentRuntimeLease{}
    |> AgentRuntimeLease.changeset(%{
      agent_id: agent.id,
      owner_token: owner_generation,
      owner_node: Atom.to_string(node()),
      claimed_at: now,
      renewed_at: now,
      ready_at: now,
      lease_until: DateTime.add(now, 300, :second),
      coordination_activation_epoch: node.activation_epoch,
      coordination_partition_id: partition.partition_id,
      coordination_partition_epoch: partition.ownership_epoch,
      coordination_node_incarnation_id: node.id
    })
    |> Repo.insert!()

    %{
      agent: agent,
      owner_generation: owner_generation,
      node: node,
      partition: partition
    }
  end

  defp insert_pending_effect!(context, suffix, overrides \\ %{}) do
    attrs =
      %{
        id: Ecto.UUID.generate(),
        agent_id: context.agent.id,
        owner_user_id: context.agent.user_id,
        idempotency_key: Ecto.UUID.generate(),
        effect_type: "llm_call",
        params: %{
          "__maraithon_effect_protocol" => 2,
          "model" => "coordination-test-v1",
          "messages" => [%{"role" => "user", "content" => suffix}]
        },
        status: "pending",
        runtime_owner_generation: context.owner_generation,
        attempts: 0,
        max_attempts: 3,
        coordination_activation_epoch: context.node.activation_epoch,
        coordination_partition_id: context.partition.partition_id,
        coordination_partition_epoch: context.partition.ownership_epoch,
        coordination_node_incarnation_id: context.node.id
      }
      |> Map.merge(overrides)

    {:ok, effect} =
      Repo.transaction(fn ->
        ProtocolCutover.require_exact_write!()
        %Effect{} |> Effect.protocol_changeset(attrs) |> Repo.insert!()
      end)

    effect
  end

  defp start_runner!(opts \\ []) do
    runner = start_supervised!({EffectRunner, opts})
    Ecto.Adapters.SQL.Sandbox.allow(Repo, self(), runner)
    runner
  end

  defp configure_provider!(mode) do
    old_runtime = Application.get_env(:maraithon, Maraithon.Runtime, [])
    old_pid = Application.get_env(:maraithon, :effect_coordination_test_pid)
    old_mode = Application.get_env(:maraithon, :effect_coordination_provider_mode)

    Application.put_env(
      :maraithon,
      Maraithon.Runtime,
      Keyword.put(old_runtime, :llm_provider, BoundaryProvider)
    )

    Application.put_env(:maraithon, :effect_coordination_test_pid, self())
    Application.put_env(:maraithon, :effect_coordination_provider_mode, mode)

    on_exit(fn ->
      Application.put_env(:maraithon, Maraithon.Runtime, old_runtime)
      restore_env(:effect_coordination_test_pid, old_pid)
      restore_env(:effect_coordination_provider_mode, old_mode)
      LLMRateLimiter.reset()
    end)
  end

  defp outcome_evidence(assignment_id) do
    Repo.query!(
      "SELECT outcome FROM runtime_task_outcome_evidence WHERE assignment_id = $1::uuid",
      [Ecto.UUID.dump!(assignment_id)]
    ).rows
  end

  defp outcome_evidence_count(assignment_id), do: length(outcome_evidence(assignment_id))

  defp termination_proof_count(assignment_id) do
    Repo.query!(
      "SELECT count(*) FROM runtime_task_termination_proofs WHERE assignment_id = $1::uuid",
      [Ecto.UUID.dump!(assignment_id)]
    ).rows
    |> then(fn [[count]] -> count end)
  end

  defp after_runner_barrier(runner, fun, attempts \\ 100)
  defp after_runner_barrier(_runner, _fun, 0), do: flunk("condition did not become durable")

  defp after_runner_barrier(runner, fun, attempts) do
    _ = :sys.get_state(runner)

    case fun.() do
      {:ok, value} -> value
      :retry -> after_runner_barrier(runner, fun, attempts - 1)
    end
  end

  defp as_activation_operator(fun) do
    Repo.query!("SET ROLE maraithon_activation_operator", [])

    try do
      fun.()
    after
      Repo.query!("RESET ROLE", [])
    end
  end

  defp coordination_activation_opts do
    [
      confirmation: Protocol.activation_confirmation(),
      evidence_id: @evidence_id,
      evidence_digest: @evidence_digest,
      activated_by: @activated_by,
      exact_revision: @revision
    ]
  end

  defp restore_env(key, nil), do: Application.delete_env(:maraithon, key)
  defp restore_env(key, value), do: Application.put_env(:maraithon, key, value)
  defp ok!({:ok, value}), do: value
end
