defmodule Maraithon.Runtime.FreshnessSweepTest do
  use Maraithon.DataCase, async: false

  alias Maraithon.Accounts
  alias Maraithon.ConnectedAccounts
  alias Maraithon.Connectors.SourceCursors
  alias Maraithon.OAuth
  alias Maraithon.Runtime.FreshnessSweep
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
      email_module: CapturingEmail
    )

    # Reconnect pushes ride PushBroker (SPEC 02 R9), whose sends go through
    # TelegramResponder and the :insights telegram module — stub that too or
    # the captured-notification assertions silently test nothing.
    previous_insights = Application.get_env(:maraithon, :insights, [])

    Application.put_env(
      :maraithon,
      :insights,
      Keyword.put(previous_insights, :telegram_module, CapturingTelegram)
    )

    # ... and the broker itself defaults to disabled in tests, which turns
    # every reconnect push into a silent skip.
    previous_assistant = Application.get_env(:maraithon, :telegram_assistant, [])

    Application.put_env(
      :maraithon,
      :telegram_assistant,
      Keyword.put(previous_assistant, :telegram_unified_push_enabled, true)
    )

    on_exit(fn ->
      Application.delete_env(:maraithon, :connected_accounts)
      Application.put_env(:maraithon, :insights, previous_insights)
      Application.put_env(:maraithon, :telegram_assistant, previous_assistant)
    end)

    :ok
  end

  test "R2: flags a source that has gone quiet beyond its staleness threshold" do
    user_id = "freshness-sweep-stale-#{System.unique_integer([:positive])}@example.com"
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

    {:ok, _telegram} =
      ConnectedAccounts.upsert_manual(user_id, "telegram", %{external_account_id: "112233"})

    stale_at = DateTime.add(DateTime.utc_now(), -30, :hour)

    {:ok, _google} =
      ConnectedAccounts.upsert_manual(user_id, "google:founder@example.com", %{
        external_account_id: "founder@example.com",
        metadata: %{
          "account_email" => "founder@example.com",
          "last_successful_sync_at" => DateTime.to_iso8601(stale_at)
        }
      })

    start_supervised!(
      {FreshnessSweep,
       name: nil,
       observer: self(),
       interval_ms: :timer.hours(1),
       batch_size: 5_000,
       initial_delay_ms: 10}
    )

    assert_receive {:freshness_sweep_cycle, %{checked: checked, flagged: flagged}}, 2_000
    assert checked >= 1
    assert flagged >= 1

    account = ConnectedAccounts.get(user_id, "google:founder@example.com")
    assert account.status == "error"
    assert get_in(account.metadata, ["last_error", "reason"]) == "source_stale"

    # Filter to this test's own destination: the sweep also walks any other
    # connected accounts already present (this suite does not run against a
    # pristine per-test database), so other rows may notify too.
    assert [%{text: text}] =
             :capturing_telegram_recorder
             |> Agent.get(&Enum.reverse/1)
             |> Enum.filter(&(&1.chat_id == "112233"))

    assert text =~ "haven't seen"
  end

  test "R2: does not flag a freshly connected account that has not synced yet" do
    user_id = "freshness-sweep-fresh-#{System.unique_integer([:positive])}@example.com"
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

    {:ok, _google} =
      ConnectedAccounts.upsert_manual(user_id, "google:founder@example.com", %{
        external_account_id: "founder@example.com",
        metadata: %{"account_email" => "founder@example.com"}
      })

    start_supervised!(
      {FreshnessSweep,
       name: nil,
       observer: self(),
       interval_ms: :timer.hours(1),
       batch_size: 5_000,
       never_synced_after_hours: 24,
       initial_delay_ms: 10}
    )

    assert_receive {:freshness_sweep_cycle, %{}}, 2_000

    account = ConnectedAccounts.get(user_id, "google:founder@example.com")
    assert account.status == "connected"
  end

  test "R2: flags a never-synced account once it has been connected past the threshold" do
    user_id = "freshness-sweep-never-synced-#{System.unique_integer([:positive])}@example.com"
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

    {:ok, account} =
      ConnectedAccounts.upsert_manual(user_id, "google:founder@example.com", %{
        external_account_id: "founder@example.com",
        metadata: %{"account_email" => "founder@example.com"}
      })

    old_inserted_at =
      DateTime.add(DateTime.utc_now(), -48, :hour) |> DateTime.truncate(:second)

    # Simulate a genuinely never-synced row: no `connected_at`/
    # `last_refreshed_at` proxy timestamp (both are otherwise always set by
    # `upsert_manual`/`upsert_from_oauth`), inserted 48h ago. Bypasses the
    # changeset (these fields aren't normally nullable post-connect) with a
    # direct update to exercise `SourceFreshness`'s genuine `never_synced`
    # branch rather than the `connected_at`-as-proxy `stale` branch.
    import Ecto.Query

    Maraithon.Repo.update_all(
      from(a in Maraithon.Accounts.ConnectedAccount, where: a.id == ^account.id),
      set: [connected_at: nil, last_refreshed_at: nil, inserted_at: old_inserted_at]
    )

    start_supervised!(
      {FreshnessSweep,
       name: nil,
       observer: self(),
       interval_ms: :timer.hours(1),
       batch_size: 5_000,
       never_synced_after_hours: 24,
       initial_delay_ms: 10}
    )

    assert_receive {:freshness_sweep_cycle, %{flagged: flagged}}, 2_000
    assert flagged >= 1

    account = ConnectedAccounts.get(user_id, "google:founder@example.com")
    assert account.status == "error"
    assert get_in(account.metadata, ["last_error", "reason"]) == "source_stale"
  end

  test "R2: flags an expired push watch (already past watch_expires_at)" do
    user_id = "freshness-sweep-watch-#{System.unique_integer([:positive])}@example.com"
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

    {:ok, _token} =
      OAuth.store_tokens(user_id, "google", %{
        access_token: "valid_access_token",
        refresh_token: "valid_refresh_token",
        expires_in: 3600
      })

    account = ConnectedAccounts.get(user_id, "google")
    expired_at = DateTime.add(DateTime.utc_now(), -3_600, :second)

    SourceCursors.put(account, "gmail_history_id", %{
      "value" => "1000",
      "watch_expires_at" => expired_at
    })

    start_supervised!(
      {FreshnessSweep,
       name: nil,
       observer: self(),
       interval_ms: :timer.hours(1),
       batch_size: 5_000,
       initial_delay_ms: 10}
    )

    assert_receive {:freshness_sweep_cycle, %{flagged: flagged}}, 2_000
    assert flagged >= 1

    account = ConnectedAccounts.get(user_id, "google")
    assert get_in(account.metadata, ["last_error", "reason"]) == "watch_expired"
  end

  test "self-heals a soft-flagged Telegram account when the probe answers" do
    user_id = "freshness-sweep-heal-#{System.unique_integer([:positive])}@example.com"
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

    {:ok, _telegram} =
      ConnectedAccounts.upsert_manual(user_id, "telegram", %{external_account_id: "556677"})

    ConnectedAccounts.report_access_issue(user_id, "telegram", "source_stale")

    flagged = ConnectedAccounts.get_by_external_account_any_status("telegram", "556677")
    assert flagged.status == "error"

    Application.put_env(:maraithon, :freshness_sweep, telegram_module: CapturingTelegram)
    on_exit(fn -> Application.delete_env(:maraithon, :freshness_sweep) end)

    start_supervised!(
      {FreshnessSweep,
       name: nil,
       observer: self(),
       interval_ms: :timer.hours(1),
       batch_size: 5_000,
       initial_delay_ms: 10}
    )

    assert_receive {:freshness_sweep_cycle, %{healed: healed}}, 2_000
    assert healed >= 1

    healed_account = ConnectedAccounts.get(user_id, "telegram")
    assert healed_account.status == "connected"
    assert get_in(healed_account.metadata, ["last_error"]) == nil

    # The probe was the silent getChat, not a user-visible message.
    assert :capturing_telegram_recorder
           |> Agent.get(&Enum.reverse/1)
           |> Enum.any?(&(&1.type == :get_chat and &1.chat_id == "556677"))
  end

  test "does not heal a hard-failed Telegram account" do
    user_id = "freshness-sweep-hard-#{System.unique_integer([:positive])}@example.com"
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

    {:ok, _telegram} =
      ConnectedAccounts.upsert_manual(user_id, "telegram", %{external_account_id: "778899"})

    ConnectedAccounts.report_access_issue(user_id, "telegram", :reauth_required)

    Application.put_env(:maraithon, :freshness_sweep, telegram_module: CapturingTelegram)
    on_exit(fn -> Application.delete_env(:maraithon, :freshness_sweep) end)

    start_supervised!(
      {FreshnessSweep,
       name: nil,
       observer: self(),
       interval_ms: :timer.hours(1),
       batch_size: 5_000,
       initial_delay_ms: 10}
    )

    assert_receive {:freshness_sweep_cycle, %{}}, 2_000

    account = ConnectedAccounts.get_by_external_account_any_status("telegram", "778899")
    assert account.status == "error"
  end
end
