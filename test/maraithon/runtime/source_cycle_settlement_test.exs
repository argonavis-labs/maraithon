defmodule Maraithon.Runtime.SourceCycleSettlementTest do
  use Maraithon.DataCase, async: false

  alias Maraithon.Accounts
  alias Maraithon.ChiefOfStaff.SourceBundle
  alias Maraithon.ConnectedAccounts
  alias Maraithon.Repo
  alias Maraithon.Runtime.BackgroundJobs
  alias Maraithon.Runtime.SourceAccountDiscovery
  alias Maraithon.Runtime.SourceCycle
  alias Maraithon.Runtime.SourceCycleProofs
  alias Maraithon.Runtime.SourceCycleSettlement
  alias Maraithon.Runtime.TodoClosureReceipt
  alias Maraithon.Todos.Todo

  test "seals every discovery fan-out decision against its Activity jobs" do
    account = connected_account("discovery")
    bundle = gmail_bundle(account, "message-discovery")
    [source_ref] = Maraithon.Runtime.SourceAccountDiscovery.source_item_refs(bundle)

    acquisition =
      enqueue(account, "runtime_partition:source_account_discovery", "discovery-acquire", %{})

    reason =
      enqueue(
        account,
        "runtime_partition:source_account_discovery_reason",
        "discovery-reason",
        %{
          "acquisition_job_id" => acquisition.id,
          "source_bundle" => bundle,
          "source_item_refs" => [source_ref]
        },
        %{
          "decision_manifest" => [
            %{"source_ref" => source_ref, "action" => "skip", "persisted_todo_id" => nil}
          ]
        },
        "completed"
      )

    finalizer =
      enqueue(
        account,
        "runtime_partition:source_account_discovery_finalize",
        "discovery-finalize",
        %{
          "acquisition_job_id" => acquisition.id,
          "reason_job_ids" => [reason.id]
        }
      )

    assert {:ok, %{source_items: 1, source_decisions: 1, expected_jobs: 3}} =
             Repo.transaction(fn ->
               SourceCycleSettlement.seal(
                 finalizer,
                 %{},
                 account,
                 [watermark(account, "gmail_discovery_watermark", "1700000100")]
               )
             end)
             |> elem(1)

    cycle = Repo.get_by!(SourceCycle, acquisition_job_id: acquisition.id)

    assert {:ok, %{source_items: 1, source_decisions: 1}} =
             SourceCycleProofs.verify_complete(cycle)

    now = DateTime.utc_now()

    audit =
      SourceCycleProofs.verify_window(
        DateTime.add(now, -60, :second),
        DateTime.add(now, 60, :second)
      )

    assert audit.healthy?
    assert audit.cycle_coverage_percent == 100.0
    assert audit.activity_coverage_percent == 100.0
    assert audit.visible_activity_rows == 3

    assert bundle
           |> SourceAccountDiscovery.filter_settled_source_items(account, "discovery")
           |> SourceAccountDiscovery.source_item_count() == 0

    revised_bundle =
      put_in(
        bundle,
        ["gmail", "messages", Access.at(0), "body"],
        "Please finish the revised work."
      )

    assert revised_bundle
           |> SourceAccountDiscovery.filter_settled_source_items(account, "discovery")
           |> SourceAccountDiscovery.source_item_count() == 1
  end

  test "seals completion evidence against the exact pre-evaluation todo snapshot" do
    account = connected_account("closure")
    bundle = gmail_bundle(account, "message-closure")
    todo = todo(account, "closure todo")
    snapshot_updated_at = todo.updated_at

    acquisition =
      enqueue(account, "runtime_partition:source_account_closure_acquire", "closure-acquire", %{})

    reason =
      enqueue(
        account,
        "runtime_partition:source_account_closure_reason",
        "closure-reason",
        %{
          "acquisition_job_id" => acquisition.id,
          "source_bundle" => bundle,
          "todo_snapshots" => [
            %{
              "id" => todo.id,
              "status" => "open",
              "updated_at" => DateTime.to_iso8601(snapshot_updated_at)
            }
          ]
        },
        %{
          "todo_decision_manifest" => [
            %{"todo_ref" => todo.id, "action" => "evaluated"}
          ]
        },
        "completed"
      )

    {:ok, _done} = todo |> Todo.changeset(%{status: "done"}) |> Repo.update()

    finalizer =
      enqueue(
        account,
        "runtime_partition:source_account_closure_finalize",
        "closure-finalize",
        %{
          "acquisition_job_id" => acquisition.id,
          "reason_job_ids" => [reason.id]
        }
      )

    assert {:ok, %{source_items: 1, todo_snapshots: 1, todo_closures: 1, expected_jobs: 3}} =
             Repo.transaction(fn ->
               SourceCycleSettlement.seal(
                 finalizer,
                 %{},
                 account,
                 [watermark(account, "gmail_closure_watermark", "1700000200")]
               )
             end)
             |> elem(1)

    cycle = Repo.get_by!(SourceCycle, acquisition_job_id: acquisition.id)
    receipt = Repo.get_by!(TodoClosureReceipt, cycle_id: cycle.id, todo_id: todo.id)
    assert receipt.outcome == "completed"
    assert byte_size(receipt.evidence_digest) == 32
  end

  defp connected_account(suffix) do
    user_id = "source-settlement-#{suffix}-#{System.unique_integer([:positive])}@example.com"
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

    {:ok, account} =
      ConnectedAccounts.upsert_manual(user_id, "google:#{user_id}", %{
        metadata: %{"account_email" => user_id, "services" => ["gmail"]}
      })

    account
  end

  defp gmail_bundle(account, message_id) do
    SourceBundle.empty(%{timestamp: ~U[2026-08-30 12:00:00Z]})
    |> SourceBundle.put_gmail(%{
      "messages" => [
        %{
          "google_provider" => account.provider,
          "message_id" => message_id,
          "thread_id" => "thread-#{message_id}",
          "internal_date" => "2026-08-30T12:00:00Z",
          "subject" => "A real commitment",
          "body" => "Please finish the work."
        }
      ]
    })
  end

  defp todo(account, title) do
    attrs = %{
      user_id: account.user_id,
      owner_user_id: account.user_id,
      source: "gmail",
      source_account_id: account.id,
      kind: "general",
      title: title,
      summary: "A sourced commitment to complete",
      next_action: "Complete the requested work",
      dedupe_key: "source-settlement:#{account.id}:#{title}"
    }

    %Todo{} |> Todo.changeset(attrs) |> Repo.insert!()
  end

  defp enqueue(account, type, suffix, payload, result \\ %{}, status \\ "pending") do
    {:ok, job} =
      BackgroundJobs.enqueue(type, %{
        user_id: account.user_id,
        queue: "runtime_model_user",
        dedupe_key: "source-settlement:#{account.id}:#{suffix}",
        scheduled_at: DateTime.utc_now(),
        payload: payload,
        result: result,
        status: status
      })

    job
  end

  defp watermark(account, kind, value) do
    %{"account_id" => account.id, "kind" => kind, "value" => value}
  end
end
