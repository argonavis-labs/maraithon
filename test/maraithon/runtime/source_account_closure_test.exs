defmodule Maraithon.Runtime.SourceAccountClosureTest do
  use Maraithon.DataCase, async: false

  alias Maraithon.Accounts
  alias Maraithon.ChiefOfStaff.SourceBundle
  alias Maraithon.ConnectedAccounts
  alias Maraithon.Connectors.SourceCursors
  alias Maraithon.DurablePayload
  alias Maraithon.Runtime.BackgroundJob
  alias Maraithon.Runtime.SourceAccountClosure
  alias Maraithon.Runtime.SourceAccountDiscovery
  alias Maraithon.Todos

  test "empty closure delta advances without a model handoff" do
    account = closure_account("empty")
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    bundle = SourceBundle.empty(%{trigger: %{type: :wakeup}, timestamp: now})
    proposals = [closure_watermark(account, "1700000200")]

    assert {:ok,
            %{
              outcome: "empty_delta",
              source_items: 0,
              model_calls: 0,
              advanced_watermarks: 1
            }} =
             SourceAccountClosure.acquire(account,
               source_bundle: bundle,
               proposed_watermarks: proposals
             )

    assert %{value: "1700000200"} =
             SourceCursors.get(account.id, "gmail_closure_watermark")
  end

  test "non-empty closure delta stays sealed until account reasoning settles" do
    account = closure_account("sealed")
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    {:ok, [todo]} =
      Todos.upsert_many(account.user_id, [
        %{
          "source" => "gmail",
          "kind" => "gmail_triage",
          "title" => "Reply to the account thread",
          "summary" => "This stays open without exact completion evidence.",
          "next_action" => "Reply to the thread.",
          "priority" => 85,
          "source_account_id" => account.id,
          "source_item_id" => "closure-thread",
          "dedupe_key" => "source-account-closure:sealed"
        }
      ])

    message = %{
      "id" => "new-incoming-message",
      "thread_id" => "other-thread",
      "subject" => "Routine update",
      "snippet" => "An update with no completion evidence.",
      "body" => "An update with no completion evidence.",
      "from" => "sender@example.com",
      "to" => [account.user_id],
      "label_ids" => ["INBOX"],
      "internal_date" => DateTime.to_unix(now, :millisecond)
    }

    bundle =
      %{trigger: %{type: :wakeup}, timestamp: now}
      |> SourceBundle.empty()
      |> SourceBundle.put_gmail(%{
        "messages" => [message],
        "inbox_messages" => [message],
        "sent_messages" => [],
        "status" => "ready",
        "fetched_at" => now
      })

    assert {:ok,
            %{
              outcome: "fanout_ready",
              handoffs: [handoff],
              finalizer: finalizer,
              source_items: 1,
              fanout_count: 1
            }} =
             SourceAccountClosure.acquire(account,
               source_bundle: bundle,
               proposed_watermarks: [closure_watermark(account, "1700000300")],
               acquisition_job_id: "closure-acquisition"
             )

    refute SourceCursors.get(account.id, "gmail_closure_watermark")
    caller = self()

    assert {:error, :cross_source_completion_incomplete_decisions} =
             SourceAccountClosure.reason(account, handoff,
               now: now,
               llm_complete: fn _prompt ->
                 {:ok, %{content: Jason.encode!(%{"resolutions" => []})}}
               end
             )

    refute SourceCursors.get(account.id, "gmail_closure_watermark")

    llm_complete = fn _prompt ->
      send(caller, :model_called)

      {:ok,
       %{
         content:
           Jason.encode!(%{
             "resolutions" => [
               %{
                 "todo_id" => todo.id,
                 "completed" => false,
                 "reasoning" => "No exact completion evidence is present."
               }
             ]
           })
       }}
    end

    assert {:ok,
            child_result =
              %{
                outcome: "evaluated",
                account_id: account_id,
                decision_count: 1,
                fanout_index: 1,
                fanout_count: 1,
                result: %{coverage_complete?: true, model_calls: 1}
              }} =
             SourceAccountClosure.reason(account, handoff,
               now: now,
               llm_complete: llm_complete
             )

    assert account_id == account.id
    assert_received :model_called
    refute SourceCursors.get(account.id, "gmail_closure_watermark")

    assert {:error, :source_closure_incomplete_decisions} =
             SourceAccountClosure.finalize(account, finalizer, [
               Map.put(child_result, :decision_refs, ["gmail:wrong-item"])
             ])

    tampered_manifest =
      update_in(child_result.todo_decision_manifest, fn [entry] ->
        [%{entry | action: "superseded"}]
      end)

    assert {:error, :source_closure_incomplete_decisions} =
             SourceAccountClosure.finalize(
               account,
               finalizer,
               [%{child_result | todo_decision_manifest: tampered_manifest}]
             )

    refute SourceCursors.get(account.id, "gmail_closure_watermark")

    assert {:ok,
            %{
              outcome: "finalized",
              source_items: 1,
              decision_count: 1,
              fanout_count: 1,
              model_calls: 1
            }} = SourceAccountClosure.finalize(account, finalizer, [child_result])

    assert %{value: "1700000300"} =
             SourceCursors.get(account.id, "gmail_closure_watermark")
  end

  test "fans out by todo batch once while every worker receives the complete source delta" do
    account = closure_account("efficient")
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    todo_attrs =
      Enum.map(1..21, fn index ->
        %{
          "source" => "gmail",
          "kind" => "gmail_triage",
          "title" => "Open account work #{index}",
          "summary" => "This item stays open until later evidence proves it complete.",
          "next_action" => "Complete account work #{index}.",
          "source_account_id" => account.id,
          "source_item_id" => "todo-source-#{index}",
          "dedupe_key" => "source-account-closure:efficient:#{index}"
        }
      end)

    assert {:ok, todos} = Todos.upsert_many(account.user_id, todo_attrs)
    assert length(todos) == 21

    messages =
      Enum.map(1..12, fn index ->
        %{
          "id" => "later-message-#{index}",
          "thread_id" => "later-thread-#{index}",
          "subject" => "Later evidence #{index}",
          "body" => "Complete source evidence #{index}",
          "from" => "sender@example.com",
          "to" => [account.user_id],
          "label_ids" => ["INBOX"],
          "internal_date" => DateTime.to_unix(now, :millisecond)
        }
      end)

    bundle =
      %{trigger: %{type: :wakeup}, timestamp: now}
      |> SourceBundle.empty()
      |> SourceBundle.put_gmail(%{
        "messages" => messages,
        "inbox_messages" => messages,
        "sent_messages" => [],
        "status" => "ready",
        "fetched_at" => now
      })

    assert {:ok,
            %{
              source_items: 12,
              todo_count: 21,
              fanout_count: 3,
              handoffs: handoffs
            }} =
             SourceAccountClosure.acquire(account,
               source_bundle: bundle,
               proposed_watermarks: [closure_watermark(account, "1700000400")]
             )

    assert Enum.map(handoffs, & &1["todo_count"]) == [10, 10, 1]
    assert Enum.all?(handoffs, &(&1["source_items"] == 12))
    assert Enum.all?(handoffs, &(length(&1["source_item_refs"]) == 12))

    old_source_partition_work = ceil(12 / 5) * ceil(21 / 10)
    assert length(handoffs) == 3
    assert length(handoffs) < old_source_partition_work
  end

  test "large closure deltas become an exact bounded source by todo matrix" do
    account = closure_account("large-matrix")
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    {:ok, [todo]} =
      Todos.upsert_many(account.user_id, [
        %{
          "source" => "gmail",
          "kind" => "gmail_triage",
          "title" => "Close from a large exact delta",
          "summary" => "Every bounded source partition must be checked before settlement.",
          "next_action" => "Finish the large-delta follow-up.",
          "source_account_id" => account.id,
          "source_item_id" => "large-matrix-todo",
          "dedupe_key" => "source-account-closure:large-matrix"
        }
      ])

    messages =
      Enum.map(1..30, fn index ->
        body =
          Enum.map_join(1..900, fn chunk ->
            :crypto.hash(:sha512, "#{index}:#{chunk}") |> Base.encode64()
          end)

        %{
          "id" => "large-message-#{index}",
          "thread_id" => "large-thread-#{index}",
          "subject" => "Large evidence #{index}",
          "body" => body,
          "from" => "sender@example.com",
          "to" => [account.user_id],
          "label_ids" => ["INBOX"],
          "internal_date" => DateTime.to_unix(now, :millisecond)
        }
      end)

    bundle =
      %{trigger: %{type: :wakeup}, timestamp: now}
      |> SourceBundle.empty()
      |> SourceBundle.put_gmail(%{
        "messages" => messages,
        "inbox_messages" => messages,
        "sent_messages" => [],
        "status" => "ready",
        "fetched_at" => now
      })

    assert is_nil(SourceAccountDiscovery.compact_bundle(bundle))

    assert {:ok,
            %{
              source_items: 30,
              todo_count: 1,
              source_partition_count: source_partition_count,
              todo_batch_count: 1,
              fanout_count: fanout_count,
              handoffs: handoffs,
              finalizer: finalizer
            }} =
             SourceAccountClosure.acquire(account,
               source_bundle: bundle,
               proposed_watermarks: [closure_watermark(account, "1700000410")]
             )

    assert source_partition_count > 1
    assert fanout_count == source_partition_count
    assert length(handoffs) == fanout_count
    assert Enum.map(handoffs, & &1["fanout_index"]) == Enum.to_list(1..fanout_count)
    assert Enum.map(handoffs, & &1["source_partition_index"]) == Enum.to_list(1..fanout_count)
    assert Enum.sum(Enum.map(handoffs, & &1["source_items"])) == 30

    child_results =
      Enum.map(handoffs, fn handoff ->
        %{
          fanout_index: handoff["fanout_index"],
          fanout_count: handoff["fanout_count"],
          source_partition_index: handoff["source_partition_index"],
          source_partition_count: handoff["source_partition_count"],
          todo_batch_index: handoff["todo_batch_index"],
          todo_batch_count: handoff["todo_batch_count"],
          source_items: handoff["source_items"],
          source_item_refs: handoff["source_item_refs"],
          source_refs_digest: handoff["source_refs_digest"],
          decision_count: 1,
          decision_refs: [todo.id],
          todo_decision_count: 1,
          todo_decision_manifest: [%{todo_ref: todo.id, action: "evaluated"}],
          evaluated_todo_decision_refs: [todo.id],
          superseded_todo_decision_refs: [],
          model_calls: 1
        }
      end)

    assert {:ok,
            %{
              source_items: 30,
              decision_count: 1,
              fanout_count: ^fanout_count,
              model_calls: ^fanout_count
            }} = SourceAccountClosure.finalize(account, finalizer, child_results)

    assert %{value: "1700000410"} =
             SourceCursors.get(account.id, "gmail_closure_watermark")
  end

  test "account evidence evaluates open todos created by another source account" do
    evidence_account = closure_account("cross-source-evidence")

    {:ok, other_account} =
      ConnectedAccounts.upsert_manual(
        evidence_account.user_id,
        "slack:T-CROSS-SOURCE-#{System.unique_integer([:positive])}",
        %{metadata: %{"team_name" => "Other evidence source"}}
      )

    {:ok, [todo]} =
      Todos.upsert_many(evidence_account.user_id, [
        %{
          "source" => "slack",
          "kind" => "general",
          "title" => "Work surfaced by another account",
          "summary" => "Later Gmail evidence may settle this Slack-sourced work.",
          "next_action" => "Finish the cross-source follow-up.",
          "source_account_id" => other_account.id,
          "source_item_id" => "cross-source-thread",
          "dedupe_key" => "source-account-closure:cross-source-evidence"
        }
      ])

    now = DateTime.utc_now() |> DateTime.truncate(:second)

    message = %{
      "id" => "gmail-cross-source-evidence",
      "thread_id" => "gmail-cross-source-thread",
      "subject" => "Cross-source evidence",
      "body" => "Evidence that must be considered against every open todo.",
      "from" => "sender@example.com",
      "to" => [evidence_account.user_id],
      "label_ids" => ["INBOX"],
      "internal_date" => DateTime.to_unix(now, :millisecond)
    }

    bundle =
      %{trigger: %{type: :wakeup}, timestamp: now}
      |> SourceBundle.empty()
      |> SourceBundle.put_gmail(%{
        "messages" => [message],
        "inbox_messages" => [message],
        "sent_messages" => [],
        "status" => "ready",
        "fetched_at" => now
      })

    assert {:ok, %{todo_count: 1, handoffs: [handoff]}} =
             SourceAccountClosure.acquire(evidence_account,
               source_bundle: bundle,
               proposed_watermarks: [closure_watermark(evidence_account, "1700000425")]
             )

    assert handoff["todo_ids"] == [todo.id]
  end

  test "records a todo closed after acquisition as superseded instead of evaluated" do
    account = closure_account("superseded")
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    {:ok, [todo]} =
      Todos.upsert_many(account.user_id, [
        %{
          "source" => "gmail",
          "kind" => "gmail_triage",
          "title" => "Finish before the completion worker runs",
          "summary" => "The user may close this after the source delta is acquired.",
          "next_action" => "Finish the work.",
          "source_account_id" => account.id,
          "source_item_id" => "superseded-thread",
          "dedupe_key" => "source-account-closure:superseded"
        }
      ])

    message = %{
      "id" => "superseded-later-message",
      "thread_id" => "superseded-thread",
      "subject" => "Later evidence",
      "body" => "Later source evidence.",
      "from" => "sender@example.com",
      "to" => [account.user_id],
      "label_ids" => ["INBOX"],
      "internal_date" => DateTime.to_unix(now, :millisecond)
    }

    bundle =
      %{trigger: %{type: :wakeup}, timestamp: now}
      |> SourceBundle.empty()
      |> SourceBundle.put_gmail(%{
        "messages" => [message],
        "inbox_messages" => [message],
        "sent_messages" => [],
        "status" => "ready",
        "fetched_at" => now
      })

    assert {:ok, %{handoffs: [handoff], finalizer: finalizer}} =
             SourceAccountClosure.acquire(account,
               source_bundle: bundle,
               proposed_watermarks: [closure_watermark(account, "1700000450")]
             )

    assert {:ok, _todo} = Todos.mark_done(account.user_id, todo.id)

    assert {:ok,
            %{
              decision_refs: [decision_ref],
              evaluated_todo_decision_count: 0,
              evaluated_todo_decision_refs: [],
              superseded_todo_decision_count: 1,
              superseded_todo_decision_refs: [superseded_ref]
            } = child_result} = SourceAccountClosure.reason(account, handoff, now: now)

    assert decision_ref == todo.id
    assert superseded_ref == todo.id

    assert {:ok, %{decision_count: 1}} =
             SourceAccountClosure.finalize(account, finalizer, [child_result])
  end

  test "losslessly seals a completion delta larger than the durable job payload" do
    account = closure_account("aggregate-oversized")
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    {:ok, [_todo]} =
      Todos.upsert_many(account.user_id, [
        %{
          "source" => "gmail",
          "kind" => "gmail_triage",
          "title" => "Review oversized exact evidence",
          "summary" => "This remains open until the later evidence is evaluated.",
          "next_action" => "Review the complete thread.",
          "source_account_id" => account.id,
          "source_item_id" => "aggregate-oversized-thread",
          "dedupe_key" => "source-account-closure:aggregate-oversized"
        }
      ])

    aggregate_fields =
      Map.new(1..8, fn index ->
        {"provider_field_#{index}", String.duplicate("exact completion field #{index} ", 3_000)}
      end)

    body = String.duplicate("oversized exact completion evidence ", 6_000)

    message =
      aggregate_fields
      |> Map.merge(%{
        "id" => "aggregate-oversized-message",
        "thread_id" => "aggregate-oversized-thread",
        "subject" => "Oversized completion evidence",
        "body" => body,
        "from" => "sender@example.com",
        "to" => [account.user_id],
        "label_ids" => ["INBOX"],
        "internal_date" => DateTime.to_unix(now, :millisecond)
      })

    bundle =
      %{trigger: %{type: :wakeup}, timestamp: now}
      |> SourceBundle.empty()
      |> SourceBundle.put_gmail(%{
        "messages" => [message],
        "inbox_messages" => [message],
        "sent_messages" => [],
        "status" => "ready",
        "fetched_at" => now
      })

    compact = SourceAccountDiscovery.compact_bundle(bundle)
    assert byte_size(Jason.encode!(compact)) > BackgroundJob.max_payload_bytes()

    assert {:ok, %{handoffs: [handoff]}} =
             SourceAccountClosure.acquire(account,
               source_bundle: bundle,
               proposed_watermarks: [closure_watermark(account, "1700000500")],
               acquisition_job_id: "aggregate-oversized-closure"
             )

    assert %{"__maraithon_bounded_source_bundle_v1__" => _sealed} =
             handoff["source_bundle"]

    assert {:ok, _canonical} =
             DurablePayload.prepare_map(
               handoff,
               BackgroundJob.max_payload_bytes(),
               BackgroundJob.payload_bounds()
             )

    assert {:ok, restored} =
             SourceAccountDiscovery.restore_partition_bundle(handoff["source_bundle"])

    assert [restored_message] = SourceBundle.gmail_messages(restored)
    assert restored_message == message
  end

  defp closure_account(suffix) do
    user_id = "source-closure-#{suffix}-#{System.unique_integer([:positive])}@example.com"
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

    {:ok, account} =
      ConnectedAccounts.upsert_manual(user_id, "google:#{user_id}", %{
        metadata: %{"account_email" => user_id, "services" => ["gmail"]}
      })

    account
  end

  defp closure_watermark(account, value) do
    %{account: account, kind: "gmail_closure_watermark", value: value}
  end
end
