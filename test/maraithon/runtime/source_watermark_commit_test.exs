defmodule Maraithon.Runtime.SourceWatermarkCommitTest do
  use Maraithon.DataCase, async: false

  alias Maraithon.Accounts
  alias Maraithon.ConnectedAccounts
  alias Maraithon.Connectors.SourceCursors
  alias Maraithon.Repo
  alias Maraithon.Runtime.BackgroundJob
  alias Maraithon.Runtime.BackgroundJobs
  alias Maraithon.Runtime.GmailSourceReplay
  alias Maraithon.Runtime.SourceCycle
  alias Maraithon.Runtime.SourceWatermarkCommit

  test "commits and sanitizes a deferred cursor inside the caller transaction" do
    account = connected_account("atomic")

    job = source_job(account, "runtime_partition:source_account_discovery", "atomic")

    handler_result =
      {:ok,
       %{
         account_id: account.id,
         outcome: "empty_delta",
         advanced_watermarks: 0,
         deferred_watermarks: [
           %{
             "account_id" => account.id,
             "kind" => "gmail_discovery_watermark",
             "value" => "1700000600"
           }
         ]
       }}

    assert {:error, :rollback_probe} =
             Repo.transaction(fn ->
               assert {:ok, {:ok, sanitized}} =
                        SourceWatermarkCommit.commit_and_sanitize(job, handler_result)

               assert sanitized.advanced_watermarks == 1
               refute Map.has_key?(sanitized, :deferred_watermarks)

               assert %{value: "1700000600"} =
                        SourceCursors.get(account.id, "gmail_discovery_watermark")

               assert %SourceCycle{acquisition_job_id: acquisition_job_id} =
                        Repo.get_by(SourceCycle,
                          connected_account_id: account.id,
                          role: "discovery"
                        )

               assert acquisition_job_id == job.id

               Repo.rollback(:rollback_probe)
             end)

    refute SourceCursors.get(account.id, "gmail_discovery_watermark")
    refute Repo.get_by(SourceCycle, connected_account_id: account.id, role: "discovery")
  end

  test "rejects a deferred cursor on the wrong job role without writing it" do
    account = connected_account("wrong-role")

    job = %BackgroundJob{
      user_id: account.user_id,
      job_type: "runtime_partition:source_account_closure_acquire"
    }

    result =
      {:ok,
       %{
         account_id: account.id,
         deferred_watermarks: [
           %{
             "account_id" => account.id,
             "kind" => "gmail_discovery_watermark",
             "value" => "1700000700"
           }
         ]
       }}

    assert {:error, :invalid_deferred_source_watermark} =
             SourceWatermarkCommit.commit_and_sanitize(job, result)

    refute SourceCursors.get(account.id, "gmail_discovery_watermark")
  end

  test "binds replay settlement to its durable account window and reference" do
    account = connected_account("replay-contract")
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    lower = now |> DateTime.add(-24, :hour) |> DateTime.to_unix(:second)
    upper = now |> DateTime.add(-1, :second) |> DateTime.to_unix(:second)
    assert {:ok, replay} = GmailSourceReplay.build(account, lower, upper, now)

    {:ok, _cursor} =
      SourceCursors.put(account, replay.discovery_kind, %{value: Integer.to_string(lower)})

    {:ok, job} =
      BackgroundJobs.enqueue("runtime_partition:source_account_discovery", %{
        user_id: account.user_id,
        queue: "runtime_provider_account",
        dedupe_key: "source-watermark-replay-contract:#{account.id}",
        scheduled_at: now,
        payload:
          replay
          |> GmailSourceReplay.payload()
          |> Map.merge(%{"account_id" => account.id, "role" => "discovery"})
      })

    forged_result =
      {:ok,
       %{
         account_id: account.id,
         deferred_watermarks: [
           %{
             "account_id" => account.id,
             "kind" => replay.discovery_kind,
             "expected_lower_value" => Integer.to_string(lower),
             "value" => Integer.to_string(upper + 1)
           }
         ]
       }}

    assert {:error, :invalid_gmail_source_replay_settlement} =
             SourceWatermarkCommit.commit_and_sanitize(job, forged_result)

    live_cursor_result =
      put_in(
        forged_result,
        [Access.elem(1), :deferred_watermarks, Access.at(0)],
        %{
          "account_id" => account.id,
          "kind" => "gmail_discovery_watermark",
          "expected_lower_value" => Integer.to_string(lower),
          "value" => Integer.to_string(upper)
        }
      )

    assert {:error, :invalid_gmail_source_replay_settlement} =
             SourceWatermarkCommit.commit_and_sanitize(job, live_cursor_result)

    assert %{value: value} = SourceCursors.get(account.id, replay.discovery_kind)
    assert value == Integer.to_string(lower)
    refute SourceCursors.get(account.id, "gmail_discovery_watermark")
  end

  test "supersedes a stale legacy finalizer without sealing a backward cycle" do
    account = connected_account("stale-legacy")
    {:ok, _cursor} = SourceCursors.put(account, "gmail_discovery_watermark", %{value: "200"})
    job = source_job(account, "runtime_partition:source_account_discovery", "stale-legacy")

    handler_result =
      {:ok,
       %{
         account_id: account.id,
         outcome: "empty_delta",
         deferred_watermarks: [
           %{
             "account_id" => account.id,
             "kind" => "gmail_discovery_watermark",
             "value" => "100"
           }
         ]
       }}

    assert {:ok, sanitized} =
             Repo.transaction(fn ->
               assert {:ok, {:ok, result}} =
                        SourceWatermarkCommit.commit_and_sanitize(job, handler_result)

               result
             end)

    assert sanitized.outcome == "superseded"
    assert sanitized.advanced_watermarks == 0
    assert sanitized.superseded_watermarks == 1
    assert %{value: "200"} = SourceCursors.get(account.id, "gmail_discovery_watermark")
    refute Repo.get_by(SourceCycle, acquisition_job_id: job.id)
  end

  test "seals only when the acquisition lower cursor still matches" do
    account = connected_account("expected-lower")
    {:ok, _cursor} = SourceCursors.put(account, "gmail_discovery_watermark", %{value: "100"})
    job = source_job(account, "runtime_partition:source_account_discovery", "expected-lower")

    handler_result =
      {:ok,
       %{
         account_id: account.id,
         outcome: "empty_delta",
         deferred_watermarks: [
           %{
             "account_id" => account.id,
             "kind" => "gmail_discovery_watermark",
             "expected_lower_value" => "100",
             "value" => "200"
           }
         ]
       }}

    assert {:ok, sanitized} =
             Repo.transaction(fn ->
               assert {:ok, {:ok, result}} =
                        SourceWatermarkCommit.commit_and_sanitize(job, handler_result)

               result
             end)

    assert sanitized.advanced_watermarks == 1
    assert %{value: "200"} = SourceCursors.get(account.id, "gmail_discovery_watermark")

    assert %SourceCycle{lower_cursor: "100", upper_cursor: "200"} =
             Repo.get_by(SourceCycle, acquisition_job_id: job.id)
  end

  defp connected_account(suffix) do
    user_id = "source-watermark-#{suffix}-#{System.unique_integer([:positive])}@example.com"
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

    {:ok, account} =
      ConnectedAccounts.upsert_manual(user_id, "google:#{user_id}", %{
        metadata: %{"account_email" => user_id, "services" => ["gmail"]}
      })

    account
  end

  defp source_job(account, job_type, suffix) do
    {:ok, job} =
      BackgroundJobs.enqueue(job_type, %{
        user_id: account.user_id,
        queue: "runtime_provider_account",
        dedupe_key: "source-watermark-proof:#{suffix}:#{account.id}",
        scheduled_at: DateTime.utc_now(),
        payload: %{"account_id" => account.id}
      })

    job
  end
end
