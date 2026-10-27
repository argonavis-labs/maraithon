defmodule Maraithon.SourceFreshnessTest do
  use Maraithon.DataCase, async: false

  alias Maraithon.Accounts
  alias Maraithon.Accounts.ConnectedAccount
  alias Maraithon.ConnectedAccounts
  alias Maraithon.SourceFreshness
  alias Maraithon.TestSupport.CapturingAPNS
  alias Maraithon.TestSupport.CapturingEmail
  alias Maraithon.TelegramAssistant.Context

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

    # Recovery confirmations ride PushBroker (SPEC 02 R9), which now
    # delivers via APNs to the user's registered devices. The broker itself
    # defaults to disabled in tests — enable it, and pin the quiet-hours
    # window away from the current local hour so pushes are never held.
    previous_assistant = Application.get_env(:maraithon, :telegram_assistant, [])

    local_hour = Maraithon.TelegramAssistant.PushBroker.local_now_for_user("setup").hour

    Application.put_env(
      :maraithon,
      :telegram_assistant,
      Keyword.merge(previous_assistant,
        telegram_unified_push_enabled: true,
        quiet_hours_start_local: rem(local_hour + 2, 24),
        quiet_hours_end_local: rem(local_hour + 3, 24)
      )
    )

    on_exit(fn ->
      Application.delete_env(:maraithon, :connected_accounts)
      Application.put_env(:maraithon, :telegram_assistant, previous_assistant)
    end)

    :ok
  end

  test "computes fresh, stale, and reauth-required source states" do
    user_id = "source-freshness-#{System.unique_integer([:positive])}@example.com"
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

    now = ~U[2026-05-10 12:00:00Z]
    stale_at = ~U[2026-05-07 12:00:00Z]

    {:ok, _gmail} =
      ConnectedAccounts.upsert_manual(user_id, "google", %{
        external_account_id: "gmail@example.com",
        metadata: %{"last_successful_sync_at" => DateTime.to_iso8601(stale_at)}
      })

    {:ok, _telegram} =
      ConnectedAccounts.upsert_manual(user_id, "telegram", %{external_account_id: "12345"})

    assert {:ok, _linear} =
             SourceFreshness.mark_error(user_id, "telegram", "invalid_grant reauth required",
               at: now
             )

    assert CapturingAPNS.recorded() == []

    assert [
             %{
               to: ^user_id,
               content: email
             }
           ] = Agent.get(:capturing_email_recorder, &Enum.reverse/1)

    assert email.subject == "Reconnect Telegram in Maraithon"

    snapshots = SourceFreshness.for_user(user_id, now: now)

    google = Enum.find(snapshots, &(&1.provider == "google"))
    assert google.status == "stale"
    assert google.stale_reason == "Last successful Google check was 3 days ago."
    refute google.stale_reason =~ "sync"
    refute google.stale_reason =~ "unknown"

    telegram = Enum.find(snapshots, &(&1.provider == "telegram"))
    assert telegram.status == "reauth_required"
    assert telegram.last_error["reason"] =~ "invalid_grant"

    assert %{stale_reason: "Last successful Google check was 3 days ago."} =
             user_id
             |> SourceFreshness.compact_for_prompt(now: now)
             |> Enum.find(&(&1.provider == "google"))
  end

  test "describes never-checked sources without sync jargon" do
    now = ~U[2026-05-10 12:00:00Z]

    snapshot =
      SourceFreshness.for_account(
        %ConnectedAccount{
          user_id: "never-checked@example.com",
          provider: "google",
          external_account_id: "work@example.com",
          status: "connected",
          metadata: %{},
          updated_at: now
        },
        now: now
      )

    assert snapshot.status == "never_synced"
    assert snapshot.stale_reason == "Google has not completed a source check yet."
    refute snapshot.stale_reason =~ "sync"
  end

  test "compact_for_prompt includes a reconnect_url for broken sources only (R5)" do
    user_id = "source-freshness-reconnect-url-#{System.unique_integer([:positive])}@example.com"
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

    Application.put_env(:maraithon, :connected_accounts,
      reconnect_base_url: "https://maraithon.test"
    )

    on_exit(fn -> Application.delete_env(:maraithon, :connected_accounts) end)

    {:ok, _google} =
      ConnectedAccounts.upsert_manual(user_id, "google:founder@example.com", %{
        external_account_id: "founder@example.com",
        metadata: %{"account_email" => "founder@example.com"}
      })

    assert {:ok, _account} =
             SourceFreshness.mark_error(
               user_id,
               "google:founder@example.com",
               "oauth_reauth_required"
             )

    snapshots = SourceFreshness.compact_for_prompt(user_id)
    google = Enum.find(snapshots, &(&1.provider == "google"))

    assert google.status == "reauth_required"
    assert google.reconnect_url == "https://maraithon.test/connectors/google"
  end

  test "mark_success sends a one-time recovery confirmation and re-arms notifications (R4)" do
    user_id = "source-freshness-recovery-#{System.unique_integer([:positive])}@example.com"
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)
    :ok = CapturingAPNS.enable(user_id)

    {:ok, _google} =
      ConnectedAccounts.upsert_manual(user_id, "google:founder@example.com", %{
        external_account_id: "founder@example.com",
        metadata: %{"account_email" => "founder@example.com"}
      })

    assert {:ok, _account} =
             SourceFreshness.mark_error(
               user_id,
               "google:founder@example.com",
               "oauth_reauth_required"
             )

    assert [%{payload: notify_payload}] = CapturingAPNS.recorded()
    assert notify_payload["aps"]["alert"]["title"] == "Connector health: Google"
    Agent.update(:capturing_apns_recorder, fn _ -> [] end)

    assert {:ok, recovered} = SourceFreshness.mark_success(user_id, "google:founder@example.com")
    assert recovered.status == "connected"
    refute get_in(recovered.metadata, ["reconnect_notification"])

    assert [%{payload: recovery_payload}] = CapturingAPNS.recorded()
    assert recovery_payload["aps"]["alert"]["body"] =~ "connected again"

    # A second success with nothing pending must not re-confirm.
    assert {:ok, _recovered} = SourceFreshness.mark_success(user_id, "google:founder@example.com")
    assert [%{payload: _payload}] = CapturingAPNS.recorded()
  end

  test "injects compact freshness into Telegram assistant context" do
    user_id = "context-freshness-#{System.unique_integer([:positive])}@example.com"
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

    {:ok, _telegram} =
      ConnectedAccounts.upsert_manual(user_id, "telegram", %{external_account_id: "12345"})

    context = Context.build(%{user_id: user_id, chat_id: "12345"})

    assert [%{provider: "telegram", account_label: "Telegram", status: "fresh"}] =
             context.source_freshness

    refute inspect(context.source_freshness) =~ "12345"
    refute Enum.any?(context.source_freshness, &Map.has_key?(&1, :account_id))
  end

  test "compact freshness hides provider and account internals from prompt context" do
    user_id = "source-freshness-prompt-#{System.unique_integer([:positive])}@example.com"
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

    now = ~U[2026-05-10 12:00:00Z]

    {:ok, _slack} =
      ConnectedAccounts.upsert_manual(user_id, "slack:TSECRET:user:USECRET", %{
        external_account_id: "TSECRET",
        metadata: %{"team_name" => "Agora"}
      })

    {:ok, _slack_error} =
      SourceFreshness.mark_error(
        user_id,
        "slack:TSECRET:user:USECRET",
        "invalid_grant token=TSECRET user=USECRET",
        at: now
      )

    {:ok, _google} =
      ConnectedAccounts.upsert_manual(user_id, "google:founder@example.com", %{
        external_account_id: "google-account-raw",
        metadata: %{"account_email" => "founder@example.com"}
      })

    snapshots = SourceFreshness.compact_for_prompt(user_id, now: now)

    assert %{
             provider: "slack",
             account_label: "Agora",
             status: "reauth_required",
             stale_reason: "needs reconnect",
             last_error: %{"reason" => "needs reconnect"}
           } = Enum.find(snapshots, &(&1.provider == "slack"))

    assert %{provider: "google", account_label: "founder@example.com", status: "fresh"} =
             Enum.find(snapshots, &(&1.provider == "google"))

    encoded = inspect(snapshots)
    refute encoded =~ "TSECRET"
    refute encoded =~ "USECRET"
    refute encoded =~ "google-account-raw"
    refute encoded =~ "invalid_grant"
    refute Enum.any?(snapshots, &Map.has_key?(&1, :account_id))
  end
end
