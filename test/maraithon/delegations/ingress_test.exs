defmodule Maraithon.Delegations.IngressTest do
  use Maraithon.DataCase, async: false
  alias Maraithon.{Accounts, Repo}
  alias Maraithon.Delegations.{Delegation, Event, Grant, Ingress, Scope, StateMachine}

  setup tags do
    user_id =
      if tags[:controlled_eval],
        do: "kent@runner.now",
        else: "delegation-ingress-#{Ecto.UUID.generate()}@example.invalid"

    {:ok, _} = Accounts.get_or_create_user_by_email(user_id)

    account =
      Repo.insert!(%Maraithon.Accounts.ConnectedAccount{
        user_id: user_id,
        provider: "google:eval",
        status: "connected",
        metadata: %{"email" => "kent@runner.now"}
      })

    todo =
      Repo.insert!(%Maraithon.Todos.Todo{
        user_id: user_id,
        owner_user_id: user_id,
        title: "Eval reply",
        summary: "Get the test colour",
        source: "manual",
        next_action: "Ask",
        dedupe_key: Ecto.UUID.generate()
      })

    owner =
      if tags[:tracked_owner] do
        person = Repo.insert!(%Maraithon.Crm.Person{user_id: user_id, display_name: "Charlie"})
        %{"kind" => "person", "id" => person.id, "label" => "Charlie"}
      else
        Maraithon.Todos.Workflow.user_owner(todo)
      end

    scope = %{
      "identity" => %{
        "email" => "kent@runner.now",
        "account_id" => account.id,
        "signature" => tags[:signature]
      },
      "to" => ["kent.fenwick@gmail.com"],
      "cc" => [],
      "first_send_cc" => tags[:first_send_cc] || [],
      "subject" => "[Maraithon eval] A question",
      "task_owner" => owner,
      "outcome" => "Get the test colour"
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

    g =
      %Grant{user_id: user_id}
      |> Grant.changeset(%{
        delegation_id: d.id,
        version: 1,
        origin_request_id: Ecto.UUID.generate(),
        data: %{"scope" => scope, "scope_hash" => Scope.hash(scope)}
      })
      |> Repo.insert!()

    d = d |> Delegation.changeset(%{current_grant_id: g.id}) |> Repo.update!()

    message = %{
      message_id: "112233",
      thread_id: "aabbcc",
      from: "Kent <kent.fenwick@gmail.com>",
      to: "Kent <kent@runner.now>",
      subject: "[Maraithon eval] A question",
      text_body: "The colour is indigo.",
      labels: ["INBOX"],
      internal_date: DateTime.add(d.inserted_at, 1),
      internet_message_id: "<eval@example.invalid>"
    }

    %{user_id: user_id, account: account, delegation: d, scope: scope, message: message}
  end

  test "arrival advances the durable revision before the coordinator runs, once per message", c do
    route(c, c.message)
    route(c, c.message)
    d = Repo.get!(Delegation, c.delegation.id) |> Delegation.hydrate()
    assert d.source_revision == 1
    assert d.state == "waiting_reply"
    [event] = Repo.all(Event) |> Enum.map(&Event.hydrate/1)
    assert event.data["classification"] == "reply"
    assert event.data["source_revision"] == 1
    {next, [:enqueue_sync]} = StateMachine.apply(d, event)
    assert next.source_revision == 1
    assert next.state == "ready"
  end

  test "opening a delegated todo does not run a second brief or fabricate a draft", c do
    alias Maraithon.Todos.{Brief, Todo}
    alias Maraithon.AssistantChat.TodoThreadPrimer
    todo = Repo.get!(Todo, c.delegation.todo_id)
    assert Maraithon.Delegations.attached?(todo)
    assert {:ok, nil} = Brief.enqueue_generation(todo, force: true)

    assert {:ok, _} =
             Brief.generate_and_store(c.user_id, todo.id,
               force: true,
               llm_complete: fn _ -> flunk("delegation already owns the model work") end
             )

    refute Repo.exists?(
             from j in Maraithon.Runtime.BackgroundJob,
               where: j.job_type == "todo_brief_generation"
           )

    assert {:ok, thread} = Maraithon.AssistantChat.get_or_create_todo_thread(c.user_id, todo.id)
    assert :skip = TodoThreadPrimer.resolve_send_action_attrs(thread, todo)
    assert is_nil(TodoThreadPrimer.prepared_action_for(thread, todo))

    turn =
      Repo.one!(
        from t in Maraithon.TelegramConversations.Turn, where: t.conversation_id == ^thread.id
      )
      |> Maraithon.TelegramConversations.Turn.hydrate()

    assert turn.structured_data["delegation_managed"]
    assert is_nil(turn.structured_data["drafted_next_step"])
    assert is_nil(turn.structured_data["prepared_action_id"])
  end

  test "retention preserves a stopped conversation while model spend is unknown", c do
    alias Maraithon.Delegations.{Retention, Turn}
    exact_authority(c.user_id)

    assert {:ok, _} =
             Repo.transaction(fn ->
               {d, _, event} = decision_turn(c)
               d |> Delegation.changeset(%{state: "stopped"}) |> Repo.update!()
               turn = Repo.get!(Turn, event.data["turn_id"]) |> Turn.hydrate()

               turn
               |> Turn.changeset(%{status: "superseded", reserved_micro_usd: 105_268})
               |> Repo.update!()
             end)

    cutoff = DateTime.add(DateTime.utc_now(), 1)
    opts = [now: cutoff, limit: 50, per_tenant: 50]
    assert {:ok, %{count: 0}} = Retention.retention_backlog(cutoff, nil, opts)
    assert {:ok, %{purged: 0}} = Retention.purge_retention_batch(cutoff, nil, opts)
    assert Repo.get(Delegation, c.delegation.id)
    turn = Repo.one!(Turn) |> Turn.hydrate()
    assert turn.reserved_micro_usd == 105_268

    turn |> Turn.changeset(%{reserved_micro_usd: 0, cost_micro_usd: 100}) |> Repo.update!()
    assert {:ok, %{count: 1}} = Retention.retention_backlog(cutoff, nil, opts)
  end

  @tag idle_coordinator: true
  test "retirement requires seven quiet days and never retires a waiting conversation", c do
    agent = idle_coordinator(c)
    now = DateTime.utc_now()
    assert idle_coordinator?(agent.id, now)
    refute idle_coordinator?(agent.id, DateTime.add(now, -2, :day))

    for state <- ~w(waiting_reply paused needs_user waiting_capacity) do
      d = Repo.get!(Delegation, c.delegation.id) |> Delegation.hydrate()
      d |> Delegation.changeset(%{state: state}) |> Repo.update!()
      refute idle_coordinator?(agent.id, DateTime.add(now, 180, :day))
    end
  end

  @tag idle_coordinator: true
  test "recent completion, a stopped coordinator and a tripped guard all prevent retirement", c do
    agent = idle_coordinator(c)
    now = DateTime.utc_now()
    d = Repo.get!(Delegation, c.delegation.id) |> Delegation.hydrate()
    d |> Delegation.changeset(%{state: "expired"}) |> Repo.update!()
    refute idle_coordinator?(agent.id, now)

    later = DateTime.add(now, 8, :day)
    assert idle_coordinator?(agent.id, later)
    agent |> Ecto.Changeset.change(status: "stopped") |> Repo.update!()
    refute idle_coordinator?(agent.id, later)
    agent |> Ecto.Changeset.change(status: "running") |> Repo.update!()

    Repo.insert!(%Maraithon.Runtime.AgentRestartGuard{
      agent_id: agent.id,
      generation: Ecto.UUID.generate(),
      tripped: true
    })

    refute idle_coordinator?(agent.id, later)
  end

  @tag idle_coordinator: true
  test "an unfinished turn prevents an otherwise idle coordinator from retiring", c do
    agent = idle_coordinator(c)
    c = %{c | delegation: Repo.get!(Delegation, c.delegation.id) |> Delegation.hydrate()}
    assert {:ok, _} = Repo.transaction(fn -> decision_turn(c) end)
    d = Repo.get!(Delegation, c.delegation.id) |> Delegation.hydrate()
    d |> Delegation.changeset(%{state: "stopped"}) |> Repo.update!()
    refute idle_coordinator?(agent.id, DateTime.add(DateTime.utc_now(), 8, :day))
  end

  @tag idle_coordinator: true
  test "an unproven send prevents retirement even after its turn is superseded", c do
    alias Maraithon.Delegations.{Execution, Turn}
    alias Maraithon.TelegramAssistant.PreparedAction
    enable_gmail(c.user_id)
    agent = idle_coordinator(c)
    c = %{c | delegation: Repo.get!(Delegation, c.delegation.id) |> Delegation.hydrate()}

    assert {:ok, action} =
             Repo.transaction(fn ->
               {d, grant, event} = decision_turn(c)
               next = Execution.prepare!(d, grant, event, DateTime.utc_now())
               assert next.state == "sending"
               next |> Delegation.changeset(%{state: "stopped"}) |> Repo.update!()
               turn = Repo.one!(Turn) |> Turn.hydrate()
               turn |> Turn.changeset(%{status: "superseded"}) |> Repo.update!()
               Repo.one!(PreparedAction) |> PreparedAction.hydrate_payload()
             end)

    later = DateTime.add(DateTime.utc_now(), 8, :day)
    refute idle_coordinator?(agent.id, later)
    action |> PreparedAction.changeset(%{status: "expired"}) |> Repo.update!()
    assert idle_coordinator?(agent.id, later)
  end

  @tag idle_coordinator: true
  test "a sweep retires an empty coordinator once and a new delegation gets a new Agent", c do
    alias Maraithon.Runtime.{BackgroundJobs, ScheduledJob}
    alias Maraithon.Delegations.{Lifecycle, Wakes}
    agent = idle_coordinator(c)

    timer =
      %ScheduledJob{}
      |> ScheduledJob.changeset(%{
        agent_id: agent.id,
        job_type: "wakeup",
        fire_at: DateTime.add(DateTime.utc_now(), 3600)
      })
      |> Repo.insert!()

    assert {:ok, %{failures: []}} =
             Maraithon.DurablePayloadVerification.verify_batch("scheduled_jobs")

    {node, partitions} = exact_authority(c.user_id)
    configure(:process_role, :web)

    type = "runtime_recurring:delegation_due_sweep"
    {:ok, _} = BackgroundJobs.enqueue(type, %{user_id: c.user_id, payload: %{}})

    run_leased_job(node, partitions, type, fn job ->
      assert {:ok, %{retired: 1, repaired: 0, held: 0}} = Wakes.run_once(job)
      old = Repo.get!(Maraithon.Agents.Agent, agent.id)
      assert old.status == "stopped"
      assert old.install_status == "removed"
      assert Repo.reload!(timer).status == "cancelled"

      assert Repo.get!(Delegation, c.delegation.id).current_grant_id ==
               c.delegation.current_grant_id

      assert Repo.get_by!(Maraithon.AgentIsolation.Binding, agent_id: agent.id).status ==
               "revoked"

      assert {:ok, %{users: 0, retired: 0}} = Wakes.run_once(job)

      assert {:ok, _} =
               Maraithon.Runtime.JobAuthority.transaction(job, fn ->
                 d = Repo.get!(Delegation, c.delegation.id) |> Delegation.hydrate()
                 d |> Delegation.changeset(%{state: "waiting_reply"}) |> Repo.update!()
               end)

      assert {:ok, fresh} = Lifecycle.ensure(c.user_id, job: job)
      assert fresh.id != agent.id
      assert fresh.status == "running"

      assert Repo.get_by!(Maraithon.AgentIsolation.Binding, agent_id: fresh.id).identity_key !=
               Repo.get_by!(Maraithon.AgentIsolation.Binding, agent_id: agent.id).identity_key

      assert Repo.get!(Delegation, c.delegation.id).agent_id == fresh.id
      assert {:ok, same} = Lifecycle.ensure(c.user_id, job: job)
      assert same.id == fresh.id
      {:ok, %{retired: 1}}
    end)
  end

  @tag idle_coordinator: true
  test "a new conversation after candidate selection cancels retirement and stale jobs cannot stop",
       c do
    alias Maraithon.Runtime.{BackgroundJob, BackgroundJobs}
    agent = idle_coordinator(c)
    {node, partitions} = exact_authority(c.user_id)
    configure(:process_role, :web)
    type = "runtime_recurring:delegation_due_sweep"
    {:ok, _} = BackgroundJobs.enqueue(type, %{user_id: c.user_id, payload: %{}})
    assert idle_coordinator?(agent.id, DateTime.utc_now())

    run_leased_job(node, partitions, type, fn job ->
      assert {:error, :task_authority_lost} =
               Maraithon.Runtime.retire_delegation_coordinator(agent.id, %{
                 job
                 | claim_token: Ecto.UUID.generate()
               })

      assert {:ok, _} =
               Maraithon.Runtime.JobAuthority.transaction(job, fn ->
                 d = Repo.get!(Delegation, c.delegation.id) |> Delegation.hydrate()
                 d |> Delegation.changeset(%{state: "waiting_reply"}) |> Repo.update!()
               end)

      assert {:error, :coordinator_not_idle} =
               Maraithon.Runtime.retire_delegation_coordinator(agent.id, job)

      assert Repo.get!(Maraithon.Agents.Agent, agent.id).status == "running"
      assert Maraithon.Runtime.AgentLifecycleOperations.get(agent.id) == nil
      assert Repo.get!(BackgroundJob, job.id).status == "running"
      {:ok, %{retired: 0}}
    end)
  end

  defp idle_coordinator(c) do
    old = DateTime.add(DateTime.utc_now(), -8, :day)

    agent =
      Repo.insert!(%Maraithon.Agents.Agent{
        user_id: c.user_id,
        behavior: "delegation_coordinator",
        status: "running",
        inserted_at: old,
        started_at: old
      })

    {:ok, _} =
      Maraithon.AgentIsolation.grant_binding_consent(
        agent,
        binding_consent(agent, %{"identity_key" => "delegations:#{c.user_id}"})
      )

    c.delegation
    |> Delegation.changeset(%{state: "completed", agent_id: agent.id})
    |> Ecto.Changeset.put_change(:updated_at, old)
    |> Repo.update!()

    agent
  end

  defp idle_coordinator?(id, now),
    do:
      Repo.exists?(
        from a in Maraithon.Delegations.Lifecycle.idle_coordinators(now), where: a.id == ^id
      )

  test "six months of quiet checkpoints preserve the grant and admit one late reply", c do
    alias Maraithon.Behaviors.DelegationCoordinator, as: Behavior
    alias Maraithon.Runtime.BackgroundJob
    alias Maraithon.Delegations.Turn
    enable_gmail(c.user_id)

    agent =
      Repo.insert!(%Maraithon.Agents.Agent{user_id: c.user_id, behavior: "delegation_coordinator"})

    ledger = %{"facts" => "The original question is still waiting for Kent's answer."}

    d =
      c.delegation
      |> Delegation.changeset(%{agent_id: agent.id, data: %{"ledger" => ledger}})
      |> Repo.update!()

    grant = Maraithon.Delegations.current_grant(d)
    first = DateTime.add(d.inserted_at, 2)

    wake = fn state, now ->
      Behavior.handle_wakeup(state, %{
        user_id: c.user_id,
        agent_id: agent.id,
        write: fn callback ->
          Repo.transaction(fn ->
            Maraithon.PrivacyErasure.WriteFence.lock_user_writable!(c.user_id)
            callback.(now)
          end)
        end
      })
    end

    state =
      Enum.reduce(0..719, Behavior.init(%{}), fn tick, state ->
        now = DateTime.add(first, tick * 6, :hour)
        # A fresh decoded checkpoint models process memory being lost between wakes.
        restored = state |> Behavior.snapshot_state() |> Jason.encode!() |> Jason.decode!()
        restored = Behavior.reconcile_restored_state(restored, %{})
        assert {:idle, next} = wake.(restored, now)
        assert {:absolute, due} = Behavior.next_wakeup(next)
        assert DateTime.diff(due, now) == 6 * 3600
        assert byte_size(Jason.encode!(Behavior.snapshot_state(next))) < 1_024
        next
      end)

    assert Repo.aggregate(BackgroundJob, :count) == 0
    assert Repo.aggregate(Turn, :count) == 0
    assert Maraithon.Delegations.current_grant(d).id == grant.id

    assert Repo.get!(Delegation, d.id) |> Delegation.hydrate() |> Map.get(:data) == d.data

    now = DateTime.add(first, 180, :day)
    late = %{c.message | internal_date: now}
    route(c, late)
    route(c, late)
    assert {:idle, next} = wake.(state, now)
    assert {:idle, _} = wake.(next, now)
    assert Repo.aggregate(Turn, :count) == 1

    assert Repo.aggregate(
             from(j in BackgroundJob, where: j.job_type == "delegation_sync"),
             :count
           ) == 1

    assert Repo.one!(Turn).model_calls == 0
    assert Repo.get!(Delegation, d.id).lifetime_sends == 0
    assert Maraithon.Delegations.current_grant(d).id == grant.id
  end

  test "same subject or thread on a different account cannot wake this delegation", c do
    assert {:ok, :ok} = Repo.transaction(fn -> Ingress.gmail!(c.user_id, -1, c.message) end)
    route(c, %{c.message | thread_id: "different"})
    assert Repo.aggregate(Event, :count) == 0
    assert Repo.get!(Delegation, c.delegation.id).source_revision == 0
  end

  test "a transaction rollback also removes the revision and wake intent", c do
    assert {:error, :interrupted} =
             Repo.transaction(fn ->
               Ingress.gmail!(c.user_id, c.account.id, c.message)
               Repo.rollback(:interrupted)
             end)

    assert Repo.aggregate(Event, :count) == 0
    assert Repo.get!(Delegation, c.delegation.id).source_revision == 0
  end

  test "the Gmail source hook persists its observation and wake in the same transaction", c do
    assert {:error, :interrupted} =
             Repo.transaction(fn ->
               assert :ok =
                        Maraithon.Connectors.Gmail.ingest_messages(c.user_id, [c.message],
                          account: c.account
                        )

               assert Repo.aggregate(Maraithon.Crm.Observation, :count) == 1
               assert Repo.aggregate(Event, :count) == 1
               Repo.rollback(:interrupted)
             end)

    assert Repo.aggregate(Maraithon.Crm.Observation, :count) == 0
    assert Repo.aggregate(Event, :count) == 0
    assert Repo.get!(Delegation, c.delegation.id).source_revision == 0
  end

  test "a manual send from the bound account pauses, even though both participants are Kent", c do
    message = %{c.message | from: c.message.to, to: c.message.from, labels: ["SENT"]}
    assert Ingress.classify(message, c.scope) == "human_send"
    assert Ingress.classify(message, c.scope, true) == "own_send"

    {next, [:cancel_unentered, :notify_user]} =
      StateMachine.apply(
        c.delegation,
        %{kind: "inbound_message", data: %{"classification" => "human_send"}}
      )

    assert next.state == "paused"
  end

  test "a new participant holds the conversation for scope review", c do
    message = Map.put(c.message, :cc, "New Person <new@example.invalid>")
    assert Ingress.classify(message, c.scope) == "scope_change"

    {next, _} =
      StateMachine.apply(c.delegation, %{
        kind: "inbound_message",
        data: %{"classification" => "scope_change"}
      })

    assert next.state == "needs_user"
  end

  test "drafts, automated responses, bounces and stop requests are deterministic", c do
    assert Ingress.classify(%{c.message | labels: ["DRAFT"]}, c.scope) == "draft"

    assert Ingress.classify(Map.put(c.message, :auto_submitted, "auto-replied"), c.scope) ==
             "auto_reply"

    assert Ingress.classify(
             Map.merge(c.message, %{
               return_path: "<>",
               content_type: "multipart/report; report-type=delivery-status"
             }),
             c.scope
           ) == "bounce"

    assert Ingress.classify(%{c.message | text_body: "Please stop"}, c.scope) == "stop"
  end

  test "a late reply is retained without reopening a stopped conversation", c do
    c.delegation |> Delegation.changeset(%{state: "stopped"}) |> Repo.update!()
    route(c, c.message)
    assert Repo.get!(Delegation, c.delegation.id).state == "stopped"
    [event] = Repo.all(Event)
    assert event.wake_state == "consumed"
  end

  test "a counterparty stop request still stops a paused conversation", c do
    {next, [:cancel_unentered, :notify_user]} =
      StateMachine.apply(
        %{c.delegation | state: "paused"},
        %{kind: "inbound_message", data: %{"classification" => "stop"}}
      )

    assert next.state == "stopped"
  end

  test "turn, bound run and sync job are admitted once in the same transaction", c do
    alias Maraithon.Delegations.{Binding, Jobs, Turn}
    alias Maraithon.Runtime.{BackgroundJob, PeriodicJobs}
    alias Maraithon.TelegramAssistant.Run
    grant = Maraithon.Delegations.current_grant(c.delegation)
    event = %{id: Ecto.UUID.generate(), kind: "user_action"}

    assert {:ok, job} =
             Repo.transaction(fn ->
               Maraithon.PrivacyErasure.WriteFence.lock_user_writable!(c.user_id)
               now = Maraithon.Runtime.DatabaseClock.now!()
               next = Jobs.start_sync!(c.delegation, grant, event, now)
               assert next.state == "syncing"
               assert Jobs.start_sync!(next, grant, event, now).state == "syncing"
               [turn] = Repo.all(Turn) |> Enum.map(&Turn.hydrate/1)
               [run] = Repo.all(Run) |> Enum.map(&Run.hydrate_payloads/1)
               [job] = Repo.all(BackgroundJob) |> Enum.map(&BackgroundJob.hydrate_payloads/1)
               assert turn.run_id == run.id
               assert job.payload == run.prompt_snapshot[Binding.key()]
               assert job.queue == "runtime_provider_account"

               assert job.partition_key ==
                        PeriodicJobs.provider_partition(c.user_id, c.account.provider)

               assert job.rate_limit_key == "google"
               assert run.surface == "delegation"
               assert run.conversation_id == nil
               assert turn.model_calls == 0

               job
             end)

    assert {:error, :task_authority_required} =
             Jobs.transaction(job, fn _ -> flunk("unleased worker entered") end)
  end

  test "a failed admission leaves no turn, run, or job behind", c do
    grant = Maraithon.Delegations.current_grant(c.delegation)

    assert {:error, :interrupted} =
             Repo.transaction(fn ->
               Maraithon.Delegations.Jobs.start_sync!(
                 c.delegation,
                 grant,
                 %{id: Ecto.UUID.generate(), kind: "timer_due"},
                 DateTime.utc_now()
               )

               Repo.rollback(:interrupted)
             end)

    assert Repo.aggregate(Maraithon.Delegations.Turn, :count) == 0
    assert Repo.aggregate(Maraithon.TelegramAssistant.Run, :count) == 0
    assert Repo.aggregate(Maraithon.Runtime.BackgroundJob, :count) == 0
  end

  test "lost model responses remain reserved across turns and old budget windows", c do
    alias Maraithon.Delegations.{Actions, Authority, Binding, Budget, Jobs, Turn}
    alias Maraithon.TelegramAssistant.Run
    ready_cost_monitor()

    grant = Maraithon.Delegations.current_grant(c.delegation)
    event = %{id: Ecto.UUID.generate(), kind: "user_action"}

    assert {:ok, :checked} =
             Repo.transaction(fn ->
               Maraithon.PrivacyErasure.WriteFence.lock_user_writable!(c.user_id)
               now = Maraithon.Runtime.DatabaseClock.now!()
               d = Jobs.start_sync!(c.delegation, grant, event, now)
               d = c.delegation |> Delegation.changeset(%{state: d.state}) |> Repo.update!()
               run = Repo.one!(Run) |> Run.hydrate_payloads()
               binding = run.prompt_snapshot[Binding.key()]

               quote = %{
                 "model" => run.model_name,
                 "quoted_at" => DateTime.to_iso8601(now),
                 "reserved_micro_usd" => 105_268
               }

               assert :ok =
                        Budget.reserve!(
                          Authority.lock_context!(binding, c.user_id),
                          "compose",
                          quote
                        )

               assert {:error, :model_already_entered} =
                        Budget.reserve!(
                          Authority.lock_context!(binding, c.user_id),
                          "compose",
                          quote
                        )

               assert :ok =
                        Budget.reserve!(
                          Authority.lock_context!(binding, c.user_id),
                          "policy",
                          quote
                        )

               turn = Repo.one!(Turn) |> Turn.hydrate()
               assert turn.model_calls == 2
               assert turn.reserved_micro_usd == 210_536
               assert turn.cost_micro_usd == 0
               refute Actions.supersede_unentered!(d)

               Repo.get!(Turn, turn.id)
               |> Ecto.Changeset.change(updated_at: DateTime.add(now, -60, :day))
               |> Repo.update!()

               Jobs.start_sync!(d, grant, %{event | id: Ecto.UUID.generate()}, now)
               next_turn = Repo.get_by!(Turn, delegation_id: d.id, seq: 2)
               next_run = Repo.get!(Run, next_turn.run_id) |> Run.hydrate_payloads()
               next = Authority.lock_context!(next_run.prompt_snapshot[Binding.key()], c.user_id)
               assert {:error, :delegation_cost_limit} = Budget.reserve!(next, "compose", quote)
               assert Repo.get!(Turn, next_turn.id).model_calls == 0
               :checked
             end)
  end

  @tag signature: "-Kent"
  test "a verified turn freezes the exact mailbox, recipients, body and reply parent before the undo window",
       c do
    enable_gmail(c.user_id)
    alias Maraithon.Delegations.{Binding, Execution, Turn}
    alias Maraithon.Runtime.BackgroundJob
    alias Maraithon.TelegramAssistant.PreparedAction

    assert {:ok, action} =
             Repo.transaction(fn ->
               {d, grant, event} = decision_turn(c)
               now = Maraithon.Runtime.DatabaseClock.now!()

               run =
                 Repo.one!(Maraithon.TelegramAssistant.Run)
                 |> Maraithon.TelegramAssistant.Run.hydrate_payloads()

               snapshot =
                 Maraithon.Delegations.Voice.freeze(run.prompt_snapshot, c.user_id, c.scope)

               run
               |> Maraithon.TelegramAssistant.Run.changeset(%{prompt_snapshot: snapshot})
               |> Repo.update!()

               next = Execution.prepare!(d, grant, event, now)
               assert next.state == "sending"
               [action] = Repo.all(PreparedAction) |> Enum.map(&PreparedAction.hydrate_payload/1)
               assert action.authorization_kind == "delegation_grant"
               assert action.status == "confirmed"
               assert action.payload["account_id"] == c.account.id
               assert action.payload["to"] == "kent.fenwick@gmail.com"
               assert action.payload["from"] == "kent@runner.now"
               assert action.payload["body"] == "Got it. Indigo.\n\n-Kent"
               assert action.payload["thread_id"] == "aabbcc"
               assert action.payload["reply_to_message_id"] == c.message.message_id
               assert action.payload["_maraithon_voice_version"] == snapshot["voice"]["version"]
               assert is_binary(action.payload["_maraithon_confirmed_payload_sha256"])
               assert action.payload[Binding.key()]["delegation_id"] == d.id
               turn = Repo.get!(Turn, action.delegation_turn_id)
               assert turn.status == "dispatched"
               assert DateTime.diff(turn.available_at, now) >= 120
               jobs = Repo.all(BackgroundJob) |> Enum.map(&BackgroundJob.hydrate_payloads/1)
               [send_job] = Enum.filter(jobs, &(&1.job_type == "delegation_send"))
               [reconcile] = Enum.filter(jobs, &(&1.job_type == "assistant_action_reconcile"))
               assert send_job.payload["action_id"] == action.id
               assert send_job.scheduled_at == turn.available_at
               assert DateTime.compare(reconcile.scheduled_at, turn.available_at) == :gt
               assert Execution.prepare!(next, grant, event, now).state == "sending"
               assert Repo.aggregate(PreparedAction, :count) == 1
               assert Repo.get!(PreparedAction, action.id).status == "confirmed"
               action
             end)

    assert {:error, ^action, :delegation_job_required} =
             Maraithon.TelegramAssistant.execute_granted_action(action)

    assert Repo.get!(PreparedAction, action.id).status == "confirmed"
  end

  for previous_sends <- [0, 1] do
    @tag first_send_cc: ["observer@example.invalid"]
    test "prepared send after #{previous_sends} proven sends freezes the correct first-message Cc",
         c do
      enable_gmail(c.user_id)

      assert {:ok, :checked} =
               Repo.transaction(fn ->
                 {d, grant, event} = decision_turn(c)

                 d =
                   d
                   |> Delegation.changeset(%{lifetime_sends: unquote(previous_sends)})
                   |> Repo.update!()

                 next =
                   Maraithon.Delegations.Execution.prepare!(d, grant, event, DateTime.utc_now())

                 assert next.state == "sending"

                 action =
                   Repo.one!(Maraithon.TelegramAssistant.PreparedAction)
                   |> Maraithon.TelegramAssistant.PreparedAction.hydrate_payload()

                 expected =
                   if unquote(previous_sends) == 0, do: "observer@example.invalid", else: ""

                 assert action.payload["cc"] == expected
                 :checked
               end)
    end
  end

  test "a changed todo prevents even a reviewed model decision from becoming a send", c do
    enable_gmail(c.user_id)

    assert {:ok, :held} =
             Repo.transaction(fn ->
               {d, grant, event} = decision_turn(c)

               assert {:ok, _} =
                        Maraithon.Todos.transition_workflow(c.user_id, d.todo_id, %{
                          "state" => "working",
                          "owner" => %{"kind" => "user"},
                          "expected_revision" => d.workflow_revision,
                          "next_action" => "Review the changed task.",
                          "reason" => "The user changed the next move.",
                          "request_id" => Ecto.UUID.generate()
                        })

               next =
                 Maraithon.Delegations.Execution.prepare!(d, grant, event, DateTime.utc_now())

               assert next.state == "needs_user"
               assert Repo.aggregate(Maraithon.TelegramAssistant.PreparedAction, :count) == 0
               :held
             end)
  end

  @tag tracked_owner: true
  test "waiting and clarification preserve Charlie as the owner", c do
    alias Maraithon.Delegations.Outcomes
    alias Maraithon.Todos.{Todo, Workflow}
    owner = c.scope["task_owner"]
    grant = Maraithon.Delegations.current_grant(c.delegation)
    event = %{id: Ecto.UUID.generate(), data: %{}}

    assert {:ok, :checked} =
             Repo.transaction(fn ->
               Maraithon.PrivacyErasure.WriteFence.lock_user_writable!(c.user_id)
               waiting = Outcomes.follow_up(c.delegation, grant, DateTime.utc_now())
               waiting = Outcomes.apply(waiting, grant, event, :progress)
               assert waiting.state == "waiting_reply"
               todo = Repo.get!(Todo, waiting.todo_id)
               assert Workflow.current(todo)["state"] == "waiting"
               assert Workflow.current(todo)["owner"] == owner

               Maraithon.Todos.review_waiting_workflows(
                 c.user_id,
                 DateTime.add(waiting.follow_up_at, 1)
               )

               assert Workflow.current(Repo.get!(Todo, waiting.todo_id))["revision"] ==
                        waiting.workflow_revision

               review =
                 Outcomes.apply(
                   %{waiting | state: "needs_user", data: %{"question" => "Which date?"}},
                   grant,
                   %{event | id: Ecto.UUID.generate()},
                   :progress
                 )

               assert review.state == "needs_user"
               todo = Repo.get!(Todo, waiting.todo_id)
               assert Workflow.current(todo)["state"] == "they_own"
               assert Workflow.current(todo)["owner"] == owner
               :checked
             end)
  end

  @tag tracked_owner: true
  test "a due waiting review preserves another person's ownership after delegation ends", c do
    alias Maraithon.Delegations.Outcomes
    alias Maraithon.Todos.{Todo, Workflow}

    assert {:ok, :checked} =
             Repo.transaction(fn ->
               Maraithon.PrivacyErasure.WriteFence.lock_user_writable!(c.user_id)
               grant = Maraithon.Delegations.current_grant(c.delegation)
               waiting = Outcomes.follow_up(c.delegation, grant, DateTime.utc_now())
               Outcomes.apply(waiting, grant, %{id: Ecto.UUID.generate(), data: %{}}, :progress)
               c.delegation |> Delegation.changeset(%{state: "stopped"}) |> Repo.update!()

               Maraithon.Todos.review_waiting_workflows(
                 c.user_id,
                 DateTime.add(waiting.follow_up_at, 1)
               )

               workflow = Workflow.current(Repo.get!(Todo, waiting.todo_id))
               assert workflow["state"] == "they_own"
               assert workflow["owner"] == c.scope["task_owner"]
               :checked
             end)
  end

  for proven <- [true, false] do
    @tag outcome_proven: proven
    test "completion requires independent outcome proof (#{proven})", c do
      alias Maraithon.Delegations.{Outcomes, Turn}
      alias Maraithon.Todos.{Todo, Workflow}

      assert {:ok, :checked} =
               Repo.transaction(fn ->
                 {d, grant, event} = decision_turn(c)
                 turn = Repo.get!(Turn, event.data["turn_id"]) |> Turn.hydrate()

                 turn
                 |> Turn.changeset(%{
                   data:
                     Map.merge(turn.data, %{
                       "decision" => %{
                         "kind" => "complete",
                         "reason" => "The colour is indigo.",
                         "evidence" => [c.message.message_id]
                       },
                       "policy_review" => %{
                         "allowed" => true,
                         "outcome_proven" => c.outcome_proven,
                         "reason" => "Checked against the reply"
                       }
                     })
                 })
                 |> Repo.update!()

                 result = Outcomes.apply(%{d | state: "completed"}, grant, event, :complete)
                 todo = Repo.get!(Todo, d.todo_id)

                 if c.outcome_proven do
                   assert result.state == "completed"
                   assert Workflow.current(todo)["state"] == "done"
                   assert Repo.get!(Turn, turn.id).status == "settled"
                 else
                   assert result.state == "needs_user"
                   assert todo.status == "open"
                 end

                 :checked
               end)
    end
  end

  for admission <- [:ready, :cooldown, :provider_cooldown, :repair, :repair_fails] do
    @tag admission: admission
    test "a leased model turn with #{admission} admission charges only provider entries", c do
      alias Maraithon.Delegations.{Decision, Jobs, Turn}
      alias Maraithon.LLM.OpenRouterProvider
      enable_gmail(c.user_id)
      {node, partitions} = exact_authority(c.user_id)
      bypass = Bypass.open()
      model = "meta/muse-spark-1.3-contributor"
      runtime = Application.get_env(:maraithon, Maraithon.Runtime, [])

      configure(
        Maraithon.Runtime,
        Keyword.merge(runtime,
          llm_provider: OpenRouterProvider,
          llm_provider_name: "openrouter",
          openrouter_model: model,
          openrouter_api_key: "local-eval-only"
        )
      )

      configure(:openrouter,
        base_url: "http://localhost:#{bypass.port}/api/v1/chat/completions",
        models_base_url: "http://localhost:#{bypass.port}/api/v1/models"
      )

      ready_cost_monitor()
      calls = start_supervised!({Agent, fn -> 0 end})

      Bypass.expect(bypass, "GET", "/api/v1/models/#{model}/endpoints", fn conn ->
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

      Bypass.stub(bypass, "POST", "/api/v1/chat/completions", fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        request = Jason.decode!(raw)
        assert request["model"] == model
        assert request["provider"]["only"] == ["meta"]

        assert Decimal.equal?(
                 Decimal.new(request["provider"]["max_price"]["prompt"]),
                 Decimal.new("0.1")
               )

        n = Agent.get_and_update(calls, &{&1 + 1, &1 + 1})
        assert c.admission != :cooldown
        expected_calls = if c.admission == :repair, do: 3, else: 2
        assert n <= expected_calls

        if c.admission == :provider_cooldown do
          conn
          |> Plug.Conn.put_resp_header("retry-after", "60")
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.resp(
            429,
            Jason.encode!(%{"error" => %{"code" => 429, "message" => "Rate limited"}})
          )
        else
          decision = %{
            "kind" => "send",
            "body" => "Got it. Indigo.",
            "reason" => "Confirm the answer",
            "evidence" => [c.message.message_id]
          }

          content =
            cond do
              c.admission == :repair_fails or (c.admission == :repair and n == 1) ->
                Map.delete(decision, "body")

              n == 1 or (c.admission == :repair and n == 2) ->
                decision

              true ->
                %{"allowed" => true, "outcome_proven" => true, "reason" => "Matches the source"}
            end

          json(conn, %{
            "id" => "gen-#{n}",
            "model" => model,
            "choices" => [
              %{
                "finish_reason" => "stop",
                "message" => %{"role" => "assistant", "content" => Jason.encode!(content)}
              }
            ],
            "usage" => %{
              "prompt_tokens" => 500,
              "completion_tokens" => 100,
              "total_tokens" => 600,
              "cost" => 0.0001
            }
          })
        end
      end)

      assert {:ok, _} =
               Repo.transaction(fn ->
                 {d, _grant, event} = decision_turn(c)
                 turn = Repo.get!(Turn, event.data["turn_id"]) |> Turn.hydrate()

                 turn
                 |> Turn.changeset(%{
                   status: "deciding",
                   data: Map.drop(turn.data, ~w(decision policy_review))
                 })
                 |> Repo.update!()

                 Jobs.start_decide!(d, event, DateTime.utc_now())
               end)

      limiter = Maraithon.Runtime.Effects.LLMRateLimiter
      on_exit(fn -> limiter.reset() end)
      if c.admission == :cooldown, do: limiter.record_rate_limit(60_000, :reasoning)

      run_leased_job(node, partitions, "delegation_decide", fn job ->
        expected =
          case c.admission do
            :cooldown -> "waiting_capacity"
            :provider_cooldown -> "waiting_capacity"
            :repair_fails -> "needs_user"
            _ -> "decided"
          end

        assert {:ok, %{state: ^expected}} = Decision.execute(job)

        run =
          Repo.get!(Maraithon.TelegramAssistant.Run, job.payload["run_id"])
          |> Maraithon.TelegramAssistant.Run.hydrate_payloads()

        assert is_binary(run.prompt_snapshot["voice"]["version"])
        assert {:ok, %{state: ^expected}} = result = Decision.execute(job)

        retried =
          Repo.get!(Maraithon.TelegramAssistant.Run, run.id)
          |> Maraithon.TelegramAssistant.Run.hydrate_payloads()

        assert retried.prompt_snapshot["voice"] == run.prompt_snapshot["voice"]
        result
      end)

      if c.admission in [:cooldown, :provider_cooldown] do
        expected_calls = if c.admission == :provider_cooldown, do: 1, else: 0
        assert Agent.get(calls, & &1) == expected_calls
        turn = Repo.one!(Turn) |> Turn.hydrate()
        assert turn.model_calls == expected_calls
        assert turn.cost_micro_usd == 0

        if c.admission == :provider_cooldown do
          assert turn.reserved_micro_usd > 0
          assert turn.data["model_entries"]["compose"]["state"] == "entered"
        else
          assert turn.reserved_micro_usd == 0
          assert turn.data["model_entries"] == nil
        end

        assert {:ok, _} =
                 Repo.transaction(fn ->
                   d = Repo.get!(Delegation, c.delegation.id) |> Delegation.hydrate()

                   event =
                     Repo.one!(from e in Event, where: e.kind == "capacity_hold")
                     |> Event.hydrate()

                   {d, commands} = StateMachine.apply(d, event)

                   next =
                     Maraithon.Delegations.Commands.apply(
                       d,
                       nil,
                       event,
                       commands,
                       DateTime.utc_now()
                     )

                   assert next.state == "waiting_capacity"
                   assert DateTime.diff(next.next_wake_at, DateTime.utc_now()) in 59..61
                   assert Repo.get!(Turn, turn.id).status == "superseded"
                   assert Repo.get!(Turn, turn.id).reserved_micro_usd == turn.reserved_micro_usd

                   assert {%{state: "ready"}, [:enqueue_sync]} =
                            StateMachine.apply(next, %{
                              kind: "timer_due",
                              occurred_at: next.next_wake_at
                            })
                 end)
      else
        expected_calls = if c.admission == :repair, do: 3, else: 2
        assert Agent.get(calls, & &1) == expected_calls
        turn = Repo.one!(Turn) |> Turn.hydrate()
        assert turn.status == if(c.admission == :repair_fails, do: "deciding", else: "validated")
        assert turn.model_calls == expected_calls
        assert turn.reserved_micro_usd == 0
        assert turn.cost_micro_usd == expected_calls * 100
        assert Repo.get!(Delegation, c.delegation.id).lifetime_micro_usd == expected_calls * 100
        expected_decisions = if c.admission == :repair_fails, do: 0, else: 1

        assert Repo.aggregate(from(e in Event, where: e.kind == "decision"), :count) ==
                 expected_decisions

        if c.admission in [:repair, :repair_fails],
          do: assert(turn.data["model_entries"]["repair"]["state"] == "settled")

        assert Repo.aggregate(Maraithon.TelegramAssistant.PreparedAction, :count) == 0
      end
    end
  end

  @tag controlled_eval: true
  test "the live eval driver sends its fixed initial email once across a checkpoint retry", c do
    alias Maraithon.Delegations.EvaluationRunner
    alias Maraithon.Runtime.BackgroundJobs
    enable_gmail(c.user_id)
    configure(:delegation_eval_only, true)
    {node, partitions} = exact_authority(c.user_id)
    bypass = Bypass.open()
    configure(:gmail, api_base_url: "http://localhost:#{bypass.port}")

    sender =
      Repo.insert!(%Maraithon.Accounts.ConnectedAccount{
        user_id: c.user_id,
        provider: "google:personal-eval",
        status: "connected",
        metadata: %{"email" => "kent.fenwick@gmail.com"}
      })

    for provider <- [sender.provider, c.account.provider] do
      assert {:ok, _} =
               Maraithon.OAuth.store_tokens(c.user_id, provider, %{
                 access_token: "local-eval-only",
                 refresh_token: "fixture",
                 expires_in: 3600,
                 scopes: ["https://www.googleapis.com/auth/gmail.compose"]
               })
    end

    Bypass.expect_once(
      bypass,
      "GET",
      "/users/me/settings/sendAs",
      &json(
        &1,
        %{"sendAs" => [%{"isPrimary" => true, "sendAsEmail" => "kent.fenwick@gmail.com"}]}
      )
    )

    Bypass.expect_once(bypass, "POST", "/users/me/messages/send", fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      mime = raw |> Jason.decode!() |> Map.fetch!("raw") |> Base.url_decode64!(padding: false)
      assert mime =~ "From: kent.fenwick@gmail.com\r\n"
      assert mime =~ "To: kent@runner.now\r\n"
      assert mime =~ "Subject: [Maraithon eval] local\r\n"
      assert mime =~ ~r/Message-ID: <maraithon\.[a-f0-9-]+@maraithon\.com>\r\n/
      json(conn, %{"id" => "778899", "threadId" => "aabbcc"})
    end)

    Bypass.expect(bypass, "GET", "/users/me/messages/778899", fn conn ->
      json(conn, %{
        "id" => "778899",
        "threadId" => "aabbcc",
        "labelIds" => ["SENT"],
        "payload" => %{
          "headers" => [%{"name" => "Message-ID", "value" => "<rewritten@mail.gmail.com>"}]
        }
      })
    end)

    Bypass.expect(bypass, "GET", "/users/me/messages", fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)
      assert conn.query_params["q"] == "in:anywhere rfc822msgid:<rewritten@mail.gmail.com>"
      json(conn, %{"messages" => []})
    end)

    assert {:ok, _} =
             BackgroundJobs.enqueue("delegation_eval", %{
               user_id: c.user_id,
               payload: %{
                 "scenario" => hd(Maraithon.Delegations.Evaluation.scenarios()["scenarios"]),
                 "subject" => "[Maraithon eval] local",
                 "sender_account_id" => sender.id,
                 "owner_account_id" => c.account.id,
                 "deadline" => DateTime.to_iso8601(DateTime.add(DateTime.utc_now(), 3600))
               }
             })

    run_leased_job(node, partitions, "delegation_eval", fn job ->
      for _ <- 1..2 do
        assert {:ok, %{"phase" => "waiting_for_initial_email"}, {:reschedule_in, 30_000}} =
                 EvaluationRunner.execute(job)
      end

      {:ok, %{state: "checked"}}
    end)

    assert Repo.aggregate(Maraithon.TelegramAssistant.PreparedAction, :count) == 1
  end

  for busy <- [false, true] do
    @tag busy_slot: busy
    test "a leased booking rechecks availability (busy=#{busy})", c do
      alias Maraithon.Delegations.{Commands, Execution, Policy, Receipts, Turn}
      alias Maraithon.TelegramAssistant.PreparedAction
      enable_gmail(c.user_id)
      {node, partitions} = exact_authority(c.user_id)
      bypass = Bypass.open()
      configure(:gmail, api_base_url: "http://localhost:#{bypass.port}")
      configure(:google_calendar, api_base_url: "http://localhost:#{bypass.port}")

      assert {:ok, _} =
               Maraithon.OAuth.store_tokens(c.user_id, c.account.provider, %{
                 access_token: "bound-calendar",
                 refresh_token: "fixture",
                 expires_in: 3600,
                 scopes: [
                   "https://www.googleapis.com/auth/gmail.compose",
                   "https://www.googleapis.com/auth/calendar"
                 ]
               })

      start_at = DateTime.new!(Date.add(Date.utc_today(), 2), ~T[15:00:00], "Etc/UTC")

      slot = %{
        "start_at" => DateTime.to_iso8601(start_at),
        "end_at" => DateTime.to_iso8601(DateTime.add(start_at, 1800)),
        "timezone" => "America/Toronto"
      }

      Bypass.expect_once(
        bypass,
        "GET",
        "/users/me/threads/aabbcc",
        &json(&1, %{"messages" => [provider_message(c.message)]})
      )

      Bypass.expect_once(bypass, "GET", "/calendars/primary/events", fn conn ->
        assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer bound-calendar"]

        events =
          if c.busy_slot,
            do: [
              %{
                "id" => "busy",
                "start" => %{"dateTime" => slot["start_at"]},
                "end" => %{"dateTime" => slot["end_at"]}
              }
            ],
            else: []

        json(conn, %{"items" => events})
      end)

      unless c.busy_slot do
        Bypass.expect_once(bypass, "POST", "/calendars/primary/events", fn conn ->
          conn = Plug.Conn.fetch_query_params(conn)
          assert conn.query_params["sendUpdates"] == "all"
          {:ok, raw, conn} = Plug.Conn.read_body(conn)
          event = Jason.decode!(raw)
          assert event["attendees"] == [%{"email" => "kent.fenwick@gmail.com"}]
          assert event["start"]["dateTime"] == slot["start_at"]
          assert event["end"]["dateTime"] == slot["end_at"]
          json(conn, Map.put(event, "status", "confirmed"))
        end)
      end

      assert {:ok, action} =
               Repo.transaction(fn ->
                 Maraithon.PrivacyErasure.WriteFence.lock_user_writable!(c.user_id)

                 d =
                   c.delegation
                   |> Delegation.changeset(%{
                     kind: "scheduling",
                     data: %{
                       "offered_slots" => [slot],
                       "offered_calendar_account_ids" => [c.account.id]
                     }
                   })
                   |> Repo.update!()

                 {d, grant, event} = decision_turn(%{c | delegation: d})
                 turn = Repo.get!(Turn, event.data["turn_id"]) |> Turn.hydrate()

                 turn
                 |> Turn.changeset(%{
                   data:
                     Map.merge(turn.data, %{
                       "decision" => %{
                         "kind" => "book",
                         "accepted_slot_id" => Policy.slot_id(slot),
                         "reason" => "Accepted offered time",
                         "evidence" => [c.message.message_id]
                       },
                       "policy_review" => %{
                         "allowed" => true,
                         "outcome_proven" => false,
                         "reason" => "Accepted offered time"
                       }
                     })
                 })
                 |> Repo.update!()

                 now = Maraithon.Runtime.DatabaseClock.now!()
                 next = Execution.prepare!(d, grant, event, now)
                 assert next.state == "sending"
                 d |> Delegation.changeset(%{state: next.state}) |> Repo.update!()
                 turn = Repo.get!(Turn, turn.id) |> Turn.hydrate()
                 turn |> Turn.changeset(%{available_at: DateTime.add(now, -1)}) |> Repo.update!()
                 Repo.get!(PreparedAction, turn.prepared_action_id)
               end)

      run_leased_job(node, partitions, "delegation_send", fn job ->
        expected = if c.busy_slot, do: "failed", else: "sent"
        assert {:ok, %{state: ^expected}} = result = Execution.execute(job)
        result
      end)

      assert {:ok, :checked} =
               Repo.transaction(fn ->
                 Maraithon.PrivacyErasure.WriteFence.lock_user_writable!(c.user_id)
                 d = Repo.get!(Delegation, c.delegation.id) |> Delegation.hydrate()

                 event =
                   Repo.one!(
                     from e in Event,
                       where:
                         e.event_key ==
                           ^"action:#{action.id}:#{if(c.busy_slot, do: "failed", else: "executed")}"
                   )
                   |> Event.hydrate()

                 assert Receipts.valid_event?(d, event)
                 {next, commands} = StateMachine.apply(d, event)

                 if c.busy_slot do
                   assert next.state == "ready"
                   assert next.data["slot_reoffers"] == 1
                   assert next.data["offered_slots"] == nil
                   assert commands == [:enqueue_sync]
                 else
                   result =
                     Commands.apply(
                       next,
                       Maraithon.Delegations.current_grant(d),
                       event,
                       commands,
                       DateTime.utc_now()
                     )

                   assert result.state == "completed"
                   todo = Repo.get!(Maraithon.Todos.Todo, d.todo_id)
                   assert Maraithon.Todos.Workflow.current(todo)["state"] == "waiting"

                   assert Maraithon.Todos.Workflow.current(todo)["waiting_until"] ==
                            slot["start_at"]
                 end

                 :checked
               end)
    end
  end

  defp decision_turn(c) do
    alias Maraithon.Delegations.{Jobs, Sources, Turn}
    alias Maraithon.TelegramAssistant.Run
    Maraithon.PrivacyErasure.WriteFence.lock_user_writable!(c.user_id)
    grant = Maraithon.Delegations.current_grant(c.delegation)
    event = %{id: Ecto.UUID.generate(), kind: "user_action"}
    Jobs.start_sync!(c.delegation, grant, event, DateTime.utc_now())
    d = c.delegation |> Delegation.changeset(%{state: "deciding"}) |> Repo.update!()
    turn = Repo.one!(Turn) |> Turn.hydrate()
    run = Repo.get!(Run, turn.run_id) |> Run.hydrate_payloads()
    {:ok, sources} = Sources.snapshot([c.message], c.account.id, "aabbcc")

    run
    |> Run.changeset(%{
      status: "completed",
      prompt_snapshot: Map.put(run.prompt_snapshot, "sources", sources)
    })
    |> Repo.update!()

    decision = %{
      "kind" => "send",
      "body" => "Got it. Indigo.",
      "reason" => "Confirm the answer",
      "evidence" => [c.message.message_id]
    }

    turn
    |> Turn.changeset(%{
      status: "validated",
      data:
        Map.merge(turn.data, %{
          "decision" => decision,
          "policy_review" => %{"allowed" => true, "reason" => "Matches the source"}
        })
    })
    |> Repo.update!()

    {d, grant, %{id: Ecto.UUID.generate(), kind: "decision", data: %{"turn_id" => turn.id}}}
  end

  for response <- [:accepted, :lost_response, :rewritten_response, :unproven] do
    @tag timeout: 30_000, send_response: response
    test "leased sender #{response} never replays an entered send", c do
      alias Maraithon.Delegations.{Execution, Turn}
      alias Maraithon.Runtime.BackgroundJob
      alias Maraithon.TelegramAssistant.PreparedAction
      enable_gmail(c.user_id)
      {node, partitions} = exact_authority(c.user_id)
      bypass = Bypass.open()
      accepted = start_supervised!({Agent, fn -> nil end})
      original = Application.get_env(:maraithon, :gmail, [])
      Application.put_env(:maraithon, :gmail, api_base_url: "http://localhost:#{bypass.port}")
      on_exit(fn -> Application.put_env(:maraithon, :gmail, original) end)

      {:ok, _} =
        Maraithon.OAuth.store_tokens(c.user_id, "google:eval", %{
          access_token: "local-eval-only",
          refresh_token: "fixture",
          expires_in: 3600,
          scopes: ["https://www.googleapis.com/auth/gmail.compose"]
        })

      message = provider_message(c.message)

      Bypass.expect_once(
        bypass,
        "GET",
        "/users/me/threads/aabbcc",
        &json(&1, %{"messages" => [message]})
      )

      Bypass.expect_once(
        bypass,
        "GET",
        "/users/me/messages/#{c.message.message_id}",
        &json(&1, message)
      )

      Bypass.expect_once(
        bypass,
        "GET",
        "/users/me/settings/sendAs",
        &json(&1, %{"sendAs" => [%{"isPrimary" => true, "sendAsEmail" => "kent@runner.now"}]})
      )

      Bypass.expect_once(bypass, "POST", "/users/me/messages/send", fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        sent = raw |> Jason.decode!() |> Map.fetch!("raw") |> Base.url_decode64!(padding: false)
        assert sent =~ "To: kent.fenwick@gmail.com\r\n"
        assert sent =~ "From: kent@runner.now\r\n"
        assert sent =~ "Got it. Indigo."
        Agent.update(accepted, fn _ -> sent end)

        if c.send_response == :accepted,
          do: json(conn, %{"id" => "445566", "threadId" => "aabbcc"}),
          else: Plug.Conn.resp(conn, 503, "Lost response after accepting the message")
      end)

      assert {:ok, action} =
               Repo.transaction(fn ->
                 {d, grant, event} = decision_turn(c)
                 now = Maraithon.Runtime.DatabaseClock.now!()
                 next = Execution.prepare!(d, grant, event, now)
                 assert next.state == "sending"
                 d |> Delegation.changeset(%{state: next.state}) |> Repo.update!()
                 action = Repo.one!(PreparedAction) |> PreparedAction.hydrate_payload()
                 # Advance the fixture past undo without sleeping or changing the payload.
                 turn = Repo.get!(Turn, action.delegation_turn_id) |> Turn.hydrate()
                 turn |> Turn.changeset(%{available_at: DateTime.add(now, -1)}) |> Repo.update!()

                 job =
                   Repo.get_by!(BackgroundJob, job_type: "delegation_send")
                   |> BackgroundJob.hydrate_payloads()

                 job
                 |> BackgroundJob.changeset(%{
                   queue: "delegation_eval_send",
                   scheduled_at: DateTime.add(now, -1)
                 })
                 |> Repo.update!()

                 action
               end)

      run_leased_job(node, partitions, "delegation_send", fn job ->
        result = Execution.execute(job)

        if c.send_response == :accepted do
          assert {:ok, %{state: "sent"}} = result
          assert {:ok, %{state: "superseded"}} = Execution.execute(job)
        else
          assert {:ok, %{state: "reconciling"}} = result
          assert {:ok, %{state: "reconciling"}} = Execution.execute(job)
        end

        result
      end)

      if c.send_response != :accepted do
        alias Maraithon.TelegramAssistant.ActionReconciliation
        assert Repo.get!(PreparedAction, action.id).status == "execution_unknown"
        assert Repo.get!(Delegation, c.delegation.id).lifetime_sends == 0

        Bypass.expect_once(bypass, "GET", "/users/me/messages", fn conn ->
          json(conn, %{
            "messages" =>
              if(c.send_response == :lost_response, do: [%{"id" => "445566"}], else: [])
          })
        end)

        if c.send_response in [:lost_response, :rewritten_response] do
          path =
            if c.send_response == :lost_response,
              do: "/users/me/messages/445566",
              else: "/users/me/threads/aabbcc"

          Bypass.expect_once(bypass, "GET", path, fn conn ->
            [headers, body] = String.split(Agent.get(accepted, & &1), "\r\n\r\n", parts: 2)

            headers =
              Enum.map(String.split(headers, "\r\n"), fn line ->
                [name, value] = String.split(line, ":", parts: 2)
                %{"name" => name, "value" => String.trim(value)}
              end)

            headers =
              if c.send_response == :rewritten_response do
                [
                  %{"name" => "Message-ID", "value" => "<rewritten@mail.gmail.com>"}
                  | Enum.map(headers, fn h ->
                      if String.downcase(h["name"]) == "message-id",
                        do: %{h | "name" => "X-Google-Original-Message-ID"},
                        else: h
                    end)
                ]
              else
                headers
              end

            message = %{
              "id" => "445566",
              "threadId" => "aabbcc",
              "labelIds" => ["SENT"],
              "payload" => %{
                "headers" => headers,
                "body" => %{"data" => Base.url_encode64(body, padding: false)}
              }
            }

            json(
              conn,
              if(c.send_response == :rewritten_response,
                do: %{"id" => "aabbcc", "messages" => [message]},
                else: message
              )
            )
          end)
        else
          Bypass.expect_once(
            bypass,
            "GET",
            "/users/me/threads/aabbcc",
            &json(&1, %{"id" => "aabbcc", "messages" => []})
          )

          observer =
            Repo.get_by!(BackgroundJob, job_type: "assistant_action_reconcile")
            |> BackgroundJob.hydrate_payloads()

          observer |> BackgroundJob.changeset(%{result: %{"checks" => 11}}) |> Repo.update!()
        end

        run_leased_job(node, partitions, "assistant_action_reconcile", fn job ->
          result = ActionReconciliation.execute(job)

          expected =
            if c.send_response in [:lost_response, :rewritten_response],
              do: "executed",
              else: "needs_review"

          assert {:ok, %{state: ^expected}} = result
          result
        end)
      end

      if c.send_response in [:accepted, :lost_response, :rewritten_response] do
        assert {:ok, :ok} =
                 Repo.transaction(fn ->
                   Maraithon.PrivacyErasure.WriteFence.lock_user_writable!(c.user_id)

                   Ingress.gmail!(
                     c.user_id,
                     c.account.id,
                     Map.merge(c.message, %{
                       message_id: "445566",
                       internet_message_id: "<changed@mail.gmail.com>",
                       from: "kent@runner.now",
                       to: "kent.fenwick@gmail.com",
                       labels: ["SENT"],
                       internal_date: DateTime.utc_now()
                     })
                   )
                 end)

        echo = Repo.get_by!(Event, event_key: "gmail:#{c.account.id}:445566") |> Event.hydrate()
        assert echo.data["classification"] == "own_send"
      end

      if c.send_response == :unproven do
        assert Repo.get!(PreparedAction, action.id).status == "execution_unknown"

        [review] =
          Repo.all(from e in Event, where: e.kind == "reconciliation_exhausted")
          |> Enum.map(&Event.hydrate/1)

        d = Repo.get!(Delegation, c.delegation.id) |> Delegation.hydrate()
        assert Maraithon.Delegations.Receipts.valid_event?(d, review)
        {next, _} = StateMachine.apply(%{d | state: "reconciling"}, review)
        assert next.state == "needs_user"
        assert Repo.aggregate(from(e in Event, where: e.kind == "send_receipt"), :count) == 0
      else
        assert Repo.get!(PreparedAction, action.id).status == "executed"
        assert Repo.get!(Turn, action.delegation_turn_id).status == "settled"
        assert Repo.get!(Delegation, c.delegation.id).lifetime_sends == 1

        assert (Repo.get!(Delegation, c.delegation.id)
                |> Delegation.hydrate()).data["last_action"] == "Sent a message."

        assert Repo.aggregate(from(e in Event, where: e.kind == "send_receipt"), :count) == 1
      end
    end
  end

  defp run_leased_job(node, partitions, type, fun) do
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

  defp configure(key, value) do
    original = Application.get_env(:maraithon, key)
    Application.put_env(:maraithon, key, value)

    on_exit(fn ->
      if original == nil,
        do: Application.delete_env(:maraithon, key),
        else: Application.put_env(:maraithon, key, original)
    end)
  end

  defp ready_cost_monitor do
    alias Maraithon.LLM.CostMonitor
    alias Maraithon.Runtime.BackgroundJobs
    original = Application.get_env(:maraithon, CostMonitor)
    Application.put_env(:maraithon, CostMonitor, enabled: true, projected_daily_usd: 3.0)

    on_exit(fn ->
      if original,
        do: Application.put_env(:maraithon, CostMonitor, original),
        else: Application.delete_env(:maraithon, CostMonitor)
    end)

    assert {:ok, _} =
             BackgroundJobs.enqueue("runtime_recurring:llm_cost_monitor", %{
               result: %{
                 "status" => "within_budget",
                 "checked_at" => DateTime.to_iso8601(DateTime.utc_now()),
                 "daily_cost_usd" => 0,
                 "rolling_cost_usd" => 0,
                 "threshold_usd" => 6,
                 "key_fingerprint" =>
                   :crypto.hash(:sha256, Maraithon.LLM.openrouter_api_key() || "")
                   |> Base.encode16(case: :lower)
               }
             })
  end

  defp exact_authority(user_id) do
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

  defp provider_message(message) do
    %{
      "id" => message.message_id,
      "threadId" => "aabbcc",
      "labelIds" => ["INBOX"],
      "internalDate" => to_string(DateTime.to_unix(message.internal_date, :millisecond)),
      "payload" => %{
        "mimeType" => "text/plain",
        "body" => %{"data" => Base.url_encode64(message.text_body, padding: false)},
        "headers" =>
          Enum.map(
            [
              {"From", message.from},
              {"To", message.to},
              {"Subject", message.subject},
              {"Message-ID", message.internet_message_id}
            ],
            fn {k, v} -> %{"name" => k, "value" => v} end
          )
      }
    }
  end

  defp json(conn, value),
    do:
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(value))

  defp enable_gmail(user_id) do
    for {key, value} <- [
          delegations_enabled: true,
          delegation_user_allowlist: [user_id],
          delegation_sends_enabled: %{gmail: true}
        ] do
      original = Application.get_env(:maraithon, key)
      Application.put_env(:maraithon, key, value)

      on_exit(fn ->
        if original == nil,
          do: Application.delete_env(:maraithon, key),
          else: Application.put_env(:maraithon, key, original)
      end)
    end
  end

  defp route(c, message) do
    assert {:ok, :ok} =
             Repo.transaction(fn ->
               Maraithon.PrivacyErasure.WriteFence.lock_user_writable!(c.user_id)
               Ingress.gmail!(c.user_id, c.account.id, message)
             end)
  end
end
