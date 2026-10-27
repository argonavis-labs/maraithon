defmodule Maraithon.Delegations.SlackTransportTest do
  use Maraithon.DataCase, async: false
  alias Maraithon.{Accounts, ConnectedAccounts, OAuth, TelegramAssistant}
  alias Maraithon.Delegations.{SlackDelivery, SlackIdentity}
  alias Maraithon.TelegramAssistant.ActionReconciliation
  alias Maraithon.Tools.SlackPostMessage

  @root "1789500000.000001"
  @sent "1789500010.000001"
  @key "_maraithon_reconciliation_identity"

  setup do
    bypass = Bypass.open()
    original = Application.get_env(:maraithon, :slack, [])
    Application.put_env(:maraithon, :slack, api_base_url: "http://localhost:#{bypass.port}/api")
    on_exit(fn -> Application.put_env(:maraithon, :slack, original) end)
    user_id = "slack-delivery-#{Ecto.UUID.generate()}@example.invalid"
    {:ok, _} = Accounts.get_or_create_user_by_email(user_id)

    for {provider, token} <- [
          {"slack:T123:user:U123", "fixture-member"},
          {"slack:T123", "fixture-bot"}
        ] do
      {:ok, _} =
        OAuth.store_tokens(user_id, provider, %{
          access_token: token,
          scopes: ["chat:write", "chat:write.customize", "channels:history", "im:write"],
          metadata: %{"authed_user_id" => "UOTHER"}
        })
    end

    source = ConnectedAccounts.get(user_id, "slack:T123:user:U123")
    %{bypass: bypass, user_id: user_id, source: source}
  end

  for actor <- ~w(as_user as_assistant) do
    test "#{actor} sends once with the exact frozen author, root and literal text", c do
      action = action(c, unquote(actor))
      auth(c)
      channel(c)
      author = action.payload[@key]["author"]

      Bypass.expect_once(c.bypass, "POST", "/api/chat.postMessage", fn conn ->
        expected_token = if unquote(actor) == "as_user", do: "fixture-member", else: "fixture-bot"
        assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer #{expected_token}"]
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        body = Jason.decode!(body)
        assert body["channel"] == "C123"
        assert body["thread_ts"] == @root
        assert body["client_msg_id"] == action.id
        assert body["text"] == "What colour? &lt;!channel&gt; &amp; &lt;@UOTHER&gt;"
        assert body["reply_broadcast"] == false
        assert body["link_names"] == false
        assert body["mrkdwn"] == false
        assert body["parse"] == "none"
        assert body["unfurl_links"] == false
        assert body["unfurl_media"] == false

        if unquote(actor) == "as_assistant" do
          assert body["username"] == "October"
          assert body["icon_url"] == "https://example.invalid/october.png"
        else
          refute Map.has_key?(body, "username")
          refute Map.has_key?(body, "icon_url")
        end

        json(conn, %{
          "ok" => true,
          "channel" => "C123",
          "ts" => @sent,
          "message" => message(action)
        })
      end)

      assert {:ok, receipt} = SlackPostMessage.execute(action.payload)
      assert receipt.ts == @sent
      assert receipt.thread_id == @root
      assert receipt.user == author["user_id"]
      assert receipt.bot_id == author["bot_id"]
      assert receipt.text_sha256 == action.payload[@key]["text_sha256"]
    end
  end

  test "a requested member never falls back to the installation's member or bot", c do
    action = action(c)

    author =
      Map.merge(action.payload["_maraithon_slack_author"], %{
        "provider" => "slack:T123:user:UMISSING",
        "user_id" => "UMISSING"
      })

    assert {:error, :no_user_token} =
             SlackIdentity.access_token(c.user_id, author, ["chat:write"])
  end

  test "preview uses the source member even when a different member installed the bot", c do
    auth(c)
    channel(c)

    Bypass.expect_once(c.bypass, "GET", "/api/conversations.replies", fn conn ->
      json(conn, %{
        "ok" => true,
        "messages" => [%{"ts" => @root, "user" => "UOTHER", "text" => "A question"}]
      })
    end)

    todo = %Maraithon.Todos.Todo{
      user_id: c.user_id,
      source: "slack",
      metadata: %{"team_id" => "T123", "channel_id" => "C123", "thread_ts" => @root}
    }

    assert {:ok, _, identity} = SlackIdentity.preview(todo, c.source, "as_user")
    assert identity["user_id"] == "U123"
    assert identity["operator_user_id"] == "U123"
  end

  for destination <- ["valid", "wrong_member", "original_dm"] do
    @tag dm_destination: destination
    test "assistant DM preview #{destination} binds its own channel without posting", c do
      %Maraithon.Delegations.AssistantIdentity{user_id: c.user_id}
      |> Maraithon.Delegations.AssistantIdentity.changeset(%{data: %{"display_name" => "October"}})
      |> Maraithon.Repo.insert!()

      auth(c)

      Bypass.expect(c.bypass, "GET", "/api/conversations.info", fn conn ->
        assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer fixture-member"]
        assert URI.decode_query(conn.query_string)["channel"] == "DORIGINAL"

        json(conn, %{
          "ok" => true,
          "channel" => %{"id" => "DORIGINAL", "is_im" => true, "user" => "UCHARLIE"}
        })
      end)

      Bypass.expect(c.bypass, "GET", "/api/conversations.replies", fn conn ->
        assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer fixture-member"]

        json(conn, %{
          "ok" => true,
          "messages" => [
            %{"ts" => @root, "user" => "UCHARLIE", "text" => "Ask me about the project."}
          ]
        })
      end)

      Bypass.expect(c.bypass, "POST", "/api/conversations.open", fn conn ->
        assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer fixture-bot"]
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        assert Jason.decode!(body) == %{"users" => "UCHARLIE", "return_im" => true}

        json(conn, %{
          "ok" => true,
          "channel" => %{
            "id" => if(c.dm_destination == "original_dm", do: "DORIGINAL", else: "DBOT"),
            "is_im" => true,
            "user" => if(c.dm_destination == "wrong_member", do: "UOTHER", else: "UCHARLIE")
          }
        })
      end)

      todo = %Maraithon.Todos.Todo{
        user_id: c.user_id,
        source: "slack",
        metadata: %{"team_id" => "T123", "channel_id" => "DORIGINAL", "thread_ts" => @root}
      }

      if c.dm_destination == "valid" do
        for _ <- 1..2 do
          assert {:ok, scope, identity} = SlackIdentity.preview(todo, c.source, "as_assistant")
          assert scope["channel"] == "DBOT"
          assert scope["source_channel_id"] == "DORIGINAL"
          assert scope["source_thread_id"] == @root
          assert scope["thread_id"] == nil
          assert scope["to"] == ["UCHARLIE"]
          assert identity["user_id"] == "UBOT"
          assert identity["dm_user_id"] == "UCHARLIE"
        end
      else
        assert {:error, :slack_assistant_dm_unavailable} =
                 SlackIdentity.preview(todo, c.source, "as_assistant")
      end
    end
  end

  test "a new assistant DM proves the root timestamp and reconciles it with the bot", c do
    action = action(c, "as_assistant")

    payload =
      action.payload
      |> Map.merge(%{"channel" => "DBOT", "thread_ts" => nil})
      |> Map.update!(
        "_maraithon_slack_author",
        &Map.merge(&1, %{"source_channel" => "DORIGINAL", "dm_user_id" => "UCHARLIE"})
      )

    action = %{action | payload: ActionReconciliation.freeze_identity(action, payload)}
    auth(c)

    Bypass.expect_once(c.bypass, "GET", "/api/conversations.info", fn conn ->
      json(conn, %{
        "ok" => true,
        "channel" => %{"id" => "DBOT", "is_im" => true, "user" => "UCHARLIE"}
      })
    end)

    sent = message(action) |> Map.delete("thread_ts")

    Bypass.expect_once(c.bypass, "POST", "/api/chat.postMessage", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      refute Map.has_key?(Jason.decode!(body), "thread_ts")
      json(conn, %{"ok" => true, "channel" => "DBOT", "ts" => @sent, "message" => sent})
    end)

    assert {:ok, %{thread_id: @sent, ts: @sent}} = SlackPostMessage.execute(action.payload)

    Bypass.expect_once(c.bypass, "GET", "/api/conversations.replies", fn conn ->
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer fixture-bot"]
      assert URI.decode_query(conn.query_string)["ts"] == @sent
      json(conn, %{"ok" => true, "messages" => [sent]})
    end)

    action =
      put_in(action.payload["_maraithon_execution_result"], %{
        "slack_observation" => %{"channel" => "DBOT", "ts" => @sent}
      })

    assert {:ok, %{thread_id: @sent, reconciled: true}} =
             SlackDelivery.observe(action, action.payload[@key])

    refute SlackDelivery.message_matches?(
             Map.put(sent, "thread_ts", @root),
             action.payload[@key],
             @sent
           )
  end

  test "reconnected credentials for a different author stop before posting", c do
    action = action(c)

    Bypass.expect_once(c.bypass, "POST", "/api/auth.test", fn conn ->
      json(conn, %{"ok" => true, "team_id" => "T123", "user_id" => "UOTHER"})
    end)

    assert {:error, :slack_identity_changed} = SlackPostMessage.execute(action.payload)
  end

  test "a single live DM refresh includes unthreaded replies and excludes other threads", c do
    auth(c)
    root = %{"ts" => @root, "user" => "U123", "text" => "What colour?"}

    Bypass.expect_once(
      c.bypass,
      "GET",
      "/api/conversations.replies",
      &json(&1, %{"ok" => true, "messages" => [root]})
    )

    Bypass.expect_once(c.bypass, "GET", "/api/conversations.history", fn conn ->
      query = URI.decode_query(conn.query_string)
      assert query["oldest"] == @root
      assert query["channel"] == "D123"

      json(conn, %{
        "ok" => true,
        "messages" => [
          root,
          %{"ts" => @sent, "thread_ts" => nil, "user" => "UOTHER", "text" => "Indigo"},
          %{
            "ts" => "1789500020.000001",
            "thread_ts" => "1789500020.000000",
            "user" => "UOTHER",
            "text" => "Other thread"
          }
        ]
      })
    end)

    author = action(c).payload["_maraithon_slack_author"]

    assert {:ok, snapshot} =
             Maraithon.Delegations.SlackSource.fetch(c.user_id, author, "D123", @root,
               include_unthreaded?: true
             )

    assert Enum.map(snapshot["messages"], & &1["message_id"]) == [@root, @sent]
    assert List.last(snapshot["messages"])["text_body"] == "Indigo"
  end

  test "short cursor pages retain old participants and only six recent bodies", c do
    auth(c)
    author = action(c).payload["_maraithon_slack_author"]

    messages =
      for n <- 0..179 do
        %{
          "ts" => "#{1_789_500_000 + n}.000001",
          "thread_ts" => @root,
          "user" => if(n == 1, do: "UOLDER", else: "UCHARLIE"),
          "text" => "Fact #{n}"
        }
      end

    pages = [[], Enum.take(messages, 40), Enum.slice(messages, 40, 100), Enum.drop(messages, 140)]

    Bypass.expect(c.bypass, "GET", "/api/conversations.replies", fn conn ->
      query = URI.decode_query(conn.query_string)
      index = String.to_integer(query["cursor"] || "0")
      cursor = if index == 3, do: "", else: Integer.to_string(index + 1)

      json(conn, %{
        "ok" => true,
        "messages" => Enum.at(pages, index),
        "response_metadata" => %{"next_cursor" => cursor}
      })
    end)

    assert {:ok, snapshot} =
             Maraithon.Delegations.SlackSource.fetch(c.user_id, author, "C123", @root)

    assert snapshot["message_count"] == 180
    assert length(snapshot["messages"]) == 6

    assert MapSet.new(Maraithon.Delegations.SlackSource.participants(snapshot, author)) ==
             MapSet.new(~w(UOLDER UCHARLIE))

    assert {:ok, direct} =
             Maraithon.Delegations.SlackSource.snapshot(messages, c.source.id, "C123", @root)

    assert direct["fingerprint"] == snapshot["fingerprint"]
  end

  for defect <- [:cursor_loop, :missing_cursor, :foreign_thread, :duplicate_page] do
    @tag defect: defect
    test "pagination #{defect} never becomes complete evidence", c do
      auth(c)
      author = action(c).payload["_maraithon_slack_author"]
      root = %{"ts" => @root, "user" => "UCHARLIE", "text" => "Root"}
      reply = %{"ts" => @sent, "thread_ts" => @root, "user" => "UCHARLIE", "text" => "Reply"}

      Bypass.expect(c.bypass, "GET", "/api/conversations.replies", fn conn ->
        query = URI.decode_query(conn.query_string)

        response =
          cond do
            c.defect == :missing_cursor ->
              %{"messages" => [root], "has_more" => true}

            is_nil(query["cursor"]) ->
              %{"messages" => [root, reply], "response_metadata" => %{"next_cursor" => "again"}}

            c.defect == :cursor_loop ->
              %{"messages" => [], "response_metadata" => %{"next_cursor" => "again"}}

            c.defect == :foreign_thread ->
              %{"messages" => [%{reply | "thread_ts" => @sent}]}

            true ->
              %{"messages" => [reply]}
          end

        json(conn, Map.put(response, "ok", true))
      end)

      assert {:error, :source_gap} =
               Maraithon.Delegations.SlackSource.fetch(c.user_id, author, "C123", @root)
    end
  end

  test "missing assistant customization scope cannot switch to the member", c do
    action = action(c, "as_assistant")

    {:ok, _} =
      OAuth.store_tokens(c.user_id, "slack:T123", %{
        access_token: "fixture-bot",
        scopes: ["chat:write"]
      })

    assert {:error, {:missing_bot_scope, "chat:write.customize"}} =
             SlackPostMessage.execute(action.payload)
  end

  test "payload changes cannot redirect or rewrite a frozen send", c do
    action = action(c)

    for {field, changed} <- [
          {"text", "changed"},
          {"channel", "COTHER"},
          {"thread_ts", @sent},
          {"team_id", "TOTHER"}
        ] do
      payload = Map.put(action.payload, field, changed)
      refute ActionReconciliation.identified?(%{action | payload: payload})
      assert {:error, :slack_identity_or_channel_unavailable} = SlackPostMessage.execute(payload)
    end
  end

  for {name, response} <- [
        {"internal error", %{"ok" => false, "error" => "internal_error"}},
        {"fatal error", %{"ok" => false, "error" => "fatal_error"}},
        {"malformed success", %{"ok" => true, "ts" => @sent, "channel" => "COTHER"}}
      ] do
    @tag response: response
    test "Slack #{name} stays uncertain after one post", c do
      action = action(c)
      auth(c)
      channel(c)
      Bypass.expect_once(c.bypass, "POST", "/api/chat.postMessage", &json(&1, c.response))
      assert {:error, %{class: :ambiguous} = error} = SlackPostMessage.execute(action.payload)
      assert TelegramAssistant.prepared_action_error_class(error) == :ambiguous
    end
  end

  test "a lost response cannot be proven from similar text or trigger any provider call", c do
    action = action(c)
    assert ActionReconciliation.supported?(action)
    assert ActionReconciliation.identified?(action)
    assert {:pending, :slack_message_not_proven} = ActionReconciliation.observe(action)
  end

  test "a known server timestamp reconciles the bot's exact reply through the bound member", c do
    action = action(c, "as_assistant")

    action = %{
      action
      | payload:
          Map.put(action.payload, "_maraithon_execution_result", %{
            "slack_observation" => %{"ts" => @sent, "channel" => "C123"}
          })
    }

    auth(c)

    Bypass.expect_once(c.bypass, "GET", "/api/conversations.replies", fn conn ->
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer fixture-member"]
      query = URI.decode_query(conn.query_string)

      assert query == %{
               "channel" => "C123",
               "ts" => @root,
               "oldest" => @sent,
               "latest" => @sent,
               "inclusive" => "true",
               "limit" => "2"
             }

      json(conn, %{"ok" => true, "messages" => [message(action)], "has_more" => false})
    end)

    assert {:ok, %{ts: @sent, bot_id: "B123", reconciled: true}} =
             ActionReconciliation.observe(action)
  end

  test "wrong author, edited text, wrong thread and duplicate read evidence never prove delivery",
       c do
    action = action(c)
    identity = action.payload[@key]

    for {key, value} <- [
          {"user", "UOTHER"},
          {"bot_id", "B123"},
          {"text", "different"},
          {"thread_ts", @sent},
          {"edited", %{"ts" => @sent}},
          {"subtype", "message_deleted"},
          {"ts", @root}
        ] do
      refute SlackDelivery.message_matches?(Map.put(message(action), key, value), identity, @sent)
    end

    action = %{
      action
      | payload:
          Map.put(action.payload, "_maraithon_execution_result", %{
            "slack_observation" => %{"ts" => @sent, "channel" => "C123"}
          })
    }

    auth(c)

    for response <- [
          %{"messages" => [message(action), message(action)]},
          %{"messages" => [message(action)], "has_more" => true},
          %{"messages" => [message(action)], "response_metadata" => %{"next_cursor" => "more"}}
        ] do
      Bypass.expect_once(
        c.bypass,
        "GET",
        "/api/conversations.replies",
        &json(&1, Map.put(response, "ok", true))
      )

      assert {:pending, :slack_message_not_proven} = ActionReconciliation.observe(action)
    end
  end

  defp action(c, actor \\ "as_user") do
    bot? = actor == "as_assistant"
    provider = if bot?, do: "slack:T123", else: "slack:T123:user:U123"
    sender = ConnectedAccounts.get(c.user_id, provider)

    author = %{
      "actor" => actor,
      "account_id" => c.source.id,
      "external_account_id" => c.source.external_account_id,
      "source_provider" => c.source.provider,
      "sender_account_id" => sender.id,
      "sender_external_account_id" => sender.external_account_id,
      "provider" => provider,
      "team_id" => "T123",
      "user_id" => if(bot?, do: "UBOT", else: "U123"),
      "bot_id" => if(bot?, do: "B123"),
      "token_preference" => if(bot?, do: "bot", else: "user"),
      "operator_user_id" => "U123",
      "display_name" => "October",
      "icon_url" => "https://example.invalid/october.png"
    }

    action = %{
      id: Ecto.UUID.generate(),
      user_id: c.user_id,
      action_type: "slack_post",
      authorization_kind: "delegation_grant",
      payload: %{}
    }

    payload = %{
      "user_id" => c.user_id,
      "team_id" => "T123",
      "channel" => "C123",
      "thread_ts" => @root,
      "text" => SlackDelivery.text("What colour? <!channel> & <@UOTHER>"),
      "_maraithon_slack_author" => author
    }

    %{action | payload: ActionReconciliation.freeze_identity(action, payload)}
  end

  defp message(action) do
    identity = action.payload[@key]

    %{
      "ts" => @sent,
      "thread_ts" => @root,
      "text" => action.payload["text"],
      "user" => identity["author"]["user_id"],
      "bot_id" => identity["author"]["bot_id"]
    }
  end

  defp auth(c) do
    Bypass.expect(c.bypass, "POST", "/api/auth.test", fn conn ->
      bot? = Plug.Conn.get_req_header(conn, "authorization") == ["Bearer fixture-bot"]

      json(conn, %{
        "ok" => true,
        "team_id" => "T123",
        "user_id" => if(bot?, do: "UBOT", else: "U123"),
        "bot_id" => if(bot?, do: "B123")
      })
    end)
  end

  defp channel(c),
    do:
      Bypass.expect(c.bypass, "GET", "/api/conversations.info", fn conn ->
        json(conn, %{"ok" => true, "channel" => %{"id" => "C123", "is_member" => true}})
      end)

  defp json(conn, body),
    do:
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(body))
end
