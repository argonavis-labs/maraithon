defmodule Maraithon.Delegations.AssistantAccountIsolationTest do
  use Maraithon.DataCase, async: false

  alias Maraithon.{Accounts, AssistantIdentities, ConnectedAccounts, OAuth, Repo, UserIdentity}
  alias Maraithon.ChiefOfStaff.SourceScope
  alias Maraithon.Connectors.Gmail
  alias Maraithon.OAuth.Google
  alias Maraithon.Runtime.SourceAccountDiscovery
  alias Maraithon.Tools.GmailHelpers
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

  test "a cached identity cannot override a newly isolated account", %{user: user} do
    account(user, "cached-assistant@example.invalid")
    assert UserIdentity.own_handle?(user, "cached-assistant@example.invalid")
    account(user, "cached-assistant@example.invalid", true)
    refute UserIdentity.own_handle?(user, "cached-assistant@example.invalid")
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
  end

  test "an identity cannot bind another user's account and an alias keeps the user's mailbox", %{
    user: user
  } do
    other = "other-#{Ecto.UUID.generate()}@example.invalid"
    {:ok, _} = Accounts.get_or_create_user_by_email(other)
    foreign = account(other, other)

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
        scopes: Google.scopes_for(["gmail"]),
        metadata: %{"account_email" => email, "assistant_account" => assistant?}
      })

    ConnectedAccounts.get(user, provider)
  end
end
