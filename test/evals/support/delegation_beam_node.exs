defmodule Maraithon.TestSupport.DelegationBeamNode do
  @moduledoc false
  import ExUnit.Assertions
  alias Maraithon.Repo
  alias Maraithon.Delegations.{Delegation, Grant, Scope, Jobs, Sources, Turn, Execution}
  alias Maraithon.Runtime.{BackgroundJob, BackgroundJobs, JobAuthority}
  alias Maraithon.Runtime.{AgentDirectives, AgentLeases, AgentSupervisor, AgentWatcher}
  alias Maraithon.Runtime.Coordination.{Authority, Session}
  alias Maraithon.TelegramAssistant.{Run, PreparedAction, ActionReconciliation}

  def boot(config) do
    Application.put_all_env(config)
    System.put_env("GIT_SHA", String.duplicate("a", 40))
    Logger.configure(level: :warning)
    {:ok, _} = Application.ensure_all_started(:maraithon)
    # Recovery is advanced explicitly so we can inspect the durable state
    # between proof, receipt reconciliation and coordinator restoration.
    :ok = Supervisor.terminate_child(Maraithon.Supervisor, AgentWatcher)
    :ok = Supervisor.delete_child(Maraithon.Supervisor, AgentWatcher)

    {:ok, _} =
      Supervisor.start_child(
        Maraithon.Supervisor,
        {AgentWatcher, reconcile?: false, recover?: false}
      )

    # Run the real Session and task supervision, with periodic product producers
    # disabled. Only the explicitly leased eval jobs run.
    {:ok, _} =
      Supervisor.start_child(Maraithon.Runtime.Supervisor, {Session, required_workers: []})

    System.pid()
  end

  def scope(user_id) do
    with {:ok, node} <- Session.current(),
         partitions = Authority.owned_partitions(node),
         id = Maraithon.Runtime.Coordination.Partitioning.partition_for("user:" <> user_id),
         true <- Enum.any?(partitions, &(&1.partition_id == id)) do
      {:ok, node, partitions}
    else
      _ -> :waiting
    end
  end

  def run(user_id, job_type) do
    {:ok, node, partitions} = scope(user_id)

    callback =
      case job_type do
        "delegation_send" -> &Execution.execute/1
        "delegation_decide" -> &Maraithon.Delegations.Decision.execute/1
        "runtime_recurring:delegation_due_sweep" -> &Maraithon.Runtime.RecurringJobs.execute/1
        "assistant_action_reconcile" -> &ActionReconciliation.execute/1
      end

    job = Repo.get_by!(BackgroundJob, job_type: job_type, status: "pending")
    Maraithon.TestSupport.DelegationRuntime.run_leased_job(node, partitions, job, callback)
  end

  def stale_write(job) do
    JobAuthority.transaction(job, fn ->
      job |> BackgroundJob.changeset(%{result: %{"stale_owner_wrote" => true}}) |> Repo.update!()
    end)
  end

  def create_coordinator(fixture) do
    {:ok, agent} =
      Maraithon.Agents.create_agent(%{
        user_id: fixture.user_id,
        behavior: "delegation_coordinator",
        status: "running",
        started_at: DateTime.utc_now(),
        config: %{}
      })

    {:ok, _} =
      Maraithon.AgentIsolation.grant_binding_consent(
        agent,
        Maraithon.DataCase.binding_consent(agent)
      )

    {:ok, _} =
      Repo.transaction(fn ->
        Maraithon.PrivacyErasure.WriteFence.lock_user_writable!(fixture.user_id)

        Repo.get!(Delegation, fixture.delegation_id)
        |> Delegation.hydrate()
        |> Delegation.changeset(%{agent_id: agent.id})
        |> Repo.update!()
      end)

    {:ok, _} =
      AgentSupervisor.start_agent(agent,
        admission: :bootstrap,
        ttl_ms: 3_000,
        renew_interval_ms: 500
      )

    {:ok, _} = wake(agent.id, "checkpoint")
    agent.id
  end

  def restart_coordinator(agent_id, generation) do
    agent = Maraithon.Agents.get_agent(agent_id)

    {:ok, _} =
      AgentSupervisor.start_agent(agent,
        admission: :recovery,
        recovery_generation: generation,
        ttl_ms: 3_000,
        renew_interval_ms: 500
      )

    :ok
  end

  def coordinator_state(agent_id) do
    case Registry.lookup(Maraithon.Runtime.AgentRegistry, agent_id) do
      [{pid, token}] ->
        {phase, data} = :sys.get_state(pid)
        {:ok, %{phase: phase, owner_token: token, state: data.behavior_state}}

      [] ->
        :waiting
    end
  end

  def stale_agent_fence(agent_id, old_token),
    do: Repo.transaction(fn -> AgentLeases.fence_ready!(agent_id, old_token) end)

  def wake(agent_id, kind) do
    agent = Maraithon.Agents.get_agent(agent_id)
    id = Ecto.UUID.generate()

    AgentDirectives.enqueue(
      agent.id,
      agent.user_id,
      "manual_wake",
      %{"job_id" => id, "job_type" => kind, "payload" => %{}},
      "beam-eval:#{id}"
    )
  end

  def attest_agent(incident, evidence_id, private_key) do
    alias Maraithon.Runtime.AgentTerminations
    digest = :crypto.hash(:sha256, evidence_id)
    operator = "local-beam-eval@example.invalid"
    payload = AgentTerminations.attestation_payload(incident, evidence_id, digest, operator)
    signature = :crypto.sign(:eddsa, :none, payload, [private_key, :ed25519])

    Repo.transaction(fn ->
      Repo.query!("SET LOCAL ROLE maraithon_incident_operator")

      AgentTerminations.attest_external(incident.id, %{
        evidence_id: evidence_id,
        evidence_digest: digest,
        signature: signature,
        proved_by: operator
      })
    end)
  end

  def activate do
    evidence = [
      evidence_id: "local-beam-eval:empty-disposable-database",
      evidence_digest: :crypto.hash(:sha256, "new local database, no application peers started"),
      activated_by: "beam-eval@example.invalid",
      revision: String.duplicate("a", 40)
    ]

    alias Maraithon.Runtime.Coordination.Protocol
    alias Maraithon.Effects.ProtocolCutover

    Repo.transaction(fn ->
      Repo.query!("SET LOCAL ROLE maraithon_activation_operator")
      assert {:ok, _} = Protocol.attest_effect_activation_evidence(evidence)

      assert {:ok, _} =
               ProtocolCutover.activate(
                 [confirmation: ProtocolCutover.activation_confirmation()] ++ evidence
               )

      assert {:ok, _} =
               Protocol.activate([confirmation: Protocol.activation_confirmation()] ++ evidence)
    end)
  end

  def stale_model_response(job) do
    Maraithon.Delegations.Budget.settle(job, "compose", %{usage: %{reported_cost: 0.0001}})
  end

  def seed(kind \\ :send) do
    user_id = "beam-eval@example.invalid"
    runtime = Application.fetch_env!(:maraithon, Maraithon.Runtime)

    Application.put_env(
      :maraithon,
      Maraithon.Runtime,
      Keyword.put(runtime, :openrouter_model, "meta/muse-spark-1.3-contributor")
    )

    Application.put_env(:maraithon, :delegations_enabled, true)
    Application.put_env(:maraithon, :delegation_user_allowlist, [user_id])
    Application.put_env(:maraithon, :delegation_eval_only, false)
    Application.put_env(:maraithon, :delegation_sends_enabled, %{gmail: true, slack: false})
    {:ok, _} = Maraithon.Accounts.get_or_create_user_by_email(user_id)

    {:ok, _} =
      Maraithon.OAuth.store_tokens(user_id, "google:eval", %{
        access_token: "local-eval-only",
        refresh_token: "fixture",
        expires_in: 3600,
        scopes: ["https://www.googleapis.com/auth/gmail.compose"]
      })

    account = Maraithon.ConnectedAccounts.get(user_id, "google:eval")

    account
    |> Ecto.Changeset.change(metadata: %{"email" => "sender@example.invalid"})
    |> Repo.update!()

    {:ok, fixture} =
      Repo.transaction(fn ->
        Maraithon.PrivacyErasure.WriteFence.lock_user_writable!(user_id)

        todo =
          Repo.insert!(%Maraithon.Todos.Todo{
            user_id: user_id,
            owner_user_id: user_id,
            title: "Recovery eval",
            summary: "Confirm indigo",
            source: "manual",
            next_action: "Reply",
            dedupe_key: Ecto.UUID.generate()
          })

        scope = %{
          "identity" => %{"email" => "sender@example.invalid", "account_id" => account.id},
          "to" => ["recipient@example.invalid"],
          "cc" => [],
          "first_send_cc" => [],
          "subject" => "[Maraithon eval] BEAM recovery",
          "task_owner" => Maraithon.Todos.Workflow.user_owner(todo),
          "outcome" => "Confirm indigo"
        }

        d =
          %Delegation{user_id: user_id}
          |> Delegation.changeset(%{
            todo_id: todo.id,
            connected_account_id: account.id,
            provider: "gmail",
            provider_thread_id: "aabbcc",
            state: "waiting_reply",
            data: %{}
          })
          |> Repo.insert!()

        grant =
          %Grant{user_id: user_id}
          |> Grant.changeset(%{
            delegation_id: d.id,
            version: 1,
            origin_request_id: Ecto.UUID.generate(),
            data: %{"scope" => scope, "scope_hash" => Scope.hash(scope)}
          })
          |> Repo.insert!()

        d = d |> Delegation.changeset(%{current_grant_id: grant.id}) |> Repo.update!()

        message = %{
          message_id: "112233",
          thread_id: "aabbcc",
          from: "recipient@example.invalid",
          to: "sender@example.invalid",
          subject: scope["subject"],
          text_body: "The colour is indigo.",
          labels: ["INBOX"],
          internal_date: DateTime.add(d.inserted_at, -1),
          internet_message_id: "<parent@example.invalid>"
        }

        Jobs.start_sync!(
          d,
          grant,
          %{id: Ecto.UUID.generate(), kind: "user_action"},
          DateTime.utc_now()
        )

        d = d |> Delegation.changeset(%{state: "deciding"}) |> Repo.update!()
        turn = Repo.one!(Turn) |> Turn.hydrate()
        run = Repo.get!(Run, turn.run_id) |> Run.hydrate_payloads()
        {:ok, sources} = Sources.snapshot([message], account.id, d.provider_thread_id)

        run
        |> Run.changeset(%{
          status: if(kind == :send, do: "completed", else: "queued"),
          prompt_snapshot: Map.put(run.prompt_snapshot, "sources", sources)
        })
        |> Repo.update!()

        action_id =
          if kind == :send do
            prepare_send!(d, grant, turn, message)
          else
            binding = run.prompt_snapshot[Maraithon.Delegations.Binding.key()]
            Jobs.enqueue!("delegation_decide", d, binding, DateTime.utc_now())
            seed_cost_monitor!()
            nil
          end

        %{
          user_id: user_id,
          delegation_id: d.id,
          action_id: action_id,
          turn_id: turn.id,
          run_id: run.id,
          grant_id: grant.id,
          message: message
        }
      end)

    fixture
  end

  defp prepare_send!(d, grant, turn, message) do
    turn
    |> Turn.changeset(%{
      status: "validated",
      data:
        Map.merge(turn.data, %{
          "decision" => %{
            "kind" => "send",
            "body" => "Got it. Indigo.",
            "reason" => "Confirm the answer",
            "evidence" => [message.message_id]
          },
          "policy_review" => %{"allowed" => true, "reason" => "Matches the source"}
        })
    })
    |> Repo.update!()

    now = Maraithon.Runtime.DatabaseClock.now!()

    next =
      Execution.prepare!(
        d,
        grant,
        %{id: Ecto.UUID.generate(), kind: "decision", data: %{"turn_id" => turn.id}},
        now
      )

    assert next.state == "sending"
    d |> Delegation.changeset(%{state: next.state}) |> Repo.update!()
    action = Repo.one!(PreparedAction) |> PreparedAction.hydrate_payload()
    # Only advance the fixture's undo deadline, never an ownership lease.
    turn = Repo.get!(Turn, turn.id) |> Turn.hydrate()
    turn |> Turn.changeset(%{available_at: DateTime.add(now, -1)}) |> Repo.update!()
    action.id
  end

  defp seed_cost_monitor! do
    {:ok, _} =
      BackgroundJobs.enqueue("runtime_recurring:llm_cost_monitor", %{
        result: %{
          "status" => "within_budget",
          "checked_at" => DateTime.to_iso8601(DateTime.utc_now()),
          "daily_cost_usd" => 0,
          "rolling_cost_usd" => 0,
          "key_fingerprint" =>
            :crypto.hash(:sha256, "local-eval-only") |> Base.encode16(case: :lower)
        }
      })
  end

  def attest(assignment, evidence_id) do
    identity = %{
      assignment_id: assignment.id,
      job_id: assignment.work_id,
      claim_token: assignment.claim_token,
      node_incarnation_id: assignment.node_incarnation_id,
      supervisor_id: assignment.supervisor_id,
      task_id: assignment.local_task_id
    }

    Repo.transaction(fn ->
      Repo.query!("SET LOCAL ROLE maraithon_incident_operator")

      Maraithon.Runtime.Coordination.TaskTerminationAttestations.record(
        identity,
        evidence_id,
        "local-beam-eval@example.invalid",
        "PHYSICAL_TASK_TERMINATED"
      )
    end)
  end
end
