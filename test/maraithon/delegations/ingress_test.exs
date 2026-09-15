defmodule Maraithon.Delegations.IngressTest do
  use Maraithon.DataCase, async: false
  alias Maraithon.{Accounts, Repo}
  alias Maraithon.Delegations.{Delegation, Event, Grant, Ingress, Scope, StateMachine}

  setup do
    user_id = "delegation-ingress-#{Ecto.UUID.generate()}@example.invalid"
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

    scope = %{
      "identity" => %{"email" => "kent@runner.now"},
      "to" => ["kent.fenwick@gmail.com"],
      "cc" => []
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
      subject: "Eval",
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
    alias Maraithon.LLM.CostMonitor
    alias Maraithon.Runtime.BackgroundJobs
    alias Maraithon.TelegramAssistant.Run
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

  defp route(c, message) do
    assert {:ok, :ok} =
             Repo.transaction(fn ->
               Maraithon.PrivacyErasure.WriteFence.lock_user_writable!(c.user_id)
               Ingress.gmail!(c.user_id, c.account.id, message)
             end)
  end
end
