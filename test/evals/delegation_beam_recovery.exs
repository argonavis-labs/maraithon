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

  setup do
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
    status = destroy_peer(first, os_pid)
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

  test "a new BEAM resumes an interrupted decision through the real wake sweep" do
    alias Maraithon.Delegations.Turn
    alias Maraithon.Runtime.{BackgroundJobs, RecurringJobs}
    alias Maraithon.TelegramAssistant.Run
    fixture = Node.seed(:decision)
    bypass = Bypass.open()
    requests = start_supervised!({Agent, fn -> 0 end})
    parent = self()
    model = "meta/muse-spark-1.3-contributor"

    Bypass.expect(bypass, "GET", "/models/#{model}/endpoints", fn conn ->
      json(conn, %{
        "data" => %{
          "id" => model,
          "endpoints" => [
            %{
              "tag" => "meta",
              "context_length" => 1_048_576,
              "supported_parameters" => ["max_tokens"],
              "pricing" => %{"prompt" => "0.0000001", "completion" => "0.0000002"}
            }
          ]
        }
      })
    end)

    Bypass.expect(bypass, "POST", "/chat/completions", fn conn ->
      Process.flag(:trap_exit, true)
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      request = Jason.decode!(body)
      assert request["model"] == model
      assert request["provider"]["only"] == ["meta"]
      n = Agent.get_and_update(requests, &{&1 + 1, &1 + 1})
      assert n <= 3

      if n == 1 do
        send(parent, {:model_entered_before_response, self()})

        receive do
          :release -> :ok
        after
          20_000 -> flunk("model fixture was not released after BEAM destruction")
        end
      end

      decision =
        if n < 3 do
          %{
            "kind" => "wait",
            "reason" => "Keep tracking the conversation",
            "evidence" => [fixture.message.message_id]
          }
        else
          %{"allowed" => true, "outcome_proven" => false, "reason" => "Within the grant"}
        end

      json(conn, %{
        "id" => "local-response-#{n}",
        "model" => model,
        "choices" => [
          %{
            "finish_reason" => "stop",
            "message" => %{
              "role" => "assistant",
              "content" => Jason.encode!(decision)
            }
          }
        ],
        "usage" => %{
          "prompt_tokens" => 500,
          "completion_tokens" => 100,
          "total_tokens" => 600,
          "cost" => 0.0001
        }
      })
    end)

    config = peer_config(bypass.port, fixture.user_id)
    {first, os_pid} = peer(config)
    {:ok, old_node, _} = eventually(fn -> call(first, :scope, [fixture.user_id]) end)
    :peer.cast(first, Node, :run, [fixture.user_id, "delegation_decide"])
    assert_receive {:model_entered_before_response, provider}, 30_000
    on_exit(fn -> send(provider, :release) end)

    old_job =
      Repo.get_by!(BackgroundJob, job_type: "delegation_decide")
      |> BackgroundJob.hydrate_payloads()

    assignment = Coordination.TaskClaims.get(old_job.coordination_task_assignment_id)
    original = Repo.get!(Turn, fixture.turn_id) |> Turn.hydrate()
    assert original.model_calls == 1
    assert original.reserved_micro_usd > 0
    assert original.cost_micro_usd == 0
    assert original.data["model_entries"]["compose"]["state"] == "entered"
    run = Repo.get!(Run, fixture.run_id) |> Run.hydrate_payloads()
    assert run.result_summary["execution_checkpoint"]["phase"] == "model_entered"
    grant = Repo.get!(Grant, fixture.grant_id) |> Grant.hydrate()

    status = destroy_peer(first, os_pid)
    send(provider, :release)
    {second, second_os_pid} = peer(config)
    refute second_os_pid == os_pid

    eventually(fn ->
      case Coordination.TaskClaims.get(assignment.id) do
        %{state: "termination_requested"} -> {:ok, :fenced}
        _ -> :waiting
      end
    end)

    partition = Repo.get!(Coordination.Partition, old_job.partition_id)
    assert partition.state == "draining"
    assert partition.owner_node_incarnation_id == old_node.id
    assert partition.ownership_epoch == old_job.coordination_partition_epoch
    assert {:error, _} = call(second, :stale_model_response, [old_job])
    assert Repo.get!(Turn, original.id) |> Turn.hydrate() == original

    assert Repo.aggregate(
             from(j in BackgroundJob, where: j.job_type == "delegation_decide"),
             :count
           ) == 1

    evidence = "local-model-beam-exit:#{os_pid}:#{old_node.id}:#{status}"
    assert {:ok, {:ok, _}} = Node.attest(Coordination.TaskClaims.get(assignment.id), evidence)
    {:ok, new_node, _} = eventually(fn -> call(second, :scope, [fixture.user_id]) end)
    refute new_node.id == old_node.id
    assert Coordination.TaskClaims.get(assignment.id).state == "outcome_ambiguous"
    assert Repo.get!(BackgroundJob, old_job.id).status == "failed"

    # Exercise production sweep wiring, including creating the coordinator and
    # binding it to the conversation, not a direct call to the repair helper.
    {:ok, sweep} =
      BackgroundJobs.enqueue(RecurringJobs.job_type("delegation_due_sweep"), %{
        queue: RecurringJobs.queue(),
        dedupe_key: RecurringJobs.dedupe_key("delegation_due_sweep"),
        payload: %{"recurring_job" => "delegation_due_sweep"}
      })

    assert is_nil(sweep.user_id)

    assert {:ok, %{users: 1, repaired: 1, held: 0}, {:reschedule_in, 300_000}} =
             call(second, :run, [fixture.user_id, "runtime_recurring:delegation_due_sweep"])

    sweep = Repo.get!(BackgroundJob, sweep.id)
    assert sweep.status == "pending"
    assert DateTime.diff(sweep.scheduled_at, DateTime.utc_now()) in 295..300

    restored = Repo.get!(Turn, original.id) |> Turn.hydrate()
    assert restored.model_calls == original.model_calls
    assert restored.reserved_micro_usd == original.reserved_micro_usd
    assert restored.data["decision_recoveries"] == 1
    assert restored.data["model_entries"]["compose:interrupted:1"]["state"] == "entered"

    assert {:ok, %{state: "decided"}} = call(second, :run, [fixture.user_id, "delegation_decide"])

    {:ok, d} =
      eventually(fn ->
        case Repo.get!(Delegation, fixture.delegation_id) do
          %{state: "waiting_reply"} = d -> {:ok, d}
          _ -> :waiting
        end
      end)

    assert is_binary(d.agent_id)
    turn = Repo.get!(Turn, original.id) |> Turn.hydrate()
    assert turn.model_calls == 3
    assert turn.reserved_micro_usd == original.reserved_micro_usd
    assert turn.cost_micro_usd == 200
    assert d.lifetime_micro_usd == 200
    assert Repo.get!(Grant, fixture.grant_id) |> Grant.hydrate() == grant
    assert Repo.get!(Run, fixture.run_id).status == "completed"
    assert Repo.aggregate(from(e in Event, where: e.kind == "decision"), :count) == 1
    assert Repo.aggregate(PreparedAction, :count) == 0
    assert d.lifetime_sends == 0
    assert Agent.get(requests, & &1) == 3
    assert {:error, _} = call(second, :stale_model_response, [old_job])
    assert Repo.get!(Turn, original.id) |> Turn.hydrate() == turn
    replacement = Repo.get_by!(BackgroundJob, job_type: "delegation_decide", status: "completed")
    new_assignment = Coordination.TaskClaims.get(replacement.coordination_task_assignment_id)
    assert new_assignment.node_incarnation_id == new_node.id
    refute new_assignment.claim_token == assignment.claim_token
    :ok = :peer.stop(second)

    IO.puts(
      "BEAM_DECISION_RECOVERY_EVIDENCE=" <>
        Jason.encode!(%{
          old_incarnation: old_node.id,
          new_incarnation: new_node.id,
          os_exit_status: status,
          same_turn_resumed: true,
          provider: "local HTTP fixture",
          fixture_model_calls: 3,
          settled_micro_usd: 200,
          retained_unknown_micro_usd: turn.reserved_micro_usd,
          stale_model_responses_rejected: 2,
          decision_events: 1,
          provider_send_count: 0,
          real_wake_sweep: true,
          global_recurring_job: true,
          sweep_rescheduled: true,
          coordinator_created: true,
          final_state: d.state,
          periodic_producers: false,
          development_spending: false
        })
    )
  end

  defp destroy_peer(peer, os_pid) do
    monitor = Process.monitor(peer)
    {"", 0} = System.cmd("kill", ["-KILL", os_pid])
    assert_receive {:DOWN, ^monitor, :process, ^peer, {:exit_status, status}}, 10_000
    assert status in [137, 9]
    status
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
        protocol_storage_verification_cache_ms: 1_000,
        llm_provider: Maraithon.LLM.OpenRouterProvider,
        llm_provider_name: "openrouter",
        openrouter_model: "meta/muse-spark-1.3-contributor",
        openrouter_api_key: "local-eval-only"
      )

    app =
      Application.get_all_env(:maraithon)
      |> Keyword.merge([
        {Maraithon.Runtime, runtime},
        {:process_role, :combined},
        {:start_background_workers, false},
        {:gmail, [api_base_url: "http://localhost:#{port}"]},
        {:openrouter,
         [
           base_url: "http://localhost:#{port}/chat/completions",
           models_base_url: "http://localhost:#{port}/models"
         ]},
        {Maraithon.LLM.CostMonitor, [enabled: true]},
        {:llm_development_spending, false},
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
