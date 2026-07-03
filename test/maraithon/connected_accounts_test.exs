defmodule Maraithon.ConnectedAccountsTest do
  use Maraithon.DataCase, async: false

  alias Maraithon.Accounts
  alias Maraithon.ConnectedAccounts
  alias Maraithon.OAuth
  alias Maraithon.TestSupport.CapturingEmail
  alias Maraithon.TestSupport.CapturingTelegram

  setup do
    start_supervised!(%{
      id: :capturing_telegram_recorder,
      start: {Agent, :start_link, [fn -> [] end, [name: :capturing_telegram_recorder]]}
    })

    start_supervised!(%{
      id: :capturing_email_recorder,
      start: {Agent, :start_link, [fn -> [] end, [name: :capturing_email_recorder]]}
    })

    Application.put_env(:maraithon, :connected_accounts,
      telegram_module: CapturingTelegram,
      email_module: CapturingEmail,
      reconnect_base_url: "https://maraithon.test"
    )

    on_exit(fn ->
      Application.delete_env(:maraithon, :connected_accounts)
    end)

    :ok
  end

  test "mark_error/3 sends one push and email reconnect alert for oauth_reauth_required" do
    user_id = "reauth-alert-#{System.unique_integer()}@example.com"
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

    {:ok, _telegram_account} =
      ConnectedAccounts.upsert_manual(user_id, "telegram", %{
        external_account_id: "6114124042",
        metadata: %{"chat_id" => "6114124042"}
      })

    {:ok, _token} =
      OAuth.store_tokens(user_id, "google:founder@example.com", %{
        access_token: "google-token",
        refresh_token: "google-refresh",
        metadata: %{"account_email" => "founder@example.com"}
      })

    assert {:ok, _account} =
             ConnectedAccounts.mark_error(
               user_id,
               "google:founder@example.com",
               "oauth_reauth_required"
             )

    # Repeated error writes should not spam duplicate notifications.
    assert {:ok, _account} =
             ConnectedAccounts.mark_error(
               user_id,
               "google:founder@example.com",
               "oauth_reauth_required"
             )

    messages = Agent.get(:capturing_telegram_recorder, &Enum.reverse/1)

    assert [
             %{
               chat_id: "6114124042",
               text: text
             }
           ] = messages

    assert text =~ "founder@example.com"
    assert text =~ "https://maraithon.test/connectors/google"

    emails = Agent.get(:capturing_email_recorder, &Enum.reverse/1)

    assert [
             %{
               to: ^user_id,
               content: email
             }
           ] = emails

    assert email.subject == "Reconnect Google in Maraithon"
    assert email.text_body =~ "founder@example.com"
    assert email.text_body =~ "https://maraithon.test/connectors/google"

    account = ConnectedAccounts.get(user_id, "google:founder@example.com")

    assert get_in(account.metadata, ["reconnect_notification", "reason"]) ==
             "oauth_reauth_required"

    assert is_binary(get_in(account.metadata, ["reconnect_notification", "sent_at"]))

    assert is_binary(
             get_in(account.metadata, ["reconnect_notification", "channels", "push", "sent_at"])
           )

    assert is_binary(
             get_in(account.metadata, ["reconnect_notification", "channels", "email", "sent_at"])
           )
  end

  test "mark_error/3 sends email when legacy metadata only proves prior push delivery" do
    user_id = "legacy-reconnect-alert-#{System.unique_integer()}@example.com"
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

    {:ok, _telegram_account} =
      ConnectedAccounts.upsert_manual(user_id, "telegram", %{
        external_account_id: "6114124042",
        metadata: %{"chat_id" => "6114124042"}
      })

    # SPEC 10 R3: re-notify-after-N-days makes `sent_at` recency matter now,
    # so this must be "recently sent" (within the renotify window) - the
    # test's intent is the legacy-shape parsing (no per-channel "channels"
    # map), not staleness, so anchor it to "now" instead of a fixed date.
    recent_sent_at = DateTime.utc_now() |> DateTime.to_iso8601()

    {:ok, _token} =
      OAuth.store_tokens(user_id, "google:founder@example.com", %{
        access_token: "google-token",
        refresh_token: "google-refresh",
        metadata: %{
          "account_email" => "founder@example.com",
          "reconnect_notification" => %{
            "reason" => "oauth_reauth_required",
            "sent_at" => recent_sent_at,
            "destination" => "6114124042"
          }
        }
      })

    assert {:ok, _account} =
             ConnectedAccounts.mark_error(
               user_id,
               "google:founder@example.com",
               "oauth_reauth_required"
             )

    assert Agent.get(:capturing_telegram_recorder, &Enum.reverse/1) == []

    assert [
             %{
               to: ^user_id,
               content: email
             }
           ] = Agent.get(:capturing_email_recorder, &Enum.reverse/1)

    assert email.subject == "Reconnect Google in Maraithon"

    account = ConnectedAccounts.get(user_id, "google:founder@example.com")
    refute get_in(account.metadata, ["reconnect_notification", "channels", "push", "sent_at"])

    assert is_binary(
             get_in(account.metadata, ["reconnect_notification", "channels", "email", "sent_at"])
           )
  end

  test "mark_error/3 stores safe generic metadata for structured failures" do
    user_id = "safe-account-error-#{System.unique_integer()}@example.com"
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

    {:ok, _token} =
      OAuth.store_tokens(user_id, "google:founder@example.com", %{
        access_token: "google-token",
        refresh_token: "google-refresh",
        metadata: %{"account_email" => "founder@example.com"}
      })

    assert {:ok, account} =
             ConnectedAccounts.mark_error(
               user_id,
               "google:founder@example.com",
               {:oauth_failed, %{api_key: "sk-or-v1-account-secret-test-value"}}
             )

    last_error = get_in(account.metadata, ["last_error", "reason"])

    assert last_error == "connector_error"
    refute inspect(account.metadata) =~ "sk-or-v1"
  end

  test "report_access_issue/3 sends one push and email reconnect alert when Gmail access is unavailable" do
    user_id = "access-issue-#{System.unique_integer()}@example.com"
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

    {:ok, _telegram_account} =
      ConnectedAccounts.upsert_manual(user_id, "telegram", %{
        external_account_id: "6114124042",
        metadata: %{"chat_id" => "6114124042"}
      })

    assert {:ok, _token} =
             OAuth.store_tokens(user_id, "google:founder@example.com", %{
               access_token: "google-token",
               refresh_token: "google-refresh",
               metadata: %{"account_email" => "founder@example.com"}
             })

    :ok = ConnectedAccounts.report_access_issue(user_id, "google:founder@example.com", :no_token)
    :ok = ConnectedAccounts.report_access_issue(user_id, "google:founder@example.com", :no_token)

    messages = Agent.get(:capturing_telegram_recorder, &Enum.reverse/1)

    assert [
             %{
               chat_id: "6114124042",
               text: text
             }
           ] = messages

    assert text =~ "founder@example.com"
    assert text =~ "https://maraithon.test/connectors/google"

    assert [
             %{
               to: ^user_id,
               content: email
             }
           ] = Agent.get(:capturing_email_recorder, &Enum.reverse/1)

    assert email.text_body =~ "needs re-authentication"

    account = ConnectedAccounts.get(user_id, "google:founder@example.com")
    assert account.status == "error"

    assert get_in(account.metadata, ["reconnect_notification", "reason"]) ==
             "oauth_reauth_required"
  end

  test "mark_disconnected/3 sends one push and email reconnect alert for unexpected disconnects" do
    user_id = "disconnect-alert-#{System.unique_integer()}@example.com"
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

    {:ok, _telegram_account} =
      ConnectedAccounts.upsert_manual(user_id, "telegram", %{
        external_account_id: "6114124042",
        metadata: %{"chat_id" => "6114124042"}
      })

    {:ok, _token} =
      OAuth.store_tokens(user_id, "google:founder@example.com", %{
        access_token: "google-token",
        refresh_token: "google-refresh",
        metadata: %{"account_email" => "founder@example.com"}
      })

    assert {:ok, _account} =
             ConnectedAccounts.mark_disconnected(user_id, "google:founder@example.com")

    assert {:ok, _account} =
             ConnectedAccounts.mark_disconnected(user_id, "google:founder@example.com")

    messages = Agent.get(:capturing_telegram_recorder, &Enum.reverse/1)

    assert [
             %{
               chat_id: "6114124042",
               text: text
             }
           ] = messages

    assert text =~ "founder@example.com"
    assert text =~ "was disconnected"
    assert text =~ "https://maraithon.test/connectors/google"

    assert [
             %{
               to: ^user_id,
               content: email
             }
           ] = Agent.get(:capturing_email_recorder, &Enum.reverse/1)

    assert email.text_body =~ "was disconnected"

    account = ConnectedAccounts.get(user_id, "google:founder@example.com")
    assert account.status == "disconnected"
    assert get_in(account.metadata, ["reconnect_notification", "reason"]) == "disconnected"
  end

  test "mark_disconnected/3 can suppress reconnect alerts for intentional disconnects" do
    user_id = "manual-disconnect-#{System.unique_integer()}@example.com"
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

    {:ok, _telegram_account} =
      ConnectedAccounts.upsert_manual(user_id, "telegram", %{
        external_account_id: "6114124042",
        metadata: %{"chat_id" => "6114124042"}
      })

    {:ok, _token} =
      OAuth.store_tokens(user_id, "google:founder@example.com", %{
        access_token: "google-token",
        refresh_token: "google-refresh",
        metadata: %{"account_email" => "founder@example.com"}
      })

    assert {:ok, _account} =
             apply(ConnectedAccounts, :mark_disconnected, [
               user_id,
               "google:founder@example.com",
               [notify?: false]
             ])

    messages = Agent.get(:capturing_telegram_recorder, &Enum.reverse/1)

    assert messages == []
    assert Agent.get(:capturing_email_recorder, &Enum.reverse/1) == []

    account = ConnectedAccounts.get(user_id, "google:founder@example.com")
    assert account.status == "disconnected"
    assert get_in(account.metadata, ["reconnect_notification"]) == nil
  end

  test "report_access_issue/3 sends a soft 'gone quiet' notice for source_stale (R3)" do
    user_id = "source-stale-alert-#{System.unique_integer()}@example.com"
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

    {:ok, _telegram_account} =
      ConnectedAccounts.upsert_manual(user_id, "telegram", %{
        external_account_id: "6114124042",
        metadata: %{"chat_id" => "6114124042"}
      })

    {:ok, _token} =
      OAuth.store_tokens(user_id, "google:founder@example.com", %{
        access_token: "google-token",
        refresh_token: "google-refresh",
        metadata: %{"account_email" => "founder@example.com"}
      })

    :ok =
      ConnectedAccounts.report_access_issue(user_id, "google:founder@example.com", "source_stale")

    assert [%{chat_id: "6114124042", text: text}] =
             Agent.get(:capturing_telegram_recorder, &Enum.reverse/1)

    assert text =~ "connector check"
    assert text =~ "haven't seen"
    assert text =~ "may need attention"
    refute text =~ "action required"

    account = ConnectedAccounts.get(user_id, "google:founder@example.com")
    assert account.status == "error"
    assert get_in(account.metadata, ["last_error", "reason"]) == "source_stale"
    assert get_in(account.metadata, ["reconnect_notification", "reason"]) == "source_stale"
  end

  test "still-broken sources re-notify after the renotify window (R3)" do
    user_id = "renotify-#{System.unique_integer()}@example.com"
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

    {:ok, _telegram_account} =
      ConnectedAccounts.upsert_manual(user_id, "telegram", %{
        external_account_id: "6114124042",
        metadata: %{"chat_id" => "6114124042"}
      })

    old_sent_at = DateTime.utc_now() |> DateTime.add(-4, :day) |> DateTime.to_iso8601()

    {:ok, _token} =
      OAuth.store_tokens(user_id, "google:founder@example.com", %{
        access_token: "google-token",
        refresh_token: "google-refresh",
        metadata: %{
          "account_email" => "founder@example.com",
          "reconnect_notification" => %{
            "reason" => "oauth_reauth_required",
            "sent_at" => old_sent_at,
            "channels" => %{
              "push" => %{"sent_at" => old_sent_at, "destination" => "6114124042"}
            }
          }
        }
      })

    assert {:ok, _account} =
             ConnectedAccounts.mark_error(
               user_id,
               "google:founder@example.com",
               "oauth_reauth_required"
             )

    assert [%{chat_id: "6114124042"}] = Agent.get(:capturing_telegram_recorder, &Enum.reverse/1)

    account = ConnectedAccounts.get(user_id, "google:founder@example.com")

    new_sent_at =
      get_in(account.metadata, ["reconnect_notification", "channels", "push", "sent_at"])

    refute new_sent_at == old_sent_at

    # Immediately repeating the same still-broken error must not re-notify
    # a second time inside the window.
    assert {:ok, _account} =
             ConnectedAccounts.mark_error(
               user_id,
               "google:founder@example.com",
               "oauth_reauth_required"
             )

    assert [%{chat_id: "6114124042"}] = Agent.get(:capturing_telegram_recorder, &Enum.reverse/1)
  end

  test "reconnecting via OAuth sends exactly one recovery confirmation and re-arms notifications (R4)" do
    user_id = "recovery-#{System.unique_integer()}@example.com"
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

    {:ok, _telegram_account} =
      ConnectedAccounts.upsert_manual(user_id, "telegram", %{
        external_account_id: "6114124042",
        metadata: %{"chat_id" => "6114124042"}
      })

    {:ok, _token} =
      OAuth.store_tokens(user_id, "google:founder@example.com", %{
        access_token: "google-token",
        refresh_token: "google-refresh",
        metadata: %{"account_email" => "founder@example.com"}
      })

    assert {:ok, _account} =
             ConnectedAccounts.mark_error(
               user_id,
               "google:founder@example.com",
               "oauth_reauth_required"
             )

    # Clear the notification recorder so only the recovery send is counted.
    Agent.update(:capturing_telegram_recorder, fn _ -> [] end)

    assert {:ok, recovered_account} =
             ConnectedAccounts.upsert_from_oauth(user_id, "google:founder@example.com", %{
               access_token: "new-google-token",
               refresh_token: "new-google-refresh",
               metadata: %{"account_email" => "founder@example.com"}
             })

    assert recovered_account.status == "connected"
    refute get_in(recovered_account.metadata, ["reconnect_notification"])

    assert [%{chat_id: "6114124042", text: text}] =
             Agent.get(:capturing_telegram_recorder, &Enum.reverse/1)

    assert text =~ "connected again"

    # A second successful refresh with nothing previously pending must not
    # send another recovery confirmation.
    assert {:ok, _account} =
             ConnectedAccounts.upsert_from_oauth(user_id, "google:founder@example.com", %{
               access_token: "newer-google-token",
               refresh_token: "newer-google-refresh",
               metadata: %{"account_email" => "founder@example.com"}
             })

    assert [%{chat_id: "6114124042"}] = Agent.get(:capturing_telegram_recorder, &Enum.reverse/1)

    # A fresh failure after recovery should be able to notify again (re-armed).
    assert {:ok, _account} =
             ConnectedAccounts.mark_error(
               user_id,
               "google:founder@example.com",
               "oauth_reauth_required"
             )

    assert [_recovery, %{chat_id: "6114124042"}] =
             Agent.get(:capturing_telegram_recorder, &Enum.reverse/1)
  end

  test "get_connected_by_external_account/2 falls back to Telegram metadata chat_id" do
    user_id = "telegram-metadata-#{System.unique_integer()}@example.com"
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

    assert {:ok, account} =
             ConnectedAccounts.upsert_manual(user_id, "telegram", %{
               metadata: %{"chat_id" => "6114124042", "username" => "kentfenwick"}
             })

    assert is_nil(account.external_account_id)

    assert %Maraithon.Accounts.ConnectedAccount{id: connected_id} =
             ConnectedAccounts.get_connected_by_external_account("telegram", "6114124042")

    assert connected_id == account.id
  end
end
