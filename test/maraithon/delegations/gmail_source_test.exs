defmodule Maraithon.Delegations.GmailSourceTest do
  use Maraithon.DataCase, async: false
  import Maraithon.TestSupport.DelegationRuntime
  alias Maraithon.{Accounts, OAuth, Repo}
  alias Maraithon.Accounts.ConnectedAccount

  alias Maraithon.Delegations.{
    Binding,
    Delegation,
    Event,
    GmailSource,
    Grant,
    Jobs,
    Scope,
    Sources,
    Turn
  }

  alias Maraithon.Runtime.{BackgroundJob, PeriodicJobs}
  alias Maraithon.TelegramAssistant.Run

  @moduletag database_role: :session

  setup tags do
    user = "gmail-source-#{Ecto.UUID.generate()}@example.invalid"
    {:ok, _} = Accounts.get_or_create_user_by_email(user)
    source = account(user, "google:source", "kent@runner.now")

    sender =
      if tags[:assistant],
        do: account(user, "google:assistant", "october@ewakened.com"),
        else: source

    todo =
      Repo.insert!(%Maraithon.Todos.Todo{
        user_id: user,
        owner_user_id: user,
        title: "Long conversation",
        summary: "Get the test colour",
        source: "manual",
        next_action: "Ask",
        dedupe_key: Ecto.UUID.generate()
      })

    scope = %{
      "identity" => %{"email" => sender.metadata["email"], "account_id" => sender.id},
      "to" => ["kent.fenwick@gmail.com"],
      "cc" => [],
      "first_send_cc" => [],
      "subject" => "[Maraithon eval] Long conversation",
      "source_account_id" => source.id,
      "source_thread_id" => "aabbcc",
      "source_user_email" => "kent@runner.now",
      "actor" => if(tags[:assistant], do: "as_assistant", else: "as_user"),
      "task_owner" => Maraithon.Todos.Workflow.user_owner(todo),
      "outcome" => "Get the test colour"
    }

    d =
      %Delegation{user_id: user}
      |> Delegation.changeset(%{
        todo_id: todo.id,
        connected_account_id: sender.id,
        provider: "gmail",
        provider_thread_id: if(tags[:assistant], do: nil, else: "aabbcc"),
        state: "waiting_reply",
        data: %{}
      })
      |> Repo.insert!()

    grant =
      %Grant{user_id: user}
      |> Grant.changeset(%{
        delegation_id: d.id,
        version: 1,
        origin_request_id: Ecto.UUID.generate(),
        data: %{"scope" => scope, "scope_hash" => Scope.hash(scope)}
      })
      |> Repo.insert!()

    d = d |> Delegation.changeset(%{current_grant_id: grant.id}) |> Repo.update!()
    {node, partitions} = exact_authority(user)
    bypass = Bypass.open()
    previous = Application.get_env(:maraithon, :gmail, [])
    Application.put_env(:maraithon, :gmail, api_base_url: "http://localhost:#{bypass.port}")
    on_exit(fn -> Application.put_env(:maraithon, :gmail, previous) end)

    %{
      user: user,
      source: source,
      delegation: d,
      scope: scope,
      node: node,
      partitions: partitions,
      bypass: bypass
    }
  end

  @tag timeout: 120_000
  test "180-message sync resumes in new leased workers, caches bodies, and detects a late reply",
       c do
    messages =
      for n <- 1..180, do: message(n, DateTime.add(c.delegation.inserted_at, n - 181, :day))

    provider = provider(c, messages)
    job = start_turn(c)

    # The fixture advances each one-second retry immediately. Keep the real
    # scheduler and leases, but allow that accelerated admission rate.
    alias Maraithon.Runtime.Coordination.FairScheduler
    assert :ok = FairScheduler.ensure_min_tenant_concurrency(job.tenant_key, 1)

    assert {:ok, _} =
             FairScheduler.configure_tenant(job.tenant_key,
               max_concurrency: 1,
               rate_per_minute: 6_000,
               burst: 10
             )

    for batch <- 1..22 do
      assert {:ok, %{state: "syncing"}, {:reschedule_in, 1_000}} = run(c, job, &Sources.execute/1)

      assert Repo.aggregate(from(e in Event, where: e.kind == "inbound_message"), :count) ==
               batch * 8

      refute context(c).run.prompt_snapshot["sources"]
      refute Repo.exists?(from e in Event, where: e.kind == "sync_result")
      assert Repo.get!(BackgroundJob, job.id).status == "pending"
    end

    assert {:ok, %{state: "synced"}} = run(c, job, &Sources.execute/1)
    snapshot = context(c).run.prompt_snapshot["sources"]
    assert snapshot["message_count"] == 180
    assert length(snapshot["messages"]) == 6
    assert byte_size(Jason.encode!(snapshot)) < 8_000
    assert reads(provider) == {23, Enum.map(Enum.take(messages, -6), & &1["id"])}
    assert Repo.aggregate(from(e in Event, where: e.kind == "inbound_message"), :count) == 180
    assert context(c).delegation.source_revision == 0
    assert context(c).turn.model_calls == 0

    # An unchanged next turn reads only metadata, reusing authenticated prior bodies.
    next_job = start_turn(c)
    assert {:ok, %{state: "synced"}} = run(c, next_job, &Sources.execute/1)
    assert reads(provider) == {24, Enum.map(Enum.take(messages, -6), & &1["id"])}

    reply = message(181, DateTime.add(c.delegation.inserted_at, 1))
    Agent.update(provider, &%{&1 | messages: messages ++ [reply]})
    send_job = pre_send_job(c)

    assert {:ok, %{verification: "source_changed"}} =
             run(c, send_job, fn leased ->
               {:ok, current} = Jobs.transaction(leased, & &1)
               assert {:error, :source_changed} = Sources.verify_before_send(leased, current)
               {:ok, %{verification: "source_changed"}}
             end)

    assert context(c).delegation.source_revision == 1
    assert Repo.aggregate(from(e in Event, where: e.kind == "inbound_message"), :count) == 181
    assert reads(provider) == {25, Enum.map(Enum.take(messages, -6) ++ [reply], & &1["id"])}

    # The replacement turn consumes the already-recorded reply without advancing it twice.
    replacement = start_turn(c)
    assert {:ok, %{state: "synced"}} = run(c, replacement, &Sources.execute/1)
    assert context(c).run.prompt_snapshot["sources"]["message_count"] == 181
    assert context(c).delegation.source_revision == 1
    assert Repo.aggregate(from(e in Event, where: e.kind == "inbound_message"), :count) == 181
  end

  @tag assistant: true
  test "an assistant's first read and freshness check use the original account and thread", c do
    old = message(1, DateTime.add(c.delegation.inserted_at, -1, :day))
    provider = provider(c, [old])
    job = start_turn(c)
    assert job.partition_key == PeriodicJobs.provider_partition(c.user, c.source.provider)
    assert {:ok, %{state: "synced"}} = run(c, job, &Sources.execute/1)
    snapshot = context(c).run.prompt_snapshot["sources"]
    assert snapshot["account_id"] == c.source.id
    assert snapshot["thread_id"] == "aabbcc"
    event = Repo.one!(from e in Event, where: e.kind == "inbound_message")
    assert event.event_key == "gmail:#{c.source.id}:1"

    reply = message(2, DateTime.add(c.delegation.inserted_at, 1))
    Agent.update(provider, &%{&1 | messages: [old, reply]})

    assert {:ok, %{verification: "source_changed"}} =
             run(c, pre_send_job(c), fn leased ->
               {:ok, current} = Jobs.transaction(leased, & &1)
               assert {:error, :source_changed} = Sources.verify_before_send(leased, current)
               {:ok, %{verification: "source_changed"}}
             end)

    assert context(c).delegation.source_revision == 1
    assert Repo.exists?(from e in Event, where: e.event_key == ^"gmail:#{c.source.id}:2")
    event = Repo.get_by!(Event, event_key: "gmail:#{c.source.id}:2") |> Event.hydrate()
    assert event.data["classification"] == "reply"
  end

  test "a mismatched body cannot become durable progress or a complete source", c do
    original = message(1, DateTime.add(c.delegation.inserted_at, -1, :day))
    provider = provider(c, [original])
    Agent.update(provider, &%{&1 | replacements: %{"1" => %{original | "threadId" => "ddeeff"}}})
    job = start_turn(c)
    assert {:error, :source_changed} = GmailSource.read(context(c))
    refute Repo.exists?(Event)
    refute context(c).run.prompt_snapshot["sources"]
    Agent.update(provider, &%{&1 | replacements: %{}})
    assert {:ok, %{state: "synced"}} = run(c, job, &Sources.execute/1)
    assert Repo.aggregate(from(e in Event, where: e.kind == "inbound_message"), :count) == 1
  end

  test "changes outside the recent window invalidate sending without replaying old bodies", c do
    messages = for n <- 1..9, do: message(n, DateTime.add(c.delegation.inserted_at, n - 10, :day))
    provider = provider(c, messages)
    job = start_turn(c)
    assert {:ok, _, {:reschedule_in, _}} = run(c, job, &Sources.execute/1)
    assert {:ok, %{state: "synced"}} = run(c, job, &Sources.execute/1)
    current = context(c)
    Agent.update(provider, &%{&1 | messages: tl(messages)})
    {:ok, index} = GmailSource.index(current.delegation, c.scope)
    refute GmailSource.unchanged?(index, current.run.prompt_snapshot["sources"])
    assert reads(provider) == {3, Enum.map(Enum.take(messages, -6), & &1["id"])}
  end

  @tag assistant: true
  test "a missing or foreign source account cannot fall back to the user's default mailbox", c do
    assert {:error, :invalid_google_account} =
             GmailSource.index(c.delegation, Map.delete(c.scope, "source_account_id"))

    other_user = "foreign-#{Ecto.UUID.generate()}@example.invalid"
    {:ok, _} = Accounts.get_or_create_user_by_email(other_user)
    foreign = account(other_user, "google:other", other_user)

    assert {:error, :invalid_google_account} =
             GmailSource.index(c.delegation, Map.put(c.scope, "source_account_id", foreign.id))
  end

  test "a new Gmail thread keeps five recent earlier messages and reads only the new body", c do
    messages = for n <- 1..6, do: message(n, DateTime.add(c.delegation.inserted_at, n - 7, :day))
    provider = provider(c, messages)
    assert {:ok, %{state: "synced"}} = run(c, start_turn(c), &Sources.execute/1)

    reply =
      message(7, DateTime.add(c.delegation.inserted_at, 1))
      |> Map.put("threadId", "ddeeff")
      |> update_in(
        ["payload", "headers"],
        &(&1 ++
            [
              %{"name" => "In-Reply-To", "value" => "<message-6@example.invalid>"},
              %{"name" => "References", "value" => "<message-6@example.invalid>"}
            ])
      )

    Agent.update(provider, &%{&1 | messages: messages ++ [reply]})

    {:ok, parsed} =
      Maraithon.Connectors.Gmail.fetch_message_content("google:source", "7", access_token: true)

    assert {:ok, :ok} =
             Repo.transaction(fn ->
               Maraithon.PrivacyErasure.WriteFence.lock_user_writable!(c.user)
               Maraithon.Delegations.Ingress.gmail!(c.user, c.source.id, parsed)
             end)

    assert Repo.get!(Delegation, c.delegation.id).provider_thread_id == "ddeeff"
    prior_body_reads = reads(provider) |> elem(1) |> length()
    assert {:ok, %{state: "synced"}} = run(c, start_turn(c), &Sources.execute/1)
    snapshot = context(c).run.prompt_snapshot["sources"]
    assert snapshot["thread_id"] == "ddeeff"
    assert Enum.map(snapshot["messages"], & &1["message_id"]) == ~w(2 3 4 5 6 7)
    assert length(elem(reads(provider), 1)) == prior_body_reads + 1
    assert context(c).delegation.source_revision == 1
    assert context(c).turn.model_calls == 0
  end

  defp account(user, provider, email) do
    {:ok, _} =
      OAuth.store_tokens(user, provider, %{
        access_token: provider,
        refresh_token: "fixture",
        expires_in: 3600
      })

    account = Repo.get_by!(ConnectedAccount, user_id: user, provider: provider)
    account |> Ecto.Changeset.change(metadata: %{"email" => email}) |> Repo.update!()
  end

  defp context(c) do
    turn =
      Repo.one!(
        from t in Turn,
          where: t.delegation_id == ^c.delegation.id,
          order_by: [desc: t.seq],
          limit: 1
      )
      |> Turn.hydrate()

    d = Repo.get!(Delegation, c.delegation.id) |> Delegation.hydrate()

    %{
      delegation: d,
      grant: Maraithon.Delegations.current_grant(d),
      turn: turn,
      run: Repo.get!(Run, turn.run_id) |> Run.hydrate_payloads()
    }
  end

  defp start_turn(c) do
    {:ok, job} =
      Repo.transaction(fn ->
        Maraithon.PrivacyErasure.WriteFence.lock_user_writable!(c.user)

        for turn <- Repo.all(from t in Turn, where: t.delegation_id == ^c.delegation.id) do
          turn |> Turn.hydrate() |> Turn.changeset(%{status: "settled"}) |> Repo.update!()
        end

        d = Repo.get!(Delegation, c.delegation.id) |> Delegation.hydrate()

        next =
          Jobs.start_sync!(
            d,
            Maraithon.Delegations.current_grant(d),
            %{id: Ecto.UUID.generate(), kind: "user_action"},
            DateTime.utc_now()
          )

        d |> Delegation.changeset(%{state: next.state}) |> Repo.update!()

        Repo.one!(
          from j in BackgroundJob,
            where: j.job_type == "delegation_sync" and j.status == "pending"
        )
      end)

    job
  end

  defp pre_send_job(c) do
    {:ok, job} =
      Repo.transaction(fn ->
        current = context(c)

        Jobs.enqueue!(
          "delegation_send",
          current.delegation,
          current.run.prompt_snapshot[Binding.key()],
          DateTime.utc_now()
        )
      end)

    job
  end

  defp run(c, job, fun),
    do: run_leased_job(c.node, c.partitions, Repo.get!(BackgroundJob, job.id), fun)

  defp provider(c, messages) do
    state =
      start_supervised!(
        {Agent,
         fn -> %{messages: messages, replacements: %{}, metadata_reads: 0, body_reads: []} end}
      )

    Bypass.stub(c.bypass, "GET", "/users/me/threads/:thread", fn conn ->
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer google:source"]
      assert Plug.Conn.fetch_query_params(conn).query_params["format"] == "metadata"

      messages =
        Agent.get_and_update(state, &{&1.messages, %{&1 | metadata_reads: &1.metadata_reads + 1}})
        |> Enum.filter(&(&1["threadId"] == List.last(conn.path_info)))

      json(conn, %{
        "messages" =>
          Enum.map(
            messages,
            &update_in(&1["payload"], fn payload -> Map.delete(payload, "body") end)
          )
      })
    end)

    Bypass.stub(c.bypass, "GET", "/users/me/messages/:id", fn conn ->
      id = List.last(conn.path_info)
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer google:source"]

      message =
        Agent.get_and_update(state, fn s ->
          {s.replacements[id] || Enum.find(s.messages, &(&1["id"] == id)),
           %{s | body_reads: s.body_reads ++ [id]}}
        end)

      json(conn, message)
    end)

    state
  end

  defp reads(provider), do: Agent.get(provider, &{&1.metadata_reads, &1.body_reads})

  defp message(n, date) do
    %{
      "id" => Integer.to_string(n, 16),
      "threadId" => "aabbcc",
      "labelIds" => ["INBOX"],
      "internalDate" => Integer.to_string(DateTime.to_unix(date, :millisecond)),
      "payload" => %{
        "mimeType" => "text/plain",
        "body" => %{"data" => Base.url_encode64("Answer #{n} is indigo.", padding: false)},
        "headers" =>
          Enum.map(
            [
              {"From", "kent.fenwick@gmail.com"},
              {"To", "kent@runner.now"},
              {"Subject", "[Maraithon eval] Long conversation"},
              {"Message-ID", "<message-#{n}@example.invalid>"}
            ],
            fn {name, value} -> %{"name" => name, "value" => value} end
          )
      }
    }
  end

  defp json(conn, value),
    do:
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(value))
end
