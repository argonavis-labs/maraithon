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
          scopes: ["chat:write", "chat:write.customize", "channels:history"],
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

    todo = %Maraithon.Todos.Todo{
      user_id: c.user_id,
      source: "slack",
      metadata: %{"team_id" => "T123", "channel_id" => "C123", "thread_ts" => @root}
    }

    assert {:ok, _, identity} = SlackIdentity.preview(todo, c.source, "as_user")
    assert identity["user_id"] == "U123"
    assert identity["operator_user_id"] == "U123"
  end

  test "reconnected credentials for a different author stop before posting", c do
    action = action(c)

    Bypass.expect_once(c.bypass, "POST", "/api/auth.test", fn conn ->
      json(conn, %{"ok" => true, "team_id" => "T123", "user_id" => "UOTHER"})
    end)

    assert {:error, :slack_identity_changed} = SlackPostMessage.execute(action.payload)
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

  test "Slack partial errors and malformed success stay uncertain after one post", c do
    action = action(c)
    auth(c)
    channel(c)

    for response <- [
          %{"ok" => false, "error" => "internal_error"},
          %{"ok" => false, "error" => "fatal_error"},
          %{"ok" => true, "ts" => @sent, "channel" => "COTHER"}
        ] do
      Bypass.expect_once(c.bypass, "POST", "/api/chat.postMessage", &json(&1, response))
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
