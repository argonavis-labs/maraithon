defmodule Maraithon.Delegations.SlackIngressTest do
  use Maraithon.DataCase, async: false
  import Maraithon.TestSupport.DelegationRuntime
  alias Maraithon.{Accounts, ConnectedAccounts, OAuth, Repo}

  alias Maraithon.Delegations.{
    Delegation,
    Event,
    Execution,
    Grant,
    Policy,
    Scope,
    SlackIngress,
    SlackSource,
    Sources,
    StateMachine,
    Turn
  }

  alias Maraithon.TelegramAssistant.{PreparedAction, Run}

  setup tags do
    user_id = "slack-ingress-#{Ecto.UUID.generate()}@example.invalid"
    {:ok, _} = Accounts.get_or_create_user_by_email(user_id)

    {:ok, _} =
      OAuth.store_tokens(user_id, "slack:T123:user:UOWN", %{
        access_token: "local-slack-member",
        scopes: ["chat:write", "channels:history", "im:history"]
      })

    account = ConnectedAccounts.get(user_id, "slack:T123:user:UOWN")

    channel =
      cond do
        tags[:new_dm] -> "DBOT"
        tags[:dm] -> "D123"
        true -> "C123"
      end

    source_channel = if tags[:new_dm], do: "DORIGINAL", else: channel
    now = DateTime.utc_now()
    root = ts(DateTime.add(now, -60))

    identity = %{
      "actor" => "as_user",
      "account_id" => account.id,
      "source_provider" => account.provider,
      "external_account_id" => account.external_account_id,
      "sender_account_id" => account.id,
      "sender_external_account_id" => account.external_account_id,
      "team_id" => "T123",
      "user_id" => "UOWN",
      "operator_user_id" => "UOWN",
      "source_channel" => source_channel,
      "dm_user_id" => if(tags[:new_dm], do: "UCHARLIE"),
      "provider" => account.provider,
      "token_preference" => "user",
      "bot_id" => nil
    }

    identity =
      if tags[:actor] == "as_assistant" do
        {:ok, _} =
          OAuth.store_tokens(user_id, "slack:T123", %{
            access_token: "local-slack-bot",
            scopes: ["chat:write", "chat:write.customize", "channels:history"]
          })

        bot = ConnectedAccounts.get(user_id, "slack:T123")

        Map.merge(identity, %{
          "actor" => "as_assistant",
          "user_id" => "UBOT",
          "bot_id" => "B123",
          "provider" => bot.provider,
          "sender_account_id" => bot.id,
          "sender_external_account_id" => bot.external_account_id,
          "token_preference" => "bot",
          "display_name" => "October"
        })
      else
        identity
      end

    todo =
      Repo.insert!(%Maraithon.Todos.Todo{
        user_id: user_id,
        owner_user_id: user_id,
        source: "slack",
        title: "Get the project colour",
        summary: "Ask Charlie for the project colour",
        next_action: "Ask Charlie",
        dedupe_key: Ecto.UUID.generate()
      })

    scope = %{
      "provider" => "slack",
      "actor" => identity["actor"],
      "team_id" => "T123",
      "channel" => channel,
      "thread_id" => if(tags[:new_dm], do: nil, else: root),
      "source_channel_id" => source_channel,
      "source_thread_id" => root,
      "source_account_id" => account.id,
      "identity" => identity,
      "to" => [channel],
      "cc" => [],
      "counterparty_user_ids" => ["UCHARLIE"],
      "task_owner" => Maraithon.Todos.Workflow.user_owner(todo),
      "outcome" => "Get the project colour"
    }

    d = insert_delegation(user_id, account.id, todo.id, scope)

    message = %{
      "ts" => ts(DateTime.add(now, 1)),
      "channel" => source_channel,
      "thread_ts" => root,
      "user" => "UCHARLIE",
      "text" => "The colour is indigo.",
      "provider_event_id" => "EvREPLY"
    }

    %{
      user_id: user_id,
      account: account,
      delegation: d,
      scope: scope,
      message: message,
      root: %{"ts" => root, "user" => "UCHARLIE", "text" => "I can supply the project colour."}
    }
  end

  test "duplicate provider deliveries and repair reads advance the conversation once", c do
    route(c, c.message)
    route(c, c.message)
    route(c, Map.put(c.message, "provider_event_id", "EvDUPLICATE"))
    route(c, SlackSource.normalize(c.message, c.scope["channel"], c.scope["thread_id"]))
    d = reload(c)
    assert d.source_revision == 1
    [event] = events(c)
    assert event.data["classification"] == "reply"
    assert event.wake_state == "pending"
    assert {next, [:enqueue_sync]} = StateMachine.apply(d, event)
    assert next.state == "ready"
    assert next.source_revision == 1
  end

  test "edits and deletes invalidate unsent decisions even without a parent in the event", c do
    route(c, c.message)

    edited =
      c.message
      |> Map.delete("thread_ts")
      |> Map.merge(%{
        "event_type" => "message_changed",
        "target_ts" => c.message["ts"],
        "event_ts" => ts(DateTime.add(DateTime.utc_now(), 2)),
        "text" => "Actually, violet.",
        "provider_event_id" => "EvEDIT"
      })

    route(c, edited)
    route(c, edited)
    assert reload(c).source_revision == 2

    route(
      c,
      Map.merge(edited, %{
        "event_type" => "message_deleted",
        "provider_event_id" => "EvDELETE",
        "event_ts" => ts(DateTime.add(DateTime.utc_now(), 3)),
        "text" => "Slack message deleted"
      })
    )

    assert reload(c).source_revision == 3
    assert List.last(events(c)).data["classification"] == "source_gap"
  end

  test "wrong workspace, channel, and unrelated thread cannot wake the task", c do
    route(c, c.message, "TOTHER")
    route(c, Map.put(c.message, "channel", "COTHER"))
    route(c, Map.put(c.message, "thread_ts", "1789500000.000001"))
    assert events(c) == []
    assert reload(c).source_revision == 0
  end

  test "manual sends pause, a new person needs review, and bots cannot complete the task", c do
    for {sender, expected} <- [{"UOWN", "human_send"}, {"UNEW", "scope_change"}] do
      message =
        SlackSource.normalize(
          Map.put(c.message, "user", sender),
          c.scope["channel"],
          c.scope["thread_id"]
        )

      assert SlackSource.classify(message, c.scope) == expected
    end

    bot =
      c.message
      |> Map.put("bot_id", "BOTHER")
      |> SlackSource.normalize(c.scope["channel"], c.scope["thread_id"])

    assert SlackSource.classify(bot, c.scope) == "auto_reply"

    context = %{
      delegation: c.delegation,
      turn: %{source_revision: 0},
      grant: %{data: %{"scope" => c.scope}},
      run: %{prompt_snapshot: %{"sources" => %{"complete" => true, "messages" => [bot]}}}
    }

    decision = %{"kind" => "complete", "reason" => "Indigo", "evidence" => [bot["message_id"]]}
    assert {:error, :unverified_outcome} = Policy.validate(context, decision)
    route(c, Map.put(c.message, "user", "UOWN"))

    assert {%{state: "paused"}, [:cancel_unentered, :notify_user]} =
             StateMachine.apply(reload(c), hd(events(c)))
  end

  @tag :dm
  test "an unthreaded DM is eligible only for its single live delegation", c do
    unthreaded = Map.delete(c.message, "thread_ts")
    route(c, unthreaded)
    assert reload(c).source_revision == 1

    other_todo =
      Repo.insert!(%Maraithon.Todos.Todo{
        user_id: c.user_id,
        title: "Another question",
        summary: "A separate conversation",
        next_action: "Ask",
        source: "manual",
        dedupe_key: Ecto.UUID.generate()
      })

    other =
      insert_delegation(
        c.user_id,
        c.account.id,
        other_todo.id,
        Map.put(c.scope, "thread_id", "1789500000.000001")
      )

    route(
      c,
      Map.merge(unthreaded, %{
        "ts" => ts(DateTime.add(DateTime.utc_now(), 4)),
        "provider_event_id" => "EvAMBIGUOUS"
      })
    )

    assert reload(c).source_revision == 1
    assert Repo.get!(Delegation, other.id).source_revision == 0
    assert is_nil(SlackIngress.only_live_id(c.user_id, "D123"))
  end

  test "an ingestion rollback leaves neither a source revision nor a wake behind", c do
    assert {:error, :abort} =
             Repo.transaction(fn ->
               SlackIngress.accept!(c.user_id, "T123", c.message)
               Repo.rollback(:abort)
             end)

    assert events(c) == []
    assert reload(c).source_revision == 0
  end

  test "the connector persists the reply before returning its webhook acknowledgement", c do
    {:ok, _} =
      OAuth.store_tokens(c.user_id, "slack:T123", %{
        access_token: "local-slack-bot",
        scopes: ["channels:history"],
        metadata: %{"authed_user_id" => "UOWN"}
      })

    params = %{
      "type" => "event_callback",
      "team_id" => "T123",
      "event_id" => "EvWEBHOOK",
      "authorizations" => [%{"user_id" => "UOWN"}],
      "event" => Map.put(c.message, "type", "message")
    }

    conn = Plug.Test.conn(:post, "/webhooks/slack", params)
    assert {:ok, _, _} = Maraithon.Connectors.Slack.handle_webhook(conn, params)
    assert reload(c).source_revision == 1
    assert length(events(c)) == 1

    assert Repo.exists?(
             from o in Maraithon.Crm.Observation,
               where: o.user_id == ^c.user_id and o.source == "slack"
           )

    assert {:ok, _, _} = Maraithon.Connectors.Slack.handle_webhook(conn, params)
    assert reload(c).source_revision == 1
  end

  @tag dm: true, actor: "as_assistant"
  test "private bot DM replies persist without becoming operator observations", c do
    {:ok, _} =
      OAuth.store_tokens(c.user_id, "slack:T123", %{
        access_token: "local-slack-bot",
        scopes: ["im:history"],
        metadata: %{"authed_user_id" => "UOWN", "bot_user_id" => "UBOT"}
      })

    params = %{
      "type" => "event_callback",
      "team_id" => "T123",
      "event_id" => "EvPRIVATE",
      "authorizations" => [%{"user_id" => "UBOT", "is_bot" => true}],
      "event" => Map.put(c.message, "type", "message")
    }

    conn = Plug.Test.conn(:post, "/webhooks/slack", params)
    assert {:ok, _, _} = Maraithon.Connectors.Slack.handle_webhook(conn, params)
    assert reload(c).source_revision == 1
    assert List.last(events(c)).data["classification"] == "reply"
    refute Repo.exists?(from o in Maraithon.Crm.Observation, where: o.user_id == ^c.user_id)
    assert {:ok, _, _} = Maraithon.Connectors.Slack.handle_webhook(conn, params)
    assert reload(c).source_revision == 1
    # Another DM visible only to the bot is not the operator's inbox either.
    other = params |> Map.put("event_id", "EvOTHERDM") |> put_in(["event", "channel"], "DOTHER")
    assert {:ok, _, _} = Maraithon.Connectors.Slack.handle_webhook(conn, other)
    assert length(events(c)) == 1
    refute Repo.exists?(from o in Maraithon.Crm.Observation, where: o.user_id == ^c.user_id)
  end

  @tag new_dm: true, actor: "as_assistant"
  test "unthreaded messages cannot become answers before the assistant sends its first message",
       c do
    unrelated = c.message |> Map.delete("thread_ts") |> Map.put("channel", "DBOT")
    route(c, unrelated)
    assert events(c) == []
    assert reload(c).source_revision == 0
  end

  test "editing an ignored bot message still invalidates earlier evidence", c do
    bot = Map.merge(c.message, %{"user" => "UBOT", "bot_id" => "BOTHER"})
    route(c, bot)
    assert reload(c).source_revision == 0

    edited =
      Map.merge(bot, %{
        "target_ts" => bot["ts"],
        "event_type" => "message_changed",
        "event_ts" => ts(DateTime.add(DateTime.utc_now(), 2)),
        "provider_event_id" => "EvBOTEDIT",
        "text" => "Changed"
      })

    route(c, edited)
    assert reload(c).source_revision == 1
    assert List.last(events(c)).data["classification"] == "source_changed"

    assert {%{state: "ready"}, [:enqueue_sync]} =
             StateMachine.apply(reload(c), List.last(events(c)))
  end

  for dm? <- [false, true] do
    @tag dm: dm?, fact_recall: true
    test "older Slack evidence uses its exact timestamp and author (DM #{dm?})", c do
      alias Maraithon.Delegations.{Ledger, Toolbox}
      bypass = Bypass.open()
      original = Application.get_env(:maraithon, :slack, [])
      Application.put_env(:maraithon, :slack, api_base_url: "http://localhost:#{bypass.port}/api")
      on_exit(fn -> Application.put_env(:maraithon, :slack, original) end)

      {:ok, source} =
        SlackSource.snapshot(
          [c.root, c.message],
          c.account.id,
          c.scope["channel"],
          c.scope["thread_id"]
        )

      context = %{
        delegation: c.delegation,
        grant: %{data: %{"scope" => c.scope}},
        turn: %{source_revision: 0},
        run: %{prompt_snapshot: %{"sources" => source}}
      }

      decision = %{
        "evidence" => [c.message["ts"]],
        "facts" => [
          %{
            "key" => "project_colour",
            "text" => "Charlie says the colour is indigo.",
            "evidence" => [c.message["ts"]]
          }
        ]
      }

      {:ok, ledger} = Ledger.merge(context, decision, DateTime.utc_now())

      recent =
        for n <- 2..7,
            do:
              c.message
              |> Map.put("ts", ts(DateTime.add(DateTime.utc_now(), n)))
              |> SlackSource.normalize(c.scope["channel"], c.scope["thread_id"])

      context = put_in(context, [:run, :prompt_snapshot, "sources", "messages"], recent)
      context = put_in(context, [:run, :prompt_snapshot, "fact_ledger"], ledger)

      Bypass.expect(bypass, "POST", "/api/auth.test", fn conn ->
        assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer local-slack-member"]
        json(conn, %{"ok" => true, "team_id" => "T123", "user_id" => "UOWN"})
      end)

      endpoint =
        if unquote(dm?), do: "/api/conversations.history", else: "/api/conversations.replies"

      response = if unquote(dm?), do: Map.delete(c.message, "thread_ts"), else: c.message

      Bypass.expect_once(bypass, "GET", endpoint, fn conn ->
        query = URI.decode_query(conn.query_string)
        assert query["channel"] == c.scope["channel"]
        assert query["oldest"] == c.message["ts"]
        assert query["latest"] == c.message["ts"]
        assert query["inclusive"] == "true"
        assert query["limit"] == "2"
        json(conn, %{"ok" => true, "messages" => [response], "has_more" => false})
      end)

      assert {:ok, [recalled]} = Toolbox.read(context, decision)
      assert recalled["message"]["from"] == "UCHARLIE"
      assert recalled["message"]["text_body"] == c.message["text"]
      context = put_in(context, [:run, :prompt_snapshot, "recalled_sources"], [recalled])

      Bypass.expect_once(bypass, "GET", endpoint, fn conn ->
        json(conn, %{
          "ok" => true,
          "messages" => [Map.put(response, "text", "Actually, violet.")],
          "has_more" => false
        })
      end)

      assert {:error, :recalled_evidence_changed} = Toolbox.verify_before_send(context)
    end
  end

  for {actor, response, new_dm} <- [
        {"as_user", :accepted, false},
        {"as_user", :lost_response, false},
        {"as_user", :edited_before_send, false},
        {"as_assistant", :accepted, false},
        {"as_assistant", :accepted, true},
        {"as_assistant", :edited_before_send, true},
        {"as_assistant", :lost_response, true}
      ] do
    @tag timeout: 30_000, slack_response: response, actor: actor, new_dm: new_dm
    test "leased Slack source and #{actor} #{response} sender (new DM #{new_dm}) preserve the approved turn",
         c do
      enable(c.user_id)
      {node, partitions} = exact_authority(c.user_id)
      bypass = Bypass.open()
      original = Application.get_env(:maraithon, :slack, [])
      Application.put_env(:maraithon, :slack, api_base_url: "http://localhost:#{bypass.port}/api")
      on_exit(fn -> Application.put_env(:maraithon, :slack, original) end)
      messages = start_supervised!({Agent, fn -> [c.root, c.message] end})
      accepted = start_supervised!({Agent, fn -> nil end}, id: :accepted_slack)

      Bypass.expect(
        bypass,
        "POST",
        "/api/auth.test",
        fn conn ->
          bot? = Plug.Conn.get_req_header(conn, "authorization") == ["Bearer local-slack-bot"]

          json(conn, %{
            "ok" => true,
            "team_id" => "T123",
            "user_id" => if(bot?, do: "UBOT", else: "UOWN"),
            "bot_id" => if(bot?, do: "B123")
          })
        end
      )

      Bypass.expect(
        bypass,
        "GET",
        "/api/conversations.replies",
        fn conn ->
          if c.new_dm do
            assert URI.decode_query(conn.query_string)["channel"] == "DORIGINAL"

            assert Plug.Conn.get_req_header(conn, "authorization") == [
                     "Bearer local-slack-member"
                   ]
          end

          json(conn, %{"ok" => true, "messages" => Agent.get(messages, fn list -> list end)})
        end
      )

      if c.new_dm do
        c.delegation |> Delegation.changeset(%{state: "ready"}) |> Repo.update!()
      else
        route(c, c.message)
      end

      d = reload(c)
      grant = Maraithon.Delegations.current_grant(d)

      assert {:ok, _} =
               Repo.transaction(fn ->
                 event =
                   if c.new_dm,
                     do: %{
                       id: Ecto.UUID.generate(),
                       kind: "user_action",
                       data: %{"action" => "start"}
                     },
                     else: hd(events(c))

                 {next, commands} = StateMachine.apply(d, event)

                 next =
                   Maraithon.Delegations.Commands.apply(
                     next,
                     grant,
                     event,
                     commands,
                     DateTime.utc_now()
                   )

                 d |> Delegation.changeset(%{state: next.state}) |> Repo.update!()
               end)

      assert {:ok, %{state: "synced"}} =
               run_leased_job(node, partitions, "delegation_sync", &Sources.execute/1)

      assert {:ok, action} =
               Repo.transaction(fn ->
                 d = reload(c)
                 turn = Repo.one!(Turn) |> Turn.hydrate()
                 run = Repo.get!(Run, turn.run_id) |> Run.hydrate_payloads()

                 assert Enum.map(run.prompt_snapshot["sources"]["messages"], & &1["message_id"]) ==
                          [c.root["ts"], c.message["ts"]]

                 decision = %{
                   "kind" => "send",
                   "body" => "Thanks. Indigo.",
                   "reason" => "Confirm the answer",
                   "evidence" => [c.message["ts"]]
                 }

                 run |> Run.changeset(%{status: "completed"}) |> Repo.update!()

                 turn
                 |> Turn.changeset(%{
                   status: "validated",
                   data:
                     Map.merge(turn.data, %{
                       "decision" => decision,
                       "policy_review" => %{"allowed" => true, "reason" => "Within grant"}
                     })
                 })
                 |> Repo.update!()

                 d = d |> Delegation.changeset(%{state: "deciding"}) |> Repo.update!()

                 event = %{kind: "decision", data: Map.put(decision, "turn_id", turn.id)}
                 {next, commands} = StateMachine.apply(d, event)

                 next =
                   Maraithon.Delegations.Commands.apply(
                     next,
                     grant,
                     event,
                     commands,
                     DateTime.utc_now()
                   )

                 assert next.state == "sending"
                 d |> Delegation.changeset(%{state: next.state}) |> Repo.update!()

                 Repo.get!(Turn, turn.id)
                 |> Turn.hydrate()
                 |> Turn.changeset(%{available_at: DateTime.add(DateTime.utc_now(), -1)})
                 |> Repo.update!()

                 Repo.one!(PreparedAction) |> PreparedAction.hydrate_payload()
               end)

      if c.slack_response == :edited_before_send do
        Agent.update(messages, fn [root, message] ->
          [
            root,
            Map.merge(message, %{
              "text" => "Actually violet.",
              "edited" => %{"ts" => ts(DateTime.add(DateTime.utc_now(), 2))}
            })
          ]
        end)
      else
        Bypass.expect_once(
          bypass,
          "GET",
          "/api/conversations.info",
          &json(&1, %{
            "ok" => true,
            "channel" => %{
              "id" => c.scope["channel"],
              "is_member" => true,
              "is_im" => c.new_dm,
              "user" => if(c.new_dm, do: "UCHARLIE")
            }
          })
        )

        Bypass.expect_once(bypass, "POST", "/api/chat.postMessage", fn conn ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          body = Jason.decode!(body)
          assert body["client_msg_id"] == action.id
          assert body["thread_ts"] == c.scope["thread_id"]
          assert body["channel"] == c.scope["channel"]

          sent =
            Map.merge(body, %{
              "ts" => ts(DateTime.add(DateTime.utc_now(), 4)),
              "user" => c.scope["identity"]["user_id"],
              "bot_id" => c.scope["identity"]["bot_id"]
            })

          Agent.update(accepted, fn _ -> sent end)

          if c.slack_response == :accepted,
            do:
              json(conn, %{
                "ok" => true,
                "channel" => c.scope["channel"],
                "ts" => sent["ts"],
                "message" => sent
              }),
            else: Plug.Conn.resp(conn, 503, "Accepted; response lost")
        end)
      end

      result =
        run_leased_job(node, partitions, "delegation_send", fn job ->
          result = Execution.execute(job)

          if c.slack_response == :lost_response,
            do: assert({:ok, %{state: "reconciling"}} = Execution.execute(job))

          result
        end)

      saved = Repo.get!(PreparedAction, action.id) |> PreparedAction.hydrate_payload()

      case c.slack_response do
        :accepted ->
          assert {:ok, %{state: "sent"}} = result
          assert saved.status == "executed"
          assert reload(c).lifetime_sends == 1
          route(c, Agent.get(accepted, & &1))
          assert List.last(events(c)).data["classification"] == "own_send"

          if c.new_dm do
            sent = Agent.get(accepted, & &1)
            assert reload(c).provider_thread_id == sent["ts"]

            reply =
              c.message
              |> Map.delete("thread_ts")
              |> Map.merge(%{
                "channel" => "DBOT",
                "ts" => ts(DateTime.add(DateTime.utc_now(), 5)),
                "provider_event_id" => "EvBOTDMREPLY"
              })

            route(c, reply)
            assert List.last(events(c)).data["classification"] == "reply"
            assert reload(c).source_revision == 1

            Bypass.stub(bypass, "GET", "/api/conversations.replies", fn conn ->
              assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer local-slack-bot"]
              assert URI.decode_query(conn.query_string)["ts"] == sent["ts"]
              json(conn, %{"ok" => true, "messages" => [sent]})
            end)

            Bypass.expect_once(bypass, "GET", "/api/conversations.history", fn conn ->
              assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer local-slack-bot"]
              json(conn, %{"ok" => true, "messages" => [sent, reply]})
            end)

            assert {:ok, snapshot} =
                     SlackSource.fetch(c.user_id, c.scope["identity"], "DBOT", sent["ts"],
                       include_unthreaded?: true
                     )

            assert Enum.map(snapshot["messages"], & &1["from"]) == ["UBOT", "UCHARLIE"]
          end

        :lost_response ->
          assert {:ok, %{state: "reconciling"}} = result
          assert saved.status == "execution_unknown"
          assert saved.payload["_maraithon_execution_attempts"] == 1
          assert reload(c).lifetime_sends == 0

        :edited_before_send ->
          assert {:ok, %{state: "superseded"}} = result
          assert (saved.payload["_maraithon_execution_attempts"] || 0) == 0
          assert Agent.get(accepted, & &1) == nil
          assert reload(c).source_revision == if(c.new_dm, do: 1, else: 2)

          assert {:ok, :ok} =
                   Repo.transaction(fn ->
                     d = reload(c)
                     event = List.last(events(c))
                     {next, commands} = StateMachine.apply(d, event)

                     next =
                       Maraithon.Delegations.Commands.apply(
                         next,
                         grant,
                         event,
                         commands,
                         DateTime.utc_now()
                       )

                     assert next.state == "ready"
                     assert Repo.get!(PreparedAction, action.id).status == "rejected"
                     assert Repo.get!(Turn, action.delegation_turn_id).status == "superseded"
                     :ok
                   end)
      end
    end
  end

  defp insert_delegation(user_id, account_id, todo_id, scope) do
    d =
      %Delegation{user_id: user_id}
      |> Delegation.changeset(%{
        todo_id: todo_id,
        connected_account_id: account_id,
        provider: "slack",
        actor: scope["actor"],
        provider_thread_id: scope["thread_id"],
        slack_channel: scope["channel"],
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

    d |> Delegation.changeset(%{current_grant_id: grant.id}) |> Repo.update!()
  end

  defp route(c, message, team \\ "T123"),
    do:
      Repo.transaction(fn ->
        Maraithon.PrivacyErasure.WriteFence.lock_user_writable!(c.user_id)
        SlackIngress.accept!(c.user_id, team, message)
      end)
      |> then(fn result -> assert {:ok, :ok} = result end)

  defp reload(c), do: Repo.get!(Delegation, c.delegation.id) |> Delegation.hydrate()

  defp events(c),
    do:
      Repo.all(
        from e in Event,
          where: e.delegation_id == ^c.delegation.id and e.kind == "inbound_message",
          order_by: e.seq
      )
      |> Enum.map(&Event.hydrate/1)

  defp ts(date) do
    value = DateTime.to_unix(date, :microsecond)
    "#{div(value, 1_000_000)}.#{String.pad_leading(to_string(rem(value, 1_000_000)), 6, "0")}"
  end

  defp json(conn, body),
    do:
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(body))

  defp enable(user_id) do
    for {key, value} <- [
          delegations_enabled: true,
          delegation_user_allowlist: [user_id],
          delegation_sends_enabled: %{slack: true},
          delegation_eval_only: false
        ] do
      previous = Application.get_env(:maraithon, key)
      Application.put_env(:maraithon, key, value)

      on_exit(fn ->
        if previous == nil,
          do: Application.delete_env(:maraithon, key),
          else: Application.put_env(:maraithon, key, previous)
      end)
    end
  end
end
