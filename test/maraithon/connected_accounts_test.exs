defmodule Maraithon.ConnectedAccountsTest do
  use Maraithon.DataCase, async: false

  alias Maraithon.Accounts
  alias Maraithon.ConnectedAccounts
  alias Maraithon.OAuth
  alias Maraithon.TestSupport.CapturingAPNS
  alias Maraithon.TestSupport.CapturingEmail

  setup do
    start_supervised!(%{
      id: :capturing_apns_recorder,
      start: {Agent, :start_link, [fn -> [] end, [name: :capturing_apns_recorder]]}
    })

    start_supervised!(%{
      id: :capturing_email_recorder,
      start: {Agent, :start_link, [fn -> [] end, [name: :capturing_email_recorder]]}
    })

    Application.put_env(:maraithon, :connected_accounts,
      email_module: CapturingEmail,
      reconnect_base_url: "https://maraithon.test"
    )

    # SPEC 02 R9: reconnect pushes ride PushBroker (quiet hours, receipts),
    # which now delivers via APNs to the user's registered devices. Enable
    # the unified broker and pin the quiet-hours window away from the
    # current local hour so tests are deterministic regardless of when they
    # run; the quiet-hours test below overrides the window explicitly.
    original_assistant = Application.get_env(:maraithon, :telegram_assistant, [])

    local_hour = Maraithon.TelegramAssistant.PushBroker.local_now_for_user("setup").hour

    Application.put_env(
      :maraithon,
      :telegram_assistant,
      Keyword.merge(original_assistant,
        telegram_unified_push_enabled: true,
        quiet_hours_start_local: rem(local_hour + 2, 24),
        quiet_hours_end_local: rem(local_hour + 3, 24)
      )
    )

    on_exit(fn ->
      Application.delete_env(:maraithon, :connected_accounts)
      Application.put_env(:maraithon, :telegram_assistant, original_assistant)
    end)

    :ok
  end

  test "mark_error/3 sends one push and email reconnect alert for oauth_reauth_required" do
    user_id = "reauth-alert-#{System.unique_integer()}@example.com"
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)
    :ok = CapturingAPNS.enable(user_id)

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

    assert [%{payload: payload}] = CapturingAPNS.recorded()

    assert payload["aps"]["alert"]["title"] == "Connector health: Google"

    body = payload["aps"]["alert"]["body"]
    assert body =~ "founder@example.com"
    assert body =~ "needs re-authentication"

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

  # SPEC 02 R9: a reconnect push attempted during quiet hours is held by
  # PushBroker — not marked sent (renotify window not stamped), no
  # sent_now PushReceipt — and the same attempt outside quiet hours goes
  # through and is marked sent.
  test "reconnect push during quiet hours is held and not marked sent; retried outside" do
    user_id = "quiet-hours-reconnect-#{System.unique_integer()}@example.com"
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)
    :ok = CapturingAPNS.enable(user_id)

    {:ok, _token} =
      OAuth.store_tokens(user_id, "google:quiet@example.com", %{
        access_token: "google-token",
        refresh_token: "google-refresh",
        metadata: %{"account_email" => "quiet@example.com"}
      })

    # Force quiet hours around the user's current local hour.
    local_hour = Maraithon.TelegramAssistant.PushBroker.local_now_for_user(user_id).hour
    assistant_config = Application.get_env(:maraithon, :telegram_assistant, [])

    Application.put_env(
      :maraithon,
      :telegram_assistant,
      Keyword.merge(assistant_config,
        quiet_hours_start_local: local_hour,
        quiet_hours_end_local: rem(local_hour + 1, 24)
      )
    )

    assert {:ok, _account} =
             ConnectedAccounts.mark_error(
               user_id,
               "google:quiet@example.com",
               "oauth_reauth_required"
             )

    # No push went out and no sent_now receipt exists.
    assert CapturingAPNS.recorded() == []

    refute Repo.exists?(
             from(receipt in Maraithon.TelegramAssistant.PushReceipt,
               where: receipt.user_id == ^user_id and receipt.decision == "sent_now"
             )
           )

    # The renotify window was not stamped for the push channel (email may
    # still have gone out independently).
    account = ConnectedAccounts.get(user_id, "google:quiet@example.com")

    refute get_in(account.metadata, ["reconnect_notification", "channels", "push", "sent_at"])

    # Quiet hours end; the next report_access_issue (FreshnessSweep would
    # drive this hourly in production) retries and succeeds.
    Application.put_env(
      :maraithon,
      :telegram_assistant,
      Keyword.merge(assistant_config,
        quiet_hours_start_local: rem(local_hour + 2, 24),
        quiet_hours_end_local: rem(local_hour + 3, 24)
      )
    )

    assert :ok =
             ConnectedAccounts.report_access_issue(
               user_id,
               "google:quiet@example.com",
               "oauth_reauth_required"
             )

    assert [%{payload: payload}] = CapturingAPNS.recorded()
    assert payload["aps"]["alert"]["body"] =~ "quiet@example.com"

    assert Repo.exists?(
             from(receipt in Maraithon.TelegramAssistant.PushReceipt,
               where: receipt.user_id == ^user_id and receipt.decision == "sent_now"
             )
           )

    account = ConnectedAccounts.get(user_id, "google:quiet@example.com")

    assert is_binary(
             get_in(account.metadata, ["reconnect_notification", "channels", "push", "sent_at"])
           )
  end

  test "mark_error/3 sends email when legacy metadata only proves prior push delivery" do
    user_id = "legacy-reconnect-alert-#{System.unique_integer()}@example.com"
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)
    :ok = CapturingAPNS.enable(user_id)

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

    assert CapturingAPNS.recorded() == []

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
    :ok = CapturingAPNS.enable(user_id)

    assert {:ok, _token} =
             OAuth.store_tokens(user_id, "google:founder@example.com", %{
               access_token: "google-token",
               refresh_token: "google-refresh",
               metadata: %{"account_email" => "founder@example.com"}
             })

    :ok = ConnectedAccounts.report_access_issue(user_id, "google:founder@example.com", :no_token)
    :ok = ConnectedAccounts.report_access_issue(user_id, "google:founder@example.com", :no_token)

    assert [%{payload: payload}] = CapturingAPNS.recorded()

    assert payload["aps"]["alert"]["title"] == "Connector health: Google"
    assert payload["aps"]["alert"]["body"] =~ "founder@example.com"

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
    :ok = CapturingAPNS.enable(user_id)

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

    assert [%{payload: payload}] = CapturingAPNS.recorded()

    body = payload["aps"]["alert"]["body"]
    assert body =~ "founder@example.com"
    assert body =~ "was disconnected"

    assert [
             %{
               to: ^user_id,
               content: email
             }
           ] = Agent.get(:capturing_email_recorder, &Enum.reverse/1)

    assert email.text_body =~ "was disconnected"
    assert email.text_body =~ "https://maraithon.test/connectors/google"

    account = ConnectedAccounts.get(user_id, "google:founder@example.com")
    assert account.status == "disconnected"
    assert get_in(account.metadata, ["reconnect_notification", "reason"]) == "disconnected"
  end

  test "mark_disconnected/3 can suppress reconnect alerts for intentional disconnects" do
    user_id = "manual-disconnect-#{System.unique_integer()}@example.com"
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)
    :ok = CapturingAPNS.enable(user_id)

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

    assert CapturingAPNS.recorded() == []
    assert Agent.get(:capturing_email_recorder, &Enum.reverse/1) == []

    account = ConnectedAccounts.get(user_id, "google:founder@example.com")
    assert account.status == "disconnected"
    assert get_in(account.metadata, ["reconnect_notification"]) == nil
  end

  test "report_access_issue/3 sends a soft 'gone quiet' notice for source_stale (R3)" do
    user_id = "source-stale-alert-#{System.unique_integer()}@example.com"
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)
    :ok = CapturingAPNS.enable(user_id)

    {:ok, _token} =
      OAuth.store_tokens(user_id, "google:founder@example.com", %{
        access_token: "google-token",
        refresh_token: "google-refresh",
        metadata: %{"account_email" => "founder@example.com"}
      })

    :ok =
      ConnectedAccounts.report_access_issue(user_id, "google:founder@example.com", "source_stale")

    assert [%{payload: payload}] = CapturingAPNS.recorded()

    text = payload["aps"]["alert"]["body"]
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
    :ok = CapturingAPNS.enable(user_id)

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
              "push" => %{"sent_at" => old_sent_at}
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

    assert [%{payload: _payload}] = CapturingAPNS.recorded()

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

    assert [%{payload: _payload}] = CapturingAPNS.recorded()
  end

  test "reconnecting via OAuth sends exactly one recovery confirmation and re-arms notifications (R4)" do
    user_id = "recovery-#{System.unique_integer()}@example.com"
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)
    :ok = CapturingAPNS.enable(user_id)

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
    Agent.update(:capturing_apns_recorder, fn _ -> [] end)

    assert {:ok, recovered_account} =
             ConnectedAccounts.upsert_from_oauth(user_id, "google:founder@example.com", %{
               access_token: "new-google-token",
               refresh_token: "new-google-refresh",
               metadata: %{"account_email" => "founder@example.com"}
             })

    assert recovered_account.status == "connected"
    refute get_in(recovered_account.metadata, ["reconnect_notification"])

    assert [%{payload: payload}] = CapturingAPNS.recorded()
    assert payload["aps"]["alert"]["body"] =~ "connected again"

    # A second successful refresh with nothing previously pending must not
    # send another recovery confirmation.
    assert {:ok, _account} =
             ConnectedAccounts.upsert_from_oauth(user_id, "google:founder@example.com", %{
               access_token: "newer-google-token",
               refresh_token: "newer-google-refresh",
               metadata: %{"account_email" => "founder@example.com"}
             })

    assert [%{payload: _payload}] = CapturingAPNS.recorded()

    # A fresh failure after recovery should be able to notify again
    # (re-armed) once the flap-damping window has passed. Flap damping
    # (added alongside this fix) holds a *new* failure notification for
    # `@flap_damping_window_minutes` after a recovery confirmation, so a
    # failure milliseconds later (as this test would otherwise exercise)
    # is intentionally suppressed — see the rapid-flap test below. Backdate
    # `recovery_confirmed_at` here (instead of sleeping in the test) to
    # simulate the window having elapsed and exercise genuine re-arm.
    recovered_again_account =
      ConnectedAccounts.get(user_id, "google:founder@example.com")

    backdated_metadata =
      Map.put(
        recovered_again_account.metadata,
        "recovery_confirmed_at",
        DateTime.utc_now() |> DateTime.add(-90, :minute) |> DateTime.to_iso8601()
      )

    assert {:ok, _account} =
             recovered_again_account
             |> Maraithon.Accounts.ConnectedAccount.changeset(%{metadata: backdated_metadata})
             |> Maraithon.Repo.update()

    assert {:ok, _account} =
             ConnectedAccounts.mark_error(
               user_id,
               "google:founder@example.com",
               "oauth_reauth_required"
             )

    assert [_recovery, %{payload: renotify_payload}] = CapturingAPNS.recorded()
    assert renotify_payload["aps"]["alert"]["body"] =~ "re-authentication"
  end

  test "rapid fail/recover/fail/recover flapping is damped to one notify and one confirm, and re-arms after the window (R4 flap damping)" do
    user_id = "flap-#{System.unique_integer()}@example.com"
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)
    :ok = CapturingAPNS.enable(user_id)

    {:ok, _token} =
      OAuth.store_tokens(user_id, "google:founder@example.com", %{
        access_token: "google-token",
        refresh_token: "google-refresh",
        metadata: %{"account_email" => "founder@example.com"}
      })

    # fail1 -> notify1
    assert {:ok, _account} =
             ConnectedAccounts.mark_error(
               user_id,
               "google:founder@example.com",
               "oauth_reauth_required"
             )

    assert [%{payload: notify1_payload}] = CapturingAPNS.recorded()
    assert notify1_payload["aps"]["alert"]["body"] =~ "re-authentication"

    Agent.update(:capturing_apns_recorder, fn _ -> [] end)

    # recover1 -> confirm1
    assert {:ok, _account} =
             ConnectedAccounts.upsert_from_oauth(user_id, "google:founder@example.com", %{
               access_token: "new-google-token",
               refresh_token: "new-google-refresh",
               metadata: %{"account_email" => "founder@example.com"}
             })

    assert [%{payload: confirm1_payload}] = CapturingAPNS.recorded()
    assert confirm1_payload["aps"]["alert"]["body"] =~ "connected again"

    Agent.update(:capturing_apns_recorder, fn _ -> [] end)

    # fail2, immediately after recover1 (still inside the damping window) ->
    # error state is still recorded, but the notification is held.
    assert {:ok, failed_again_account} =
             ConnectedAccounts.mark_error(
               user_id,
               "google:founder@example.com",
               "oauth_reauth_required"
             )

    assert failed_again_account.status == "error"
    assert CapturingAPNS.recorded() == []

    # recover2, also immediately -> no pending notification to confirm, so no
    # second "connected again" either. The flap stays silent both directions.
    assert {:ok, _account} =
             ConnectedAccounts.upsert_from_oauth(user_id, "google:founder@example.com", %{
               access_token: "newer-google-token",
               refresh_token: "newer-google-refresh",
               metadata: %{"account_email" => "founder@example.com"}
             })

    assert CapturingAPNS.recorded() == []

    # A genuine failure after the damping window has elapsed still notifies
    # immediately (re-arm intact). Backdate recovery_confirmed_at instead of
    # sleeping in the test.
    account = ConnectedAccounts.get(user_id, "google:founder@example.com")

    backdated_metadata =
      Map.put(
        account.metadata,
        "recovery_confirmed_at",
        DateTime.utc_now() |> DateTime.add(-90, :minute) |> DateTime.to_iso8601()
      )

    assert {:ok, _account} =
             account
             |> Maraithon.Accounts.ConnectedAccount.changeset(%{metadata: backdated_metadata})
             |> Maraithon.Repo.update()

    assert {:ok, _account} =
             ConnectedAccounts.mark_error(
               user_id,
               "google:founder@example.com",
               "oauth_reauth_required"
             )

    assert [%{payload: notify2_payload}] = CapturingAPNS.recorded()
    assert notify2_payload["aps"]["alert"]["body"] =~ "re-authentication"
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
