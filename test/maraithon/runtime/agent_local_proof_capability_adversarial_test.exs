defmodule Maraithon.Runtime.AgentLocalProofCapabilityAdversarialTest do
  use Maraithon.DataCase, async: false

  alias Maraithon.Accounts
  alias Maraithon.AgentIsolation
  alias Maraithon.Agents
  alias Maraithon.Repo
  alias Maraithon.Runtime.AgentLeases
  alias Maraithon.Runtime.AgentRegistry
  alias Maraithon.Runtime.AgentSupervisor
  alias Maraithon.Runtime.AgentTerminationIncident
  alias Maraithon.Runtime.AgentTerminationProof
  alias Maraithon.Runtime.AgentTerminations
  alias Maraithon.Runtime.AgentWatcher

  test "runtime SQL cannot turn a readable lease digest into local DOWN authority" do
    reset_sql_context!()
    assert_runtime_role!()

    try do
      {:ok, agent} = running_agent("local-proof-target")
      {supervisor, watcher} = exact_runtime()

      {:ok, owner_pid} =
        AgentSupervisor.start_agent(agent,
          supervisor: supervisor,
          watcher: watcher,
          ttl_ms: 60_000,
          renew_interval_ms: 5_000
        )

      wait_for_idle(agent.id)
      [{^owner_pid, owner_token}] = Registry.lookup(AgentRegistry, agent.id)
      lease = AgentLeases.get(agent.id)
      assert lease.owner_token == owner_token

      {:ok, foreign_agent} = running_agent("local-proof-foreign")

      {:ok, foreign_lease} =
        AgentLeases.claim(foreign_agent.id, ttl_ms: 60_000, watcher: watcher)

      assert [[readable_digest]] =
               Repo.query!(
                 """
                 SELECT termination_capability_digest
                 FROM public.agent_runtime_leases
                 WHERE agent_id = $1::uuid AND owner_token = $2::uuid
                 """,
                 [Ecto.UUID.dump!(agent.id), Ecto.UUID.dump!(owner_token)],
                 log: false
               ).rows

      assert readable_digest == lease.termination_capability_digest
      assert byte_size(readable_digest) == 32
      refute readable_digest == foreign_lease.termination_capability_digest

      assert {:requested, incident} =
               AgentTerminations.request_ambiguous(
                 agent.id,
                 owner_token,
                 "adversarial_local_proof"
               )

      assert_exact_identity!(incident, lease)
      assert proof_count(incident.id) == 0

      # The trigger treats an absent and an empty custom GUC identically. The
      # exact incident marker is present for every attempt, so each rejection
      # below exercises capability or incident/lease identity rather than a
      # missing marker.
      assert_raw_local_down_rejected!(incident, "")
      assert_raw_local_down_rejected!(incident, "not-valid-base64")

      # The digest is readable by maraithon_runtime but is not a bearer secret:
      # feeding it back as the padded Base64 GUC hashes it a second time.
      assert_raw_local_down_rejected!(incident, Base.encode64(readable_digest))

      wrong_secret = :crypto.strong_rand_bytes(32)
      refute :crypto.hash(:sha256, wrong_secret) == readable_digest
      assert_raw_local_down_rejected!(incident, Base.encode64(wrong_secret))

      # A value read from another lease cannot cross the exact incident/lease
      # boundary, with either the target token or the foreign token in the row.
      foreign_digest_guc = Base.encode64(foreign_lease.termination_capability_digest)
      assert_raw_local_down_rejected!(incident, foreign_digest_guc)

      assert_raw_local_down_rejected!(incident, foreign_digest_guc,
        lease_token: foreign_lease.owner_token
      )

      assert_digest_mutation_rejected!(lease, foreign_lease.termination_capability_digest)
      assert AgentLeases.get(agent.id).termination_capability_digest == readable_digest
      assert_runtime_role!()

      Repo.query!("SET LOCAL log_parameter_max_length_on_error = -1", [], log: false)

      assert [["-1"]] =
               Repo.query!(
                 "SELECT current_setting('log_parameter_max_length_on_error')",
                 [],
                 log: false
               ).rows

      telemetry_handler = {:agent_local_proof_query_telemetry, make_ref()}

      :ok =
        :telemetry.attach(
          telemetry_handler,
          [:maraithon, :repo, :query],
          fn _event, _measurements, metadata, receiver ->
            send(receiver, {telemetry_handler, metadata})
          end,
          self()
        )

      on_exit(fn -> :telemetry.detach(telemetry_handler) end)

      owner_ref = Process.monitor(owner_pid)
      Process.exit(owner_pid, :kill)
      assert_receive {:DOWN, ^owner_ref, :process, ^owner_pid, :killed}, 1_000

      reconciled =
        assert_eventually_value(fn ->
          case Repo.get(AgentTerminationIncident, incident.id) do
            %AgentTerminationIncident{status: "reconciled"} = value -> value
            _other -> nil
          end
        end)

      query_metadata = drain_query_metadata(telemetry_handler)
      :ok = :telemetry.detach(telemetry_handler)

      assert [["0"]] =
               Repo.query!(
                 "SELECT current_setting('log_parameter_max_length_on_error')",
                 [],
                 log: false
               ).rows

      refute Enum.any?(query_metadata, fn metadata ->
               String.contains?(metadata.query, "agent_termination_capability")
             end)

      proof = Repo.get_by!(AgentTerminationProof, incident_id: incident.id)
      assert proof.proof_kind == "local_down"
      assert proof.agent_id == agent.id
      assert proof.lease_token == owner_token
      assert proof.local_pid == inspect(owner_pid)
      assert reconciled.proof_id == proof.id
      assert AgentLeases.get(agent.id) == nil
      assert proof_count(incident.id) == 1

      # Once the watcher-owned path has consumed the exact capability, raw SQL
      # cannot replay the incident even with the readable digest and exact row
      # identity. The BEFORE trigger must reject before uniqueness is relevant.
      assert_raw_local_down_rejected!(incident, Base.encode64(readable_digest))
      assert proof_count(incident.id) == 1
    after
      reset_sql_context!()
    end

    assert_runtime_role!()
  end

  test "a NULL external-proof-only lease can never authorize local DOWN" do
    reset_sql_context!()
    assert_runtime_role!()

    try do
      {:ok, agent} = running_agent("local-proof-external-only")
      assert {:ok, lease} = AgentLeases.claim(agent.id, ttl_ms: 60_000)
      assert lease.termination_capability_digest == nil

      assert {:requested, incident} =
               AgentTerminations.request_ambiguous(
                 agent.id,
                 lease.owner_token,
                 "external_only_local_proof_attempt"
               )

      assert_exact_identity!(incident, lease)
      assert_raw_local_down_rejected!(incident, Base.encode64(:crypto.strong_rand_bytes(32)))
      assert proof_count(incident.id) == 0
      assert AgentLeases.get(agent.id).owner_token == lease.owner_token
    after
      reset_sql_context!()
    end

    assert_runtime_role!()
  end

  defp assert_raw_local_down_rejected!(incident, capability_guc, opts \\ []) do
    lease_token = Keyword.get(opts, :lease_token, "")
    before_count = proof_count(incident.id)

    Repo.query!(
      "SELECT set_config('maraithon.agent_local_down_proof', $1, true)",
      [incident.id],
      log: false
    )

    Repo.query!(
      "SELECT set_config('maraithon.agent_termination_capability', $1, true)",
      [capability_guc],
      log: false
    )

    Repo.query!(
      "SELECT set_config('maraithon.test_agent_termination_lease_token', $1, true)",
      [lease_token],
      log: false
    )

    Repo.query!(
      """
      DO $raw_local_down$
      DECLARE
        rejected boolean := false;
      BEGIN
        BEGIN
          INSERT INTO public.agent_termination_proofs (
            id, incident_id, activation_epoch, node_incarnation_id,
            partition_id, partition_epoch, agent_id, lease_token, proof_kind,
            local_pid, monitor_started_at, down_reason, proved_by, proved_at,
            inserted_at, updated_at
          )
          SELECT
            gen_random_uuid(), incident.id, incident.activation_epoch,
            incident.node_incarnation_id, incident.partition_id,
            incident.partition_epoch, incident.agent_id,
            COALESCE(
              NULLIF(
                current_setting('maraithon.test_agent_termination_lease_token', true),
                ''
              )::uuid,
              incident.lease_token
            ),
            'local_down', '<forged-pid>', timezone('UTC', clock_timestamp()),
            'forged-local-down', 'raw-sql-adversary',
            timezone('UTC', clock_timestamp()),
            timezone('UTC', clock_timestamp()),
            timezone('UTC', clock_timestamp())
          FROM public.agent_termination_incidents AS incident
          WHERE incident.id =
            current_setting('maraithon.agent_local_down_proof', true)::uuid;
        EXCEPTION WHEN check_violation THEN
          rejected := true;
        END;

        IF NOT rejected THEN
          RAISE EXCEPTION 'raw local DOWN unexpectedly bypassed capability authority';
        END IF;
      END
      $raw_local_down$;
      """,
      [],
      log: false
    )

    assert proof_count(incident.id) == before_count
  end

  defp assert_digest_mutation_rejected!(lease, replacement_digest) do
    Repo.query!(
      "SELECT set_config('maraithon.test_agent_termination_target', $1, true)",
      [lease.agent_id],
      log: false
    )

    Repo.query!(
      "SELECT set_config('maraithon.test_agent_termination_digest', $1, true)",
      [Base.encode64(replacement_digest)],
      log: false
    )

    Repo.query!(
      """
      DO $raw_digest_mutation$
      DECLARE
        rejected boolean := false;
      BEGIN
        BEGIN
          UPDATE public.agent_runtime_leases
          SET termination_capability_digest = decode(
                current_setting('maraithon.test_agent_termination_digest', true),
                'base64'
              )
          WHERE agent_id =
            current_setting('maraithon.test_agent_termination_target', true)::uuid;
        EXCEPTION WHEN insufficient_privilege OR check_violation THEN
          rejected := true;
        END;

        IF NOT rejected THEN
          RAISE EXCEPTION 'runtime SQL unexpectedly mutated Agent capability digest';
        END IF;
      END
      $raw_digest_mutation$;
      """,
      [],
      log: false
    )
  end

  defp assert_exact_identity!(incident, lease) do
    assert incident.agent_id == lease.agent_id
    assert incident.lease_token == lease.owner_token
    assert incident.owner_node == lease.owner_node
    assert incident.activation_epoch == lease.coordination_activation_epoch
    assert incident.node_incarnation_id == lease.coordination_node_incarnation_id
    assert incident.partition_id == lease.coordination_partition_id
    assert incident.partition_epoch == lease.coordination_partition_epoch
  end

  defp proof_count(incident_id) do
    AgentTerminationProof
    |> where([proof], proof.incident_id == ^incident_id)
    |> Repo.aggregate(:count, :id)
  end

  defp running_agent(name) do
    user_id = "#{name}-#{System.unique_integer([:positive])}@example.com"
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

    with {:ok, agent} <-
           Agents.create_agent(%{
             user_id: user_id,
             behavior: "prompt_agent",
             status: "running",
             started_at: DateTime.utc_now(),
             config: %{"name" => name}
           }),
         {:ok, _binding} <- AgentIsolation.grant_binding_consent(agent, binding_consent(agent)) do
      {:ok, agent}
    end
  end

  defp exact_runtime do
    suffix = System.unique_integer([:positive])
    supervisor_name = :"agent_proof_adversarial_supervisor_#{suffix}"
    watcher_name = :"agent_proof_adversarial_watcher_#{suffix}"

    supervisor =
      start_supervised!(
        {DynamicSupervisor,
         strategy: :one_for_one, name: supervisor_name, max_restarts: 20, max_seconds: 60},
        id: supervisor_name
      )

    watcher =
      start_supervised!(
        {AgentWatcher,
         name: watcher_name,
         agent_supervisor: supervisor,
         reconcile?: false,
         recover?: false,
         poll_interval_ms: 10,
         crash_loop_max: 3,
         crash_loop_window_ms: 60_000,
         down_retry_backoffs: [10]},
        id: watcher_name
      )

    {supervisor, watcher}
  end

  defp wait_for_idle(agent_id) do
    assert_eventually_value(fn ->
      case Registry.lookup(AgentRegistry, agent_id) do
        [{pid, _owner_token}] ->
          try do
            if match?({:idle, _data}, :sys.get_state(pid)), do: true
          catch
            :exit, _reason -> nil
          end

        _other ->
          nil
      end
    end)
  end

  defp assert_eventually_value(fun, attempts \\ 100)

  defp assert_eventually_value(fun, attempts) when attempts > 0 do
    case fun.() do
      nil -> retry_assertion(fn -> assert_eventually_value(fun, attempts - 1) end)
      false -> retry_assertion(fn -> assert_eventually_value(fun, attempts - 1) end)
      value -> value
    end
  end

  defp assert_eventually_value(_fun, 0),
    do: flunk("value was not available before timeout")

  defp retry_assertion(fun) do
    receive do
    after
      20 -> fun.()
    end
  end

  defp drain_query_metadata(handler, acc \\ []) do
    receive do
      {^handler, metadata} -> drain_query_metadata(handler, [metadata | acc])
    after
      0 -> acc
    end
  end

  defp assert_runtime_role! do
    assert [["maraithon_runtime"]] = Repo.query!("SELECT current_user", [], log: false).rows
  end

  defp reset_sql_context! do
    Enum.each(
      [
        "maraithon.agent_local_down_proof",
        "maraithon.agent_termination_capability",
        "maraithon.test_agent_termination_lease_token",
        "maraithon.test_agent_termination_target",
        "maraithon.test_agent_termination_digest"
      ],
      fn setting ->
        Repo.query!("SELECT set_config($1, '', true)", [setting], log: false)
      end
    )

    Repo.query!("SET LOCAL ROLE maraithon_runtime", [], log: false)
    :ok
  end
end
