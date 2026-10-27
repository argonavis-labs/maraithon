defmodule Maraithon.Runtime.SourceFanoutAuditTest do
  use Maraithon.DataCase, async: false

  import Ecto.Query

  alias Maraithon.Accounts
  alias Maraithon.ConnectedAccounts
  alias Maraithon.OAuth
  alias Maraithon.Repo

  alias Maraithon.Runtime.{
    BackgroundJob,
    BackgroundJobs,
    SourceAccountDiscovery,
    SourceFanoutAudit
  }

  @discovery_acquire "runtime_partition:source_account_discovery"

  test "a later exact cycle restores health while retaining the older failure diagnostic" do
    now = ~U[2026-08-30 17:30:00Z]
    account = discovery_account("recovered")

    insert_acquisition(account, "failed", DateTime.add(now, -900, :second), %{})

    insert_acquisition(account, "completed", DateTime.add(now, -600, :second), %{
      "outcome" => "empty_delta",
      "source_items" => 0,
      "model_calls" => 0,
      "advanced_watermarks" => 1
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
    assert audit.discovery.current_failures == []

    assert [%{account_id: account_id, errors: ["acquisition_not_completed"]}] =
             audit.discovery.failures

    assert account_id == account.id
  end

  test "an active retry past the settlement grace is unhealthy" do
    now = ~U[2026-08-30 17:30:00Z]
    account = discovery_account("retrying")

    insert_acquisition(account, "completed", DateTime.add(now, -900, :second), %{
      "outcome" => "empty_delta",
      "source_items" => 0,
      "model_calls" => 0,
      "advanced_watermarks" => 1
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

    refute audit.healthy?
    assert audit.error_codes == %{"stalled_cycle" => 1}
    assert audit.in_flight_cycles == 1
    assert audit.stalled_cycles == 1
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
      "model_calls" => 0,
      "advanced_watermarks" => 1
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

  test "audits every coordinate in a bounded closure matrix" do
    account = discovery_account("closure-matrix")

    {:ok, [todo]} =
      Maraithon.Todos.upsert_many(account.user_id, [
        %{
          "source" => "gmail",
          "kind" => "gmail_triage",
          "title" => "Audit matrix coverage",
          "summary" => "Every source partition must see this todo batch.",
          "next_action" => "Verify the exact fan-out.",
          "source_account_id" => account.id,
          "source_item_id" => "audit-matrix-todo",
          "dedupe_key" => "source-fanout-audit:closure-matrix"
        }
      ])

    discovery =
      insert_acquisition(account, "completed", DateTime.utc_now(), %{
        "outcome" => "empty_delta",
        "source_items" => 0,
        "model_calls" => 0,
        "advanced_watermarks" => 1
      })

    {:ok, acquisition} =
      enqueue_source_job(account, "runtime_partition:source_account_closure_acquire", %{
        "account_id" => account.id
      })

    source_refs = ["gmail:matrix-one", "gmail:matrix-two"]
    source_digest = SourceAccountDiscovery.refs_digest(source_refs)
    todo_digest = SourceAccountDiscovery.refs_digest([todo.id])

    reasons =
      source_refs
      |> Enum.with_index(1)
      |> Enum.map(fn {source_ref, index} ->
        {:ok, reason} =
          enqueue_source_job(
            account,
            "runtime_partition:source_account_closure_reason",
            %{
              "account_id" => account.id,
              "acquisition_job_id" => acquisition.id,
              "fanout_index" => index,
              "fanout_count" => 2
            },
            %{
              "fanout_index" => index,
              "fanout_count" => 2,
              "source_partition_index" => index,
              "source_partition_count" => 2,
              "todo_batch_index" => 1,
              "todo_batch_count" => 1,
              "source_items" => 1,
              "source_item_refs" => [source_ref],
              "source_refs_digest" => SourceAccountDiscovery.refs_digest([source_ref]),
              "decision_count" => 1,
              "decision_refs" => [todo.id],
              "todo_decision_manifest" => [
                %{"todo_ref" => todo.id, "action" => "evaluated"}
              ],
              "model_calls" => 1
            }
          )

        reason
      end)

    reason_ids = Enum.map(reasons, & &1.id)

    {:ok, finalizer} =
      enqueue_source_job(
        account,
        "runtime_partition:source_account_closure_finalize",
        %{
          "account_id" => account.id,
          "acquisition_job_id" => acquisition.id,
          "reason_job_ids" => reason_ids,
          "expected_source_partitions" => 2,
          "expected_todo_batches" => 1,
          "expected_source_refs_digest" => source_digest,
          "expected_todo_refs_digest" => todo_digest
        },
        %{
          "outcome" => "finalized",
          "source_items" => 2,
          "decision_count" => 1,
          "fanout_count" => 2,
          "advanced_watermarks" => 1
        }
      )

    acquisition
    |> BackgroundJob.changeset(%{
      result: %{
        "outcome" => "fanout_ready",
        "source_items" => 2,
        "todo_count" => 1,
        "fanout_count" => 2,
        "reason_job_ids" => reason_ids,
        "finalizer_job_id" => finalizer.id
      }
    })
    |> Repo.update!()

    now = DateTime.add(DateTime.utc_now(), 1, :second)

    audit =
      SourceFanoutAudit.verify_since(DateTime.add(discovery.inserted_at, -1, :second),
        now: now,
        settlement_grace_seconds: 0
      )

    assert audit.healthy?
    assert audit.closure.exact_cycles == 1
    assert audit.closure.source_items == 2
    assert audit.closure.todo_count == 1
    assert audit.closure.decisions == 1
    assert audit.closure.fanout_workers == 2
    assert audit.activity.every_fanout_visible?
    assert audit.activity.visible_fanout_rows == 5
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

  defp enqueue_source_job(account, job_type, payload, result \\ %{}) do
    BackgroundJobs.enqueue(job_type, %{
      user_id: account.user_id,
      status: "completed",
      completed_at: DateTime.utc_now(),
      max_attempts: 5,
      scheduled_at: DateTime.utc_now(),
      dedupe_key: "source-fanout-audit:#{job_type}:#{System.unique_integer([:positive])}",
      payload: payload,
      result: result
    })
  end
end
