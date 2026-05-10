defmodule Maraithon.SourceFreshnessTest do
  use Maraithon.DataCase, async: false

  alias Maraithon.Accounts
  alias Maraithon.ConnectedAccounts
  alias Maraithon.SourceFreshness
  alias Maraithon.TelegramAssistant.Context

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

    snapshots = SourceFreshness.for_user(user_id, now: now)

    google = Enum.find(snapshots, &(&1.provider == "google"))
    assert google.status == "stale"
    assert google.stale_reason =~ "72 hours old"

    telegram = Enum.find(snapshots, &(&1.provider == "telegram"))
    assert telegram.status == "reauth_required"
    assert telegram.last_error["reason"] =~ "invalid_grant"
  end

  test "injects compact freshness into Telegram assistant context" do
    user_id = "context-freshness-#{System.unique_integer([:positive])}@example.com"
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

    {:ok, _telegram} =
      ConnectedAccounts.upsert_manual(user_id, "telegram", %{external_account_id: "12345"})

    context = Context.build(%{user_id: user_id, chat_id: "12345"})

    assert [%{provider: "telegram", status: "fresh"}] = context.source_freshness
  end
end
