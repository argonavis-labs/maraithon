defmodule Maraithon.Runtime.SourceWatermarkCommitTest do
  use Maraithon.DataCase, async: false

  alias Maraithon.Accounts
  alias Maraithon.ConnectedAccounts
  alias Maraithon.Connectors.SourceCursors
  alias Maraithon.Repo
  alias Maraithon.Runtime.BackgroundJob
  alias Maraithon.Runtime.SourceWatermarkCommit

  test "commits and sanitizes a deferred cursor inside the caller transaction" do
    account = connected_account("atomic")

    job = %BackgroundJob{
      user_id: account.user_id,
      job_type: "runtime_partition:source_account_discovery"
    }

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

               Repo.rollback(:rollback_probe)
             end)

    refute SourceCursors.get(account.id, "gmail_discovery_watermark")
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

  defp connected_account(suffix) do
    user_id = "source-watermark-#{suffix}-#{System.unique_integer([:positive])}@example.com"
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

    {:ok, account} =
      ConnectedAccounts.upsert_manual(user_id, "google:#{user_id}", %{
        metadata: %{"account_email" => user_id, "services" => ["gmail"]}
      })

    account
  end
end
