defmodule Maraithon.Runtime.SourceFanoutAuditTest do
  use Maraithon.DataCase, async: false

  import Ecto.Query

  alias Maraithon.Accounts
  alias Maraithon.ConnectedAccounts
  alias Maraithon.OAuth
  alias Maraithon.Repo
  alias Maraithon.Runtime.{BackgroundJob, BackgroundJobs, SourceFanoutAudit}

  @discovery_acquire "runtime_partition:source_account_discovery"

  test "a later exact cycle supersedes an older failed cycle" do
    now = ~U[2026-08-30 17:30:00Z]
    account = discovery_account("recovered")

    insert_acquisition(account, "failed", DateTime.add(now, -900, :second), %{})

    insert_acquisition(account, "completed", DateTime.add(now, -600, :second), %{
      "outcome" => "empty_delta",
      "source_items" => 0,
      "model_calls" => 0
    })

    audit =
      SourceFanoutAudit.verify_since(DateTime.add(now, -1, :hour),
        now: now,
        settlement_grace_seconds: 0
      )

    assert audit.healthy?
    assert audit.error_codes == %{}
    assert audit.discovery.cycles == 2
    assert audit.discovery.failed_cycles == 1
    assert audit.discovery.current_cycles == 1
    assert audit.discovery.current_exact_cycles == 1
    assert audit.discovery.missing_account_ids == []
    assert audit.discovery.failures == []
  end

  test "an active retry is visible without being reported as a terminal cycle failure" do
    now = ~U[2026-08-30 17:30:00Z]
    account = discovery_account("retrying")

    insert_acquisition(account, "completed", DateTime.add(now, -900, :second), %{
      "outcome" => "empty_delta",
      "source_items" => 0,
      "model_calls" => 0
    })

    insert_acquisition(
      account,
      "pending",
      DateTime.add(now, -600, :second),
      %{},
      scheduled_at: DateTime.add(now, 120, :second),
      attempts: 3
    )

    audit =
      SourceFanoutAudit.verify_since(DateTime.add(now, -1, :hour),
        now: now,
        settlement_grace_seconds: 0
      )

    assert audit.healthy?
    assert audit.error_codes == %{}
    assert audit.in_flight_cycles == 1
    assert audit.activity.active_retry_rows == 1
    assert audit.activity.every_fanout_visible?
    assert audit.discovery.cycles == 1
    assert audit.discovery.current_exact_cycles == 1
  end

  test "a newer exhausted cycle remains a current failure" do
    now = ~U[2026-08-30 17:30:00Z]
    account = discovery_account("exhausted")

    insert_acquisition(account, "completed", DateTime.add(now, -900, :second), %{
      "outcome" => "empty_delta",
      "source_items" => 0,
      "model_calls" => 0
    })

    insert_acquisition(account, "failed", DateTime.add(now, -600, :second), %{}, attempts: 5)

    audit =
      SourceFanoutAudit.verify_since(DateTime.add(now, -1, :hour),
        now: now,
        settlement_grace_seconds: 0
      )

    refute audit.healthy?
    assert audit.error_codes == %{"acquisition_not_completed" => 1}
    assert audit.discovery.current_cycles == 1
    assert audit.discovery.current_exact_cycles == 0
    assert audit.discovery.missing_account_ids == [account.id]

    assert [%{account_id: account_id, errors: ["acquisition_not_completed"]}] =
             audit.discovery.failures

    assert account_id == account.id
  end

  defp discovery_account(suffix) do
    user_id =
      "source-fanout-audit-#{suffix}-#{System.unique_integer([:positive])}@example.com"

    provider = "google:#{user_id}"
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

    {:ok, account} =
      ConnectedAccounts.upsert_manual(user_id, provider, %{
        status: "connected",
        metadata: %{"account_email" => user_id, "services" => ["gmail"]}
      })

    {:ok, _token} =
      OAuth.store_tokens(user_id, provider, %{
        access_token: "source-fanout-audit-access",
        refresh_token: "source-fanout-audit-refresh",
        scopes: ["gmail.readonly"]
      })

    account
  end

  defp insert_acquisition(account, status, inserted_at, result, opts \\ []) do
    scheduled_at = Keyword.get(opts, :scheduled_at, inserted_at)

    {:ok, job} =
      BackgroundJobs.enqueue(@discovery_acquire, %{
        user_id: account.user_id,
        status: status,
        attempts: Keyword.get(opts, :attempts, 0),
        max_attempts: 5,
        scheduled_at: scheduled_at,
        dedupe_key: "source-fanout-audit:#{account.id}:#{System.unique_integer([:positive])}",
        payload: %{"account_id" => account.id},
        result: result
      })

    BackgroundJob
    |> where([candidate], candidate.id == ^job.id)
    |> Repo.update_all(set: [inserted_at: inserted_at, updated_at: inserted_at])

    job
  end
end
