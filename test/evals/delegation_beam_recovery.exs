# Explicit local eval, outside the normal suite:
# MIX_ENV=test mix run --no-start test/evals/delegation_beam_recovery.exs
unless Mix.env() == :test, do: raise("run this isolated eval with MIX_ENV=test")
ExUnit.start(autorun: false)
Logger.configure(level: :warning)
Code.require_file("support/delegation_beam_node.exs", __DIR__)

defmodule Maraithon.DelegationBeamRecoveryEval do
  use ExUnit.Case, async: false
  import Ecto.Query
  alias Maraithon.Repo
  alias Maraithon.TestSupport.DelegationBeamNode, as: Node
  alias Maraithon.Runtime.{BackgroundJob, Coordination}
  alias Maraithon.Runtime.{AgentLeases, AgentTerminations, Snapshot}
  alias Maraithon.Delegations.{Delegation, Grant, Event}
  alias Maraithon.TelegramAssistant.PreparedAction

  @moduletag timeout: 180_000

  setup_all do
    refute List.keymember?(Application.started_applications(), :maraithon, 0)
    # Never inherit a production URL or a caller-selected database. The only
    # destructive cleanup targets the fresh database successfully created here.
    config = Application.fetch_env!(:maraithon, Repo)
    assert config[:hostname] in ["localhost", "127.0.0.1"]

    config =
      config
      |> Keyword.drop([:url, :pool, :socket_dir, :socket, :parameters])
      |> Keyword.merge(
        database: "maraithon_beam_eval_#{System.pid()}_#{System.unique_integer([:positive])}",
        pool_size: 6
      )

    Application.put_env(:maraithon, Repo, config)
    {:ok, _} = Application.ensure_all_started(:ecto_sql)
    assert :ok = Ecto.Adapters.Postgres.storage_up(config)
    on_exit(fn -> assert :ok = Ecto.Adapters.Postgres.storage_down(config) end)
    start_supervised!(Repo)
    start_supervised!(Maraithon.Vault)
    # The early migrations establish the canonical roles and ownership. Later
    # catalog changes deliberately require the migrator's exact current role.
    Ecto.Migrator.run(Repo, "priv/repo/migrations", :up, to: 20_260_908_181_832, log: false)
    stop_supervised!(Repo)

    Application.put_env(
      :maraithon,
      Repo,
      Keyword.put(config, :parameters, role: "maraithon_migrator")
    )

    start_supervised!(Repo)
    Ecto.Migrator.run(Repo, "priv/repo/migrations", :up, to: 20_260_908_181_833, log: false)
    stop_supervised!(Repo)
    Application.put_env(:maraithon, Repo, config)
    start_supervised!(Repo)
    Ecto.Migrator.run(Repo, "priv/repo/migrations", :up, all: true, log: false)
    stop_supervised!(Repo)

    Application.put_env(
      :maraithon,
      Repo,
      Keyword.put(config, :parameters,
        role: "maraithon_runtime",
        log_parameter_max_length: "0",
        log_parameter_max_length_on_error: "0"
      )
    )

    start_supervised!(Repo)
    Node.activate()
    {:ok, _} = Application.ensure_all_started(:bypass)
    {public_key, private_key} = :crypto.generate_key(:eddsa, :ed25519)

    Application.put_env(:maraithon, AgentTerminations,
      external_attestation_public_key: public_key
    )

    %{attestation_key: private_key}
  end

  test "a destroyed BEAM restores an older coordinator checkpoint without replaying a send", c do
    fixture = Node.seed()
    bypass = Bypass.open()
    accepted = start_supervised!({Agent, fn -> [] end})
    parent = self()
    message = provider_message(fixture.message)

    Bypass.expect(
      bypass,
      "GET",
      "/users/me/threads/aabbcc",
      &json(&1, %{"id" => "aabbcc", "messages" => [message]})
    )

    Bypass.expect(bypass, "GET", "/users/me/messages/112233", &json(&1, message))

    Bypass.expect(
      bypass,
      "GET",
      "/users/me/settings/sendAs",
      &json(&1, %{"sendAs" => [%{"isPrimary" => true, "sendAsEmail" => "sender@example.invalid"}]})
    )

    Bypass.expect_once(bypass, "POST", "/users/me/messages/send", fn conn ->
      # Provider acceptance outlives a disconnected client. Let this mock
      # request finish after SIGKILL rather than treating Cowboy's socket
      # shutdown as a failed expectation.
      Process.flag(:trap_exit, true)
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      mime = raw |> Jason.decode!() |> Map.fetch!("raw") |> Base.url_decode64!(padding: false)
      Agent.update(accepted, &[mime | &1])
      send(parent, {:accepted_before_receipt, self()})

      receive do
        :release -> json(conn, %{"id" => "445566", "threadId" => "aabbcc"})
      after
        20_000 -> flunk("provider was not released after the application crash")
      end
    end)

    Bypass.expect(
      bypass,
      "GET",
      "/users/me/messages",
      &json(&1, %{"messages" => [%{"id" => "445566"}]})
    )

    Bypass.expect(bypass, "GET", "/users/me/messages/445566", fn conn ->
      [mime] = Agent.get(accepted, & &1)
      [headers, body] = String.split(mime, "\r\n\r\n", parts: 2)

      headers =
        Enum.map(String.split(headers, "\r\n"), fn line ->
          [name, value] = String.split(line, ":", parts: 2)
          %{"name" => name, "value" => String.trim(value)}
        end)

      json(conn, %{
        "id" => "445566",
        "threadId" => "aabbcc",
        "labelIds" => ["SENT"],
        "payload" => %{
          "headers" => headers,
          "body" => %{"data" => Base.url_encode64(body, padding: false)}
        }
      })
    end)

    config = peer_config(bypass.port, fixture.user_id)
    {first, os_pid} = peer(config)
    {:ok, old_node, _} = eventually(fn -> call(first, :scope, [fixture.user_id]) end)
    agent_id = call(first, :create_coordinator, [fixture])

    {:ok, old_snapshot} =
      eventually(fn ->
        case Snapshot.latest(agent_id) do
          nil -> :waiting
          snapshot -> {:ok, snapshot}
        end
      end)

    {:ok, %{owner_token: old_agent_token}} = call(first, :coordinator_state, [agent_id])
    assert byte_size(Jason.encode!(old_snapshot.behavior_state)) < 1_024
    :peer.cast(first, Node, :run, [fixture.user_id, "delegation_send"])
    assert_receive {:accepted_before_receipt, provider}, 30_000
    on_exit(fn -> send(provider, :release) end)
    action = Repo.get!(PreparedAction, fixture.action_id) |> PreparedAction.hydrate_payload()
    assert action.status == "confirmed"
    assert action.payload["_maraithon_execution_attempts"] == 1

    old_job =
      Repo.get_by!(BackgroundJob, job_type: "delegation_send") |> BackgroundJob.hydrate_payloads()

    assignment = Coordination.TaskClaims.get(old_job.coordination_task_assignment_id)
    assert assignment.node_incarnation_id == old_node.id
    assert assignment.state == "running"
    grant = Repo.get!(Grant, fixture.grant_id) |> Grant.hydrate()

    # The OS pid comes directly from this peer. A real exit notification, not
    # lease expiry or a missing registry entry, authorizes the local attestation.
    monitor = Process.monitor(first)
    {"", 0} = System.cmd("kill", ["-KILL", os_pid])
    assert_receive {:DOWN, ^monitor, :process, ^first, {:exit_status, status}}, 10_000
    assert status in [137, 9]
    send(provider, :release)

    {second, second_os_pid} = peer(config)
    refute second_os_pid == os_pid

    eventually(fn ->
      case Coordination.TaskClaims.get(assignment.id) do
        %{state: "termination_requested"} -> {:ok, :fenced}
        _ -> :waiting
      end
    end)

    assert {:error, _} = call(second, :stale_write, [old_job])
    assert {:error, _} = call(second, :stale_agent_fence, [agent_id, old_agent_token])

    # Still no physical proof in storage, so the old ownership remains draining.
    partition = Repo.get!(Coordination.Partition, old_job.partition_id)
    assert partition.state == "draining"
    assert partition.owner_node_incarnation_id == old_node.id
    assert partition.ownership_epoch == old_job.coordination_partition_epoch

    assert Repo.get!(Grant, fixture.grant_id) |> Grant.hydrate() == grant
    assert Repo.get!(Delegation, fixture.delegation_id).lifetime_sends == 0
    assert length(Agent.get(accepted, & &1)) == 1

    evidence_id = "local-beam-exit:#{os_pid}:#{old_node.id}:#{status}"
    assert {:ok, {:ok, _}} = Node.attest(Coordination.TaskClaims.get(assignment.id), evidence_id)

    {:ok, incident} =
      eventually(fn ->
        case AgentTerminations.request_expired(agent_id, old_agent_token, backoffs_ms: [0]) do
          {status, incident} when status in [:requested, :duplicate] -> {:ok, incident}
          _ -> :waiting
        end
      end)

    assert AgentLeases.get(agent_id).owner_token == old_agent_token
    assert {:ok, {:attested, _}} = Node.attest_agent(incident, evidence_id, c.attestation_key)
    assert {:recorded, guard} = AgentTerminations.reconcile_incident(incident.id)
    {:ok, new_node, _} = eventually(fn -> call(second, :scope, [fixture.user_id]) end)
    refute new_node.id == old_node.id
    assert Coordination.TaskClaims.get(assignment.id).state == "outcome_ambiguous"
    # The ambiguous job is not made runnable again. Its already-durable
    # observer owns recovery and must record uncertainty before proving success.
    assert Repo.get!(BackgroundJob, old_job.id).status == "failed"

    assert {:ok, %{state: "executed"}} =
             call(second, :run, [fixture.user_id, "assistant_action_reconcile"])

    assert Repo.get!(PreparedAction, fixture.action_id).status == "executed"
    assert Repo.get!(Delegation, fixture.delegation_id).lifetime_sends == 1
    assert Repo.aggregate(from(e in Event, where: e.kind == "send_unknown"), :count) == 1
    assert Repo.aggregate(from(e in Event, where: e.kind == "send_receipt"), :count) == 1
    assert Repo.aggregate(Maraithon.Delegations.Turn, :sum, :model_calls) == 0
    assert length(Agent.get(accepted, & &1)) == 1
    assert {:error, _} = call(second, :stale_write, [old_job])

    # The only checkpoint predates both receipt events. Restore it through the
    # actual gen_statem; its old cursor must not override the committed rows.
    assert Snapshot.latest(agent_id) == old_snapshot
    assert :ok = call(second, :restart_coordinator, [agent_id, guard.generation])

    {:ok, recovered} =
      eventually(fn ->
        with {:ok, %{phase: :idle} = current} <- call(second, :coordinator_state, [agent_id]),
             false <- Repo.exists?(from e in Event, where: e.wake_state != "consumed") do
          {:ok, current}
        else
          _ -> :waiting
        end
      end)

    refute recovered.owner_token == old_agent_token
    assert recovered.state["version"] == 1
    assert Repo.get!(Delegation, fixture.delegation_id).state == "waiting_reply"
    assert Repo.get!(Delegation, fixture.delegation_id).lifetime_sends == 1
    assert {:error, _} = call(second, :stale_agent_fence, [agent_id, old_agent_token])
    assert Repo.aggregate(from(e in Event, where: e.kind == "send_receipt"), :count) == 1
    assert length(Agent.get(accepted, & &1)) == 1
    :ok = :peer.stop(second)

    IO.puts(
      "BEAM_RECOVERY_EVIDENCE=" <>
        Jason.encode!(%{
          old_incarnation: old_node.id,
          new_incarnation: new_node.id,
          os_exit_status: status,
          provider_send_count: 1,
          proven_send_count: 1,
          stale_writes_rejected: 2,
          stale_agent_fences_rejected: 2,
          older_coordinator_checkpoint_restored: true,
          checkpoint_bytes: byte_size(Jason.encode!(old_snapshot.behavior_state)),
          coordinator_owner_changed: true,
          model_calls: 0,
          provider: "local HTTP fixture",
          periodic_producers: false
        })
    )
  end

  defp peer(config) do
    args = [~c"+S", ~c"2", ~c"-pa" | :code.get_path()]
    {:ok, peer, _} = :peer.start(%{connection: :standard_io, args: args, peer_down: :crash})

    on_exit(fn ->
      try do
        :peer.stop(peer)
      catch
        :exit, _ -> :ok
      end
    end)

    {:ok, _} = :peer.call(peer, Application, :ensure_all_started, [:elixir])

    :peer.call(peer, Code, :require_file, [Path.join(__DIR__, "support/delegation_beam_node.exs")])

    {peer, call(peer, :boot, [config])}
  end

  defp peer_config(port, user_id) do
    runtime =
      Application.fetch_env!(:maraithon, Maraithon.Runtime)
      |> Keyword.merge(
        exact_agent_runtime_enabled: true,
        multinode_coordination_enabled: true,
        allow_legacy_effect_protocol_in_test: false,
        coordination_tick_ms: 100,
        coordination_node_ttl_ms: 3_000,
        coordination_partition_ttl_ms: 3_000,
        coordination_leader_ttl_ms: 3_000,
        coordination_transition_limit: 16,
        protocol_storage_verification_cache_ms: 1_000
      )

    app =
      Application.get_all_env(:maraithon)
      |> Keyword.merge([
        {Maraithon.Runtime, runtime},
        {:process_role, :combined},
        {:start_background_workers, false},
        {:gmail, [api_base_url: "http://localhost:#{port}"]},
        {:delegations_enabled, true},
        {:delegation_user_allowlist, [user_id]},
        {:delegation_eval_only, false},
        {:delegation_sends_enabled, %{gmail: true, slack: false}},
        {:telegram_assistant,
         [prepared_action_execution_lease_seconds: 2, prepared_action_execution_heartbeat_ms: 100]}
      ])

    for {app_name, _, _} <- Application.loaded_applications(),
        do:
          {app_name, if(app_name == :maraithon, do: app, else: Application.get_all_env(app_name))}
  end

  defp call(peer, fun, args), do: :peer.call(peer, Node, fun, args, 30_000)

  defp eventually(fun, attempts \\ 300)
  defp eventually(_fun, 0), do: flunk("recovery condition was not reached within 30 seconds")

  defp eventually(fun, attempts) do
    case fun.() do
      {:ok, _} = result ->
        result

      {:ok, _, _} = result ->
        result

      _ ->
        ref = make_ref()
        Process.send_after(self(), ref, 100)
        receive do: (^ref -> eventually(fun, attempts - 1))
    end
  end

  defp provider_message(m),
    do: %{
      "id" => m.message_id,
      "threadId" => m.thread_id,
      "labelIds" => m.labels,
      "internalDate" => to_string(DateTime.to_unix(m.internal_date, :millisecond)),
      "payload" => %{
        "mimeType" => "text/plain",
        "headers" => [
          %{"name" => "From", "value" => m.from},
          %{"name" => "To", "value" => m.to},
          %{"name" => "Subject", "value" => m.subject},
          %{"name" => "Message-ID", "value" => m.internet_message_id}
        ],
        "body" => %{"data" => Base.url_encode64(m.text_body, padding: false)}
      }
    }

  defp json(conn, body),
    do:
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(body))
end

if ExUnit.run().failures > 0, do: System.halt(1)
