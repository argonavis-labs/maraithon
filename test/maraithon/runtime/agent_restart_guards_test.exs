defmodule Maraithon.Runtime.AgentRestartGuardsTest do
  use Maraithon.DataCase, async: true

  alias Maraithon.Accounts
  alias Maraithon.AgentIsolation
  alias Maraithon.Agents
  alias Maraithon.Agents.Agent
  alias Maraithon.Repo
  alias Maraithon.Runtime.AgentLeases
  alias Maraithon.Runtime.AgentRegistry
  alias Maraithon.Runtime.AgentRestartGuard
  alias Maraithon.Runtime.AgentRestartGuards
  alias Maraithon.Runtime.AgentRuntimeLease
  alias Maraithon.Runtime.AgentTerminations
  alias Maraithon.Runtime.AgentWatcher

  setup do
    user_id = "restart-guard-#{System.unique_integer([:positive])}@example.com"
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

    {:ok, agent} =
      Agents.create_agent(%{
        user_id: user_id,
        behavior: "prompt_agent",
        config: %{},
        install_status: "enabled",
        status: "running"
      })

    {:ok, _binding} = AgentIsolation.grant_binding_consent(agent, binding_consent(agent))
    %{agent: agent}
  end

  test "records the exact owner before release and duplicate DOWN is idempotent", %{agent: agent} do
    {lease, watcher} = claim_with_watcher(agent.id, backoffs_ms: [0])

    assert {guard, down} = prove_owner_down(agent.id, lease, watcher)

    assert guard.last_owner_token == lease.owner_token
    assert guard.crash_count == 1
    assert guard.needs_recovery
    refute guard.tripped
    assert Repo.get(AgentRuntimeLease, agent.id) == nil

    send(down.watcher, {:DOWN, down.monitor_ref, :process, down.pid, down.reason})
    _ = :sys.get_state(down.watcher)

    duplicate = Repo.get!(AgentRestartGuard, agent.id)
    assert duplicate.agent_id == guard.agent_id
    assert duplicate.crash_count == 1
    assert duplicate.generation == guard.generation

    incident = AgentTerminations.get_by_lease(lease.owner_token)
    assert incident.request_count == 1
    assert AgentTerminations.proof_for(incident.id).local_pid == inspect(down.pid)
  end

  test "expired ownership stays fenced until exact DOWN is recorded", %{agent: agent} do
    {lease, watcher} = claim_with_watcher(agent.id, backoffs_ms: [0])

    assert {:ignored, :lease_renewed} =
             AgentRestartGuards.record_expired(agent.id, lease.owner_token, backoffs_ms: [0])

    assert AgentLeases.owner?(agent.id, lease.owner_token)
    expire_lease!(agent.id)

    assert {:requested, incident} =
             AgentRestartGuards.record_expired(agent.id, lease.owner_token, backoffs_ms: [0])

    assert incident.status == "requested"
    assert Repo.get!(AgentRuntimeLease, agent.id).owner_token == lease.owner_token
    assert AgentRestartGuards.get(agent.id) == nil
    assert AgentTerminations.proof_for(incident.id) == nil

    assert {guard, _down} = prove_owner_down(agent.id, lease, watcher)

    assert guard.last_owner_token == lease.owner_token
    assert guard.needs_recovery
    assert Repo.get(AgentRuntimeLease, agent.id) == nil
    assert AgentTerminations.get(incident.id).status == "reconciled"
  end

  test "an old delayed DOWN cannot penalize or delete a replacement generation", %{agent: agent} do
    {old_lease, watcher} = claim_with_watcher(agent.id, backoffs_ms: [0])

    assert {first_guard, old_down} = prove_owner_down(agent.id, old_lease, watcher)

    assert {:ok, replacement} =
             AgentLeases.claim_recovery(agent.id, first_guard.generation)

    send(
      old_down.watcher,
      {:DOWN, old_down.monitor_ref, :process, old_down.pid, old_down.reason}
    )

    _ = :sys.get_state(old_down.watcher)
    persisted = Repo.get!(AgentRestartGuard, agent.id)
    assert persisted.crash_count == 1
    assert persisted.generation == first_guard.generation
    assert Repo.get!(AgentRuntimeLease, agent.id).owner_token == replacement.owner_token

    assert {:ok, ready} =
             AgentLeases.finish_recovery(
               agent.id,
               replacement.owner_token,
               first_guard.generation
             )

    assert ready.ready_at != nil
    assert AgentLeases.ready?(agent.id, replacement.owner_token)
    refute Repo.get!(AgentRestartGuard, agent.id).needs_recovery
  end

  test "recovery requires the exact due generation", %{agent: agent} do
    {lease, watcher} = claim_with_watcher(agent.id, backoffs_ms: [1_000])

    assert {guard, _down} = prove_owner_down(agent.id, lease, watcher)

    assert {:error, :stale_recovery_generation} =
             AgentLeases.claim_recovery(agent.id, Ecto.UUID.generate())

    assert {:error, :agent_restart_backoff} =
             AgentLeases.claim_recovery(agent.id, guard.generation)

    make_guard_due!(agent.id)
    assert {:ok, recovery} = AgentLeases.claim_recovery(agent.id, guard.generation)

    assert {:error, :stale_recovery_generation} =
             AgentLeases.finish_recovery(
               agent.id,
               recovery.owner_token,
               Ecto.UUID.generate()
             )

    refute AgentLeases.ready?(agent.id, recovery.owner_token)
    assert {:error, :runtime_lease_owned} = AgentRestartGuards.reset_for_operator(agent.id)
    assert Repo.get!(AgentRestartGuard, agent.id).needs_recovery
  end

  test "crash-loop threshold trips durably and stops desired execution", %{agent: agent} do
    owner = record_and_recover!(agent, nil, 1)
    owner = record_and_recover!(agent, owner, 2)
    {lease, watcher} = owner

    assert {tripped, _down} = prove_owner_down(agent.id, lease, watcher)

    assert tripped.crash_count == 3
    assert tripped.tripped
    assert tripped.needs_recovery
    assert Repo.get!(Agent, agent.id).status == "stopped"
    assert Repo.get(AgentRuntimeLease, agent.id) == nil

    assert {:error, :agent_not_runnable} = AgentLeases.claim(agent.id)

    assert {:error, :agent_not_runnable} =
             AgentLeases.claim_recovery(agent.id, tripped.generation)

    assert {:ok, reset} = AgentRestartGuards.reset_for_operator(agent.id)
    refute reset.tripped
    refute reset.needs_recovery
    assert reset.crash_count == 0
    assert reset.window_started_at == nil
  end

  test "proof-less and direct crash reports cannot mutate an exact owner", %{agent: agent} do
    assert {:ok, lease} = AgentLeases.claim(agent.id)

    assert {:error, :invalid_restart_guard} =
             AgentRestartGuards.record_crash(agent.id, lease.owner_token, :forged, unknown: true)

    assert {:ignored, :termination_proof_required} =
             AgentRestartGuards.record_crash(agent.id, lease.owner_token, :proofless)

    assert {:ignored, :termination_proof_required} =
             AgentRestartGuards.record_crash(agent.id, Ecto.UUID.generate(), :proofless)

    forged_token = Ecto.UUID.generate()
    down = observed_down()

    assert {:error, :local_down_witness_required} =
             AgentTerminations.record_local_down(
               agent.id,
               forged_token,
               down.pid,
               down.reason,
               down.monitor_started_at
             )

    assert AgentLeases.owner?(agent.id, lease.owner_token)
    assert AgentRestartGuards.get(agent.id) == nil
    assert AgentTerminations.get_by_lease(forged_token) == nil
  end

  defp record_and_recover!(agent, nil, expected_count) do
    owner = claim_with_watcher(agent.id, backoffs_ms: [0], max_crashes: 3)
    record_and_recover!(agent, owner, expected_count)
  end

  defp record_and_recover!(agent, {lease, current_watcher}, expected_count) do
    {guard, _down} = prove_owner_down(agent.id, lease, current_watcher)

    assert guard.crash_count == expected_count
    recovery_watcher = watcher(backoffs_ms: [0], max_crashes: 3)

    {:ok, recovery} =
      AgentLeases.claim_recovery(agent.id, guard.generation, watcher: recovery_watcher)

    refute recovery.termination_capability_digest == lease.termination_capability_digest
    {:ok, _ready} = AgentLeases.finish_recovery(agent.id, recovery.owner_token, guard.generation)
    {recovery, recovery_watcher}
  end

  defp claim_with_watcher(agent_id, opts) do
    watcher = watcher(opts)
    {:ok, lease} = AgentLeases.claim(agent_id, watcher: watcher)
    {lease, watcher}
  end

  defp prove_owner_down(agent_id, lease, watcher) do
    owner_token = lease.owner_token
    pid = registered_owner(agent_id, owner_token)
    assert :ok = AgentWatcher.track(watcher, pid, agent_id, owner_token)
    monitor_ref = watcher |> :sys.get_state() |> Map.fetch!(:pids) |> Map.fetch!(pid)

    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}, 1_000

    guard =
      assert_eventually_value(fn ->
        _ = :sys.get_state(watcher)

        case AgentRestartGuards.get(agent_id) do
          %{last_owner_token: ^owner_token} = guard -> guard
          _other -> nil
        end
      end)

    incident = AgentTerminations.get_by_lease(owner_token)
    assert incident.status == "reconciled"
    assert AgentTerminations.proof_for(incident.id).local_pid == inspect(pid)

    {guard,
     %{
       watcher: watcher,
       monitor_ref: monitor_ref,
       pid: pid,
       reason: :killed
     }}
  end

  defp watcher(opts) do
    suffix = System.unique_integer([:positive])
    name = :"restart_guard_watcher_#{suffix}"

    watcher =
      start_supervised!(
        {AgentWatcher,
         name: name,
         reconcile?: false,
         recover?: false,
         crash_loop_max: Keyword.get(opts, :max_crashes, 3),
         crash_loop_window_ms: Keyword.get(opts, :window_ms, 600_000),
         reresume_backoffs: Keyword.get(opts, :backoffs_ms, [0]),
         down_retry_backoffs: [1],
         shutdown_down_barrier_ms: 0},
        id: name
      )

    :ok = Ecto.Adapters.SQL.Sandbox.allow(Repo, self(), watcher)
    watcher
  end

  defp registered_owner(agent_id, owner_token) do
    parent = self()

    pid =
      spawn(fn ->
        result = Registry.register(AgentRegistry, agent_id, owner_token)
        send(parent, {:owner_registered, self(), result})
        receive do: (:terminate -> :ok)
      end)

    assert_receive {:owner_registered, ^pid, {:ok, _owner}}, 1_000
    pid
  end

  defp observed_down do
    pid = spawn(fn -> receive do: (:terminate -> :ok) end)
    monitor_started_at = DateTime.utc_now()
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}, 1_000
    %{pid: pid, reason: :killed, monitor_started_at: monitor_started_at}
  end

  defp assert_eventually_value(fun, attempts \\ 100)

  defp assert_eventually_value(fun, attempts) when attempts > 0 do
    case fun.() do
      nil -> assert_eventually_value(fun, attempts - 1)
      false -> assert_eventually_value(fun, attempts - 1)
      value -> value
    end
  end

  defp assert_eventually_value(_fun, 0),
    do: flunk("value was not available before timeout")

  defp expire_lease!(agent_id) do
    # Expiry is a test-only clock fixture. Bypass the production ACL and lease
    # trigger explicitly, then restore the sandbox's runtime role.
    Repo.query!("SET LOCAL ROLE NONE", [], log: false)
    Repo.query!("SET LOCAL session_replication_role = replica", [], log: false)

    try do
      Repo.query!(
        """
        UPDATE agent_runtime_leases
        SET claimed_at = timezone('UTC', clock_timestamp()) - interval '3 minutes',
            renewed_at = timezone('UTC', clock_timestamp()) - interval '2 minutes',
            lease_until = timezone('UTC', clock_timestamp()) - interval '1 minute',
            ready_at = NULL,
            draining_at = NULL,
            updated_at = timezone('UTC', clock_timestamp())
        WHERE agent_id = $1::uuid
        """,
        [Ecto.UUID.dump!(agent_id)]
      )
    after
      Repo.query!("SET LOCAL session_replication_role = origin", [], log: false)
      Repo.query!("SET LOCAL ROLE maraithon_runtime", [], log: false)
    end
  end

  defp make_guard_due!(agent_id) do
    Repo.query!(
      """
      UPDATE agent_restart_guards
      SET blocked_until = timezone('UTC', clock_timestamp()) - interval '1 second'
      WHERE agent_id = $1::uuid
      """,
      [Ecto.UUID.dump!(agent_id)]
    )
  end
end
