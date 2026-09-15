defmodule Maraithon.Delegations.AssistantAccountIsolationTest do
  use Maraithon.DataCase, async: false

  alias Maraithon.{Accounts, AssistantIdentities, ConnectedAccounts, OAuth, Repo, UserIdentity}
  alias Maraithon.ChiefOfStaff.SourceScope
  alias Maraithon.Connectors.Gmail
  alias Maraithon.OAuth.Google
  alias Maraithon.Runtime.SourceAccountDiscovery
  alias Maraithon.Tools.GmailHelpers
  alias Maraithon.Tools.GmailApiHelpers
  alias Maraithon.Tools.GoogleCalendarHelpers

  setup do
    user = "isolation-#{Ecto.UUID.generate()}@example.invalid"
    {:ok, _} = Accounts.get_or_create_user_by_email(user)
    {:ok, user: user}
  end

  test "the assistant OAuth path isolates the mailbox before verifying and binding its address",
       %{user: user} do
    bypass = Bypass.open()
    original = Application.get_env(:maraithon, :gmail, [])
    Application.put_env(:maraithon, :gmail, api_base_url: "http://localhost:#{bypass.port}")
    on_exit(fn -> Application.put_env(:maraithon, :gmail, original) end)
    provider = "google:assistant@example.invalid"

    Bypass.expect_once(bypass, "GET", "/users/me/settings/sendAs", fn conn ->
      assert provider in AssistantIdentities.assistant_providers(user)

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(
        200,
        Jason.encode!(%{
          "sendAs" => [
            %{
              "sendAsEmail" => "assistant@example.invalid",
              "isPrimary" => true
            }
          ]
        })
      )
    end)

    assert {:ok, _} =
             AssistantIdentities.connect_google(
               user,
               provider,
               %{
                 access_token: "assistant-oauth-fixture",
                 expires_in: 3600,
                 scopes: Google.scopes_for(["gmail", "gmail_compose"]),
                 metadata: %{
                   "account_email" => "assistant@example.invalid",
                   "account_name" => "October"
                 }
               },
               "assistant"
             )

    identity = AssistantIdentities.get(user)
    assert identity.data["display_name"] == "October"
    assert identity.gmail_connected_account_id == ConnectedAccounts.get(user, provider).id
    assert SourceScope.google_account_providers(SourceScope.resolve(user)) == []
  end

  test "assistant OAuth does not reclassify an existing personal mailbox", %{user: user} do
    own = account(user, user)

    assert {:error, :assistant_account_is_personal} =
             AssistantIdentities.connect_google(
               user,
               own.provider,
               %{
                 access_token: "must-not-store",
                 metadata: %{"account_email" => user}
               },
               "assistant"
             )

    assert OAuth.get_token(user, own.provider).access_token == "isolation-test-token"
    assert AssistantIdentities.assistant_account_ids(user) == []
  end

  test "a connected read-only mailbox cannot become a sending identity", %{user: user} do
    assistant = account(user, "readonly-assistant@example.invalid", true)

    {:ok, _} =
      AssistantIdentities.put(user, %{
        "display_name" => "October",
        "gmail_mode" => "account",
        "gmail_connected_account_id" => assistant.id,
        "gmail_send_as_email" => "readonly-assistant@example.invalid"
      })

    {:ok, _} =
      OAuth.store_tokens(user, assistant.provider, %{
        access_token: "read-only-fixture",
        scopes: Google.scopes_for(["gmail"])
      })

    assert {:error, :gmail_sending_permission_required} =
             AssistantIdentities.gmail_snapshot(user, "as_assistant", nil)

    own = account(user, user)

    {:ok, _} =
      OAuth.store_tokens(user, own.provider, %{
        access_token: "read-only-fixture",
        scopes: Google.scopes_for(["gmail"])
      })

    assert {:error, :gmail_sending_permission_required} =
             AssistantIdentities.gmail_snapshot(user, "as_user", own.id)

    for scope <-
          ~w(https://mail.google.com/ https://www.googleapis.com/auth/gmail.compose https://www.googleapis.com/auth/gmail.modify https://www.googleapis.com/auth/gmail.send) do
      assert OAuth.gmail_send_scopes?([scope])
    end

    refute OAuth.gmail_send_scopes?(nil)
    refute OAuth.gmail_send_scopes?(Google.scopes_for(["gmail"]))
  end

  test "a cached identity cannot override a newly isolated account", %{user: user} do
    account(user, "cached-assistant@example.invalid")
    assert UserIdentity.own_handle?(user, "cached-assistant@example.invalid")
    account(user, "cached-assistant@example.invalid", true)
    refute UserIdentity.own_handle?(user, "cached-assistant@example.invalid")
  end

  test "the default Google token never falls back to an assistant mailbox", %{user: user} do
    assistant = account(user, "assistant@example.invalid", true)
    assert OAuth.get_token(user, "google") == nil
    assert {:error, :no_token} = OAuth.get_valid_access_token(user, "google")
    assert {:ok, _} = OAuth.get_valid_access_token(user, assistant.provider, exact?: true)

    own = account(user, user)
    account(user, "newer-assistant@example.invalid", true)
    assert OAuth.get_token(user, "google").provider == own.provider
  end

  test "an assistant mailbox is not a personal source or a connector prerequisite", %{user: user} do
    assistant = account(user, "assistant@example.invalid", true)

    assert ConnectedAccounts.list_for_user(user) == [assistant]
    assert ConnectedAccounts.list_personal_for_user(user) == []

    context =
      Maraithon.TelegramAssistant.Context.build(%{
        user_id: user,
        chat_id: "isolation-fixture",
        request_focus: :connector_status
      })

    assert context.connected_accounts == []
    refute "google" in context.defaults.providers

    catalog =
      Maraithon.AgentHarness.ConnectorCatalog.for_user(user, %{
        required_connectors: %{assistant.provider => []}
      })

    assert catalog.connected_apps == []
    assert [%{provider: provider}] = catalog.missing_required_connectors
    assert provider == assistant.provider

    own = account(user, user)
    assert ConnectedAccounts.list_personal_for_user(user) == [own]

    catalog = Maraithon.AgentHarness.ConnectorCatalog.for_user(user, %{})
    assert [%{account_ids: [account_id]}] = catalog.connected_apps
    assert account_id == own.id
  end

  test "the user's primary address is not a separate assistant identity", %{user: user} do
    own = account(user, user)
    bypass = Bypass.open()
    original = Application.get_env(:maraithon, :gmail, [])
    Application.put_env(:maraithon, :gmail, api_base_url: "http://localhost:#{bypass.port}")
    on_exit(fn -> Application.put_env(:maraithon, :gmail, original) end)

    Bypass.expect(bypass, "GET", "/users/me/settings/sendAs", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(
        200,
        Jason.encode!(%{
          "sendAs" => [
            %{"sendAsEmail" => user, "isPrimary" => true, "signature" => "<div>-Kent</div>"}
          ]
        })
      )
    end)

    for mode <- ~w(account alias) do
      assert {:error, :sending_identity_unavailable} =
               AssistantIdentities.configure(user, %{
                 "display_name" => "Assistant",
                 "gmail_connected_account_id" => own.id,
                 "gmail_mode" => mode,
                 "gmail_send_as_email" => user
               })
    end

    assert AssistantIdentities.get(user) == nil
    assert {:ok, snapshot} = AssistantIdentities.gmail_snapshot(user, "as_user", own.id)
    assert snapshot["signature"] == "-Kent"
    assert snapshot["disclose_ai"] == false
  end

  test "assistant messages use the mailbox signature unless explicitly overridden", %{user: user} do
    assistant = account(user, "signature-assistant@example.invalid", true)
    bypass = Bypass.open()
    original = Application.get_env(:maraithon, :gmail, [])
    Application.put_env(:maraithon, :gmail, api_base_url: "http://localhost:#{bypass.port}")
    on_exit(fn -> Application.put_env(:maraithon, :gmail, original) end)

    Bypass.expect(bypass, "GET", "/users/me/settings/sendAs", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(
        200,
        Jason.encode!(%{
          "sendAs" => [
            %{
              "sendAsEmail" => "signature-assistant@example.invalid",
              "isPrimary" => true,
              "signature" => "<div>October</div><div>Office assistant</div>"
            }
          ]
        })
      )
    end)

    for {override, expected} <- [
          {nil, "Office assistant"},
          {"", "Office assistant"},
          {"Custom signature", "Custom signature"}
        ] do
      assert {:ok, _} =
               AssistantIdentities.put(user, %{
                 "display_name" => "October",
                 "gmail_mode" => "account",
                 "gmail_connected_account_id" => assistant.id,
                 "gmail_send_as_email" => "signature-assistant@example.invalid",
                 "disclose_ai" => false,
                 "signature_text" => override
               })

      assert {:ok, snapshot} = AssistantIdentities.gmail_snapshot(user, "as_assistant", nil)
      assert snapshot["signature"] =~ expected
    end
  end

  test "direct personal Gmail and Calendar reads cannot fall back to the only assistant account",
       %{user: user} do
    assistant = account(user, "assistant@example.invalid", true)

    for opts <- [[], [provider: assistant.provider]] do
      assert {:error, :assistant_account_excluded} = Gmail.fetch_messages(user, opts)

      assert {:error, :assistant_account_excluded} =
               Gmail.fetch_message_content(user, "aa11", opts)

      assert {:error, :assistant_account_excluded} =
               Gmail.fetch_thread_content(user, "bb22", opts)

      assert {:error, :assistant_account_excluded} =
               Maraithon.Connectors.GoogleCalendar.sync_calendar_events(user, opts)
    end

    assert {:error, :assistant_account_excluded} = Gmail.sync_mail_changes(user, "42")

    assert {:error, :assistant_account_excluded} =
             Maraithon.Connectors.GoogleCalendar.fetch_upcoming_events(user)

    assert {:error, :assistant_account_excluded} =
             Maraithon.Connectors.GoogleAccount.access_token(user, nil)

    # The delegated worker binds an explicit account and remains able to read it.
    assert {:ok, "isolation-test-token"} =
             Maraithon.Connectors.GoogleAccount.access_token(user, assistant.id)
  end

  test "direct personal reads choose the user while explicit assistant evidence reads remain available",
       %{user: user} do
    own = account(user, user)
    assistant = account(user, "assistant@example.invalid", true)
    {:ok, _} = OAuth.store_tokens(user, own.provider, %{access_token: "personal-read-token"})
    bypass = Bypass.open()
    original = Application.get_env(:maraithon, :gmail, [])
    Application.put_env(:maraithon, :gmail, api_base_url: "http://localhost:#{bypass.port}")
    on_exit(fn -> Application.put_env(:maraithon, :gmail, original) end)

    Bypass.expect_once(bypass, "GET", "/users/me/messages", fn conn ->
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer personal-read-token"]

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, ~s({"messages":[]}))
    end)

    assert {:ok, []} = Gmail.fetch_messages(user)

    Bypass.expect_once(bypass, "GET", "/users/me/messages", fn conn ->
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer isolation-test-token"]

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, ~s({"messages":[]}))
    end)

    {:ok, token} = Maraithon.Connectors.GoogleAccount.access_token(user, assistant.id)
    assert {:ok, []} = Gmail.fetch_messages(token, access_token: true)

    assert {:error, :assistant_account_excluded} =
             Gmail.fetch_messages(user, provider: assistant.provider)
  end

  test "pending assistant setup is excluded from user sources, identity, voice reads and CRM", %{
    user: user
  } do
    own = account(user, user)
    assistant = account(user, "assistant@example.invalid", true)
    assert SourceScope.google_account_providers(SourceScope.resolve(user)) == [own.provider]
    refute UserIdentity.own_handle?(user, "assistant@example.invalid")
    assert UserIdentity.own_handle?(user, user)

    assert {:error, :no_token} =
             GmailHelpers.list_messages(user, provider: assistant.provider, query: "from:me")

    assert {:error, :no_token} =
             GmailHelpers.get_message(user, "assistant-message", provider: assistant.provider)

    assert {:error, :no_token} =
             GoogleCalendarHelpers.list_events(user, provider: assistant.provider)

    assert {:error, :assistant_account_excluded} =
             GmailApiHelpers.resolve_access(%{
               "user_id" => user,
               "provider" => assistant.provider,
               "exact_account" => true
             })

    assert {:ok, ^user, provider, "isolation-test-token"} =
             GmailApiHelpers.resolve_access(%{"user_id" => user})

    assert provider == own.provider

    assert {:error, _} =
             GmailApiHelpers.resolve_access(%{
               "user_id" => user,
               "provider" => "google",
               "exact_account" => true
             })

    assert {:error, :assistant_account_excluded} = SourceAccountDiscovery.acquire(assistant, nil)

    assert {:error, :assistant_account_excluded} =
             SourceAccountDiscovery.reason(assistant, nil, %{})

    assert :ok =
             Gmail.ingest_messages(
               user,
               [
                 %{
                   message_id: "assistant-message",
                   thread_id: "assistant-thread",
                   from: "assistant@example.invalid",
                   to: "counterparty@example.invalid",
                   subject: "Delegated work",
                   body: "Following up on the request."
                 }
               ],
               account: assistant
             )

    refute Repo.exists?(from o in Maraithon.Crm.Observation, where: o.user_id == ^user)
  end

  test "assistant previews freeze the source owner's first-message copy setting", %{user: user} do
    own = account(user, user)
    assistant = account(user, "assistant@example.invalid", true)
    bypass = Bypass.open()
    original = Application.get_env(:maraithon, :gmail, [])
    Application.put_env(:maraithon, :gmail, api_base_url: "http://localhost:#{bypass.port}")
    on_exit(fn -> Application.put_env(:maraithon, :gmail, original) end)

    Bypass.expect(bypass, "GET", "/users/me/settings/sendAs", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(
        200,
        Jason.encode!(%{
          "sendAs" => [%{"sendAsEmail" => "assistant@example.invalid", "isPrimary" => true}]
        })
      )
    end)

    Bypass.expect(bypass, "GET", "/users/me/messages/aa11", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(
        200,
        Jason.encode!(%{
          "id" => "aa11",
          "threadId" => "bb22",
          "labelIds" => ["INBOX"],
          "internalDate" => "1789491600000",
          "payload" => %{
            "headers" => [
              %{"name" => "From", "value" => "Charlie <charlie@example.invalid>"},
              %{"name" => "To", "value" => user},
              %{"name" => "Subject", "value" => "Delivery date"},
              %{"name" => "Message-ID", "value" => "<fixture@example.invalid>"}
            ]
          }
        })
      )
    end)

    {:ok, _} =
      AssistantIdentities.put(user, %{
        "display_name" => "October",
        "gmail_connected_account_id" => assistant.id,
        "gmail_mode" => "account",
        "gmail_send_as_email" => "assistant@example.invalid",
        "cc_user_on_first_send" => true
      })

    todo = %Maraithon.Todos.Todo{
      id: Ecto.UUID.generate(),
      user_id: user,
      owner_user_id: user,
      title: "Get the delivery date",
      summary: "Charlie is confirming the delivery date.",
      next_action: "Ask Charlie",
      source: "gmail",
      source_account_id: own.id,
      source_item_id: "aa11"
    }

    assert {:ok, scope} = Maraithon.Delegations.Scope.preview(todo, %{"actor" => "as_assistant"})
    assert scope["to"] == ["charlie@example.invalid"]
    assert scope["cc"] == []
    assert scope["first_send_cc"] == [user]
    assert scope["source_user_email"] == user
    assert scope["identity"]["cc_user_on_first_send"] == true

    {:ok, _} = AssistantIdentities.put(user, %{"cc_user_on_first_send" => false})

    assert {:ok, changed} =
             Maraithon.Delegations.Scope.preview(todo, %{"actor" => "as_assistant"})

    assert changed["first_send_cc"] == []
    refute scope["scope_hash"] == changed["scope_hash"]
  end

  test "reconnection and changing assistants cannot restore an old assistant as the user", %{
    user: user
  } do
    first = account(user, "first@example.invalid")
    second = account(user, "second@example.invalid")
    assert UserIdentity.own_handle?(user, "first@example.invalid")

    assert {:ok, _} =
             AssistantIdentities.put(user, %{
               "display_name" => "First",
               "gmail_connected_account_id" => first.id,
               "gmail_mode" => "account",
               "gmail_send_as_email" => "first@example.invalid"
             })

    refute UserIdentity.own_handle?(user, "first@example.invalid")

    assert {:ok, _} =
             AssistantIdentities.put(user, %{
               "display_name" => "Second",
               "gmail_connected_account_id" => second.id,
               "gmail_mode" => "account",
               "gmail_send_as_email" => "second@example.invalid"
             })

    account(user, "first@example.invalid")

    assert Enum.sort(AssistantIdentities.assistant_account_ids(user)) ==
             Enum.sort([first.id, second.id])

    assert SourceScope.google_account_providers(SourceScope.resolve(user)) == []
    assert {:error, :no_token} = GmailHelpers.list_messages(user, query: "from:me")
    assert {:error, :no_token} = GmailHelpers.list_messages(user, provider: "google")
    assert {:error, :no_token} = GoogleCalendarHelpers.list_events(user)

    assert {:error, :assistant_account_excluded} =
             GmailApiHelpers.resolve_access(%{"user_id" => user})
  end

  test "an identity cannot bind another user's account and an alias keeps the user's mailbox", %{
    user: user
  } do
    other = "other-#{Ecto.UUID.generate()}@example.invalid"
    {:ok, _} = Accounts.get_or_create_user_by_email(other)
    foreign = account(other, other)

    assert {:error, :invalid_google_account} =
             GmailApiHelpers.get_for_account(user, foreign.id, "/users/me/messages")

    assert {:error, :google_account_not_connected} =
             AssistantIdentities.put(user, %{
               "display_name" => "Assistant",
               "gmail_connected_account_id" => foreign.id
             })

    assert AssistantIdentities.get(user) == nil

    own = account(user, user)

    assert {:ok, _} =
             AssistantIdentities.put(user, %{
               "display_name" => "Assistant",
               "gmail_connected_account_id" => own.id,
               "gmail_mode" => "alias",
               "gmail_send_as_email" => "assistant@example.invalid"
             })

    assert AssistantIdentities.assistant_account_ids(user) == []
    assert SourceScope.google_account_providers(SourceScope.resolve(user)) == [own.provider]
  end

  defp account(user, email, assistant? \\ false) do
    provider = "google:#{email}"

    {:ok, _} =
      OAuth.store_tokens(user, provider, %{
        access_token: "isolation-test-token",
        scopes: Google.scopes_for(["gmail_compose"]),
        metadata: %{"account_email" => email, "assistant_account" => assistant?}
      })

    ConnectedAccounts.get(user, provider)
  end
end
