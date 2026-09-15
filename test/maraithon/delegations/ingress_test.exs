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

  defp route(c, message) do
    assert {:ok, :ok} =
             Repo.transaction(fn ->
               Maraithon.PrivacyErasure.WriteFence.lock_user_writable!(c.user_id)
               Ingress.gmail!(c.user_id, c.account.id, message)
             end)
  end
end
