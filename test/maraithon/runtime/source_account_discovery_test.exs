defmodule Maraithon.Runtime.SourceAccountDiscoveryTest do
  use Maraithon.DataCase, async: false

  alias Maraithon.Accounts
  alias Maraithon.Agents
  alias Maraithon.ChiefOfStaff.SourceBundle
  alias Maraithon.ConnectedAccounts
  alias Maraithon.Connectors.SourceCursors
  alias Maraithon.OAuth
  alias Maraithon.Runtime.SourceAccountDiscovery

  test "empty account delta advances without a model handoff" do
    {account, agent} = discovery_identity("empty")
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    bundle = SourceBundle.empty(%{trigger: %{type: :wakeup}, timestamp: now})

    acquisition = fn user_id, ["followthrough"], _configs, context ->
      assert user_id == account.user_id
      assert context.source_watermark_role == "discovery"
      assert context.defer_watermark_advance

      {bundle, complete_telemetry(),
       [
         %{
           account: account,
           kind: "gmail_discovery_watermark",
           value: "1700000000"
         }
       ]}
    end

    assert {:ok,
            %{
              outcome: "empty_delta",
              source_items: 0,
              model_calls: 0,
              advanced_watermarks: 1
            }} =
             SourceAccountDiscovery.acquire(account, agent,
               acquisition: acquisition,
               now: now
             )

    assert %{value: "1700000000"} =
             SourceCursors.get(account.id, "gmail_discovery_watermark")
  end

  test "non-empty delta stays sealed until reasoning settles then advances quietly" do
    {account, agent} = discovery_identity("sealed")
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    bundle =
      %{trigger: %{type: :wakeup}, timestamp: now}
      |> SourceBundle.empty()
      |> SourceBundle.put_gmail(%{
        "messages" => [routine_message(now)],
        "inbox_messages" => [routine_message(now)],
        "sent_messages" => [],
        "status" => "ready",
        "fetched_at" => now
      })

    acquisition = fn _user_id, _skills, _configs, _context ->
      {bundle, complete_telemetry(),
       [
         %{
           account: account,
           kind: "gmail_discovery_watermark",
           value: "1700000100"
         }
       ]}
    end

    assert {:ok,
            %{
              outcome: "fanout_ready",
              handoffs: [handoff],
              finalizer: finalizer,
              source_items: 1,
              fanout_count: 1
            }} =
             SourceAccountDiscovery.acquire(account, agent,
               acquisition: acquisition,
               acquisition_job_id: "acquisition-job",
               now: now
             )

    refute SourceCursors.get(account.id, "gmail_discovery_watermark")
    caller = self()

    assert {:ok, %{model_calls: 1, decision_count: 1, advanced_watermarks: 0} = child_result} =
             SourceAccountDiscovery.reason(account, agent, handoff,
               now: now,
               llm_complete: fn prompt ->
                 assert prompt =~ Maraithon.Todos.Intelligence.sentinel()
                 send(caller, :model_called)
                 skip_decisions(1)
               end
             )

    assert_received :model_called
    refute SourceCursors.get(account.id, "gmail_discovery_watermark")

    assert {:ok, %{decision_count: 1, advanced_watermarks: 1}} =
             SourceAccountDiscovery.finalize(account, agent, finalizer, [child_result])

    assert %{value: "1700000100"} =
             SourceCursors.get(account.id, "gmail_discovery_watermark")
  end

  test "account worker uses default follow-through intelligence without a Chief row" do
    user_id =
      "source-account-discovery-default-#{System.unique_integer([:positive])}@example.com"

    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

    {:ok, account} =
      ConnectedAccounts.upsert_manual(user_id, "google:#{user_id}", %{
        metadata: %{"account_email" => user_id, "services" => ["gmail"]}
      })

    {:ok, _token} =
      OAuth.store_tokens(user_id, "google:#{user_id}", %{
        access_token: "default-discovery-access",
        refresh_token: "default-discovery-refresh",
        metadata: %{"account_email" => user_id, "services" => ["gmail"]}
      })

    now = DateTime.utc_now() |> DateTime.truncate(:second)

    bundle =
      %{trigger: %{type: :wakeup}, timestamp: now}
      |> SourceBundle.empty()
      |> SourceBundle.put_gmail(%{
        "messages" => [routine_message(now)],
        "inbox_messages" => [routine_message(now)],
        "sent_messages" => [],
        "status" => "ready",
        "fetched_at" => now
      })

    acquisition = fn ^user_id, ["followthrough"], configs, context ->
      assert [%{"provider" => "google:" <> _rest}] =
               configs["followthrough"]["source_scope"]["google_accounts"]

      assert context.agent_id == nil

      {bundle, complete_telemetry(),
       [%{account: account, kind: "gmail_discovery_watermark", value: "1700000200"}]}
    end

    assert {:ok, %{outcome: "fanout_ready", handoffs: [handoff], finalizer: finalizer}} =
             SourceAccountDiscovery.acquire(account, nil,
               acquisition: acquisition,
               now: now
             )

    refute Map.has_key?(handoff, "agent_id")

    assert {:ok, %{model_calls: 1, advanced_watermarks: 0} = child_result} =
             SourceAccountDiscovery.reason(account, nil, handoff,
               now: now,
               llm_complete: fn _prompt -> skip_decisions(1) end
             )

    assert {:ok, %{advanced_watermarks: 1}} =
             SourceAccountDiscovery.finalize(account, nil, finalizer, [child_result])

    assert %{value: "1700000200"} =
             SourceCursors.get(account.id, "gmail_discovery_watermark")
  end

  test "partitions every unique source item into small reasoning fan-outs" do
    {account, agent} = discovery_identity("partitioned")
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    messages =
      Enum.map(1..12, fn index ->
        now
        |> routine_message()
        |> Map.put("id", "message-#{index}")
        |> Map.put("thread_id", "thread-#{index}")
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

    acquisition = fn _user_id, _skills, _configs, _context ->
      {bundle, complete_telemetry(),
       [%{account: account, kind: "gmail_discovery_watermark", value: "1700000300"}]}
    end

    assert {:ok,
            %{
              source_items: 12,
              fanout_count: 3,
              handoffs: handoffs,
              finalizer: finalizer
            }} =
             SourceAccountDiscovery.acquire(account, agent,
               acquisition: acquisition,
               acquisition_job_id: "partitioned-acquisition",
               now: now
             )

    assert Enum.map(handoffs, &length(&1["source_item_refs"])) == [5, 5, 2]

    assert handoffs
           |> Enum.flat_map(& &1["source_item_refs"])
           |> Enum.uniq()
           |> length() == 12

    assert {:error, :todo_intelligence_incomplete_decisions} =
             SourceAccountDiscovery.reason(account, agent, hd(handoffs),
               now: now,
               llm_complete: fn _prompt -> skip_decisions(1) end
             )

    child_results =
      Enum.map(handoffs, fn handoff ->
        assert {:ok, child_result} =
                 SourceAccountDiscovery.reason(account, agent, handoff,
                   now: now,
                   llm_complete: fn _prompt ->
                     skip_decisions(length(handoff["source_item_refs"]))
                   end
                 )

        child_result
      end)

    refute SourceCursors.get(account.id, "gmail_discovery_watermark")

    [first_result | remaining_results] = child_results

    tampered_results =
      [Map.put(first_result, :decision_refs, ["gmail:wrong-item"])] ++ remaining_results

    assert {:error, :source_discovery_incomplete_decisions} =
             SourceAccountDiscovery.finalize(account, agent, finalizer, tampered_results)

    refute SourceCursors.get(account.id, "gmail_discovery_watermark")

    assert {:ok, %{source_items: 12, decision_count: 12, fanout_count: 3}} =
             SourceAccountDiscovery.finalize(account, agent, finalizer, child_results)

    assert %{value: "1700000300"} =
             SourceCursors.get(account.id, "gmail_discovery_watermark")
  end

  test "keeps every message in one Gmail thread in the same fan-out" do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    messages =
      Enum.map(1..4, fn index ->
        now
        |> routine_message()
        |> Map.put("id", "message-#{index}")
        |> Map.put("thread_id", "thread-#{index}")
      end) ++
        [
          now
          |> routine_message()
          |> Map.put("id", "shared-root")
          |> Map.put("thread_id", "shared-thread"),
          now
          |> routine_message()
          |> Map.put("id", "shared-reply")
          |> Map.put("thread_id", "shared-thread")
        ]

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

    assert {:ok, [first, second]} = SourceAccountDiscovery.partition_bundle(bundle)
    assert SourceAccountDiscovery.source_item_count(first) == 4

    assert second
           |> SourceBundle.gmail_messages()
           |> Enum.map(& &1["id"])
           |> Enum.sort() == ["shared-reply", "shared-root"]
  end

  test "rejects unidentified source rows and preserves long message content losslessly" do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    body = String.duplicate("exact-content-", 600)

    valid_bundle =
      %{trigger: %{type: :wakeup}, timestamp: now}
      |> SourceBundle.empty()
      |> SourceBundle.put_gmail(%{
        "messages" => [Map.put(routine_message(now), "body", body)],
        "inbox_messages" => [],
        "sent_messages" => [],
        "status" => "ready",
        "fetched_at" => now
      })

    assert {:ok, [partition]} = SourceAccountDiscovery.partition_bundle(valid_bundle)
    assert [message] = SourceBundle.gmail_messages(partition)
    assert message["body"] == body

    invalid_bundle =
      %{trigger: %{type: :wakeup}, timestamp: now}
      |> SourceBundle.empty()
      |> SourceBundle.put_gmail(%{
        "messages" => [%{"subject" => "Missing provider identity"}],
        "inbox_messages" => [],
        "sent_messages" => [],
        "status" => "ready",
        "fetched_at" => now
      })

    assert {:error, :source_discovery_item_identity_missing} =
             SourceAccountDiscovery.partition_bundle(invalid_bundle)
  end

  defp discovery_identity(suffix) do
    user_id =
      "source-account-discovery-#{suffix}-#{System.unique_integer([:positive])}@example.com"

    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

    {:ok, account} =
      ConnectedAccounts.upsert_manual(user_id, "google:#{user_id}", %{
        metadata: %{"account_email" => user_id, "services" => ["gmail"]}
      })

    {:ok, agent} =
      Agents.create_agent(%{
        user_id: user_id,
        behavior: "ai_chief_of_staff",
        config: %{},
        status: "running"
      })

    {account, agent}
  end

  defp complete_telemetry do
    %{
      "sources" => %{
        "gmail" => %{
          "status" => "ready",
          "failed_providers" => [],
          "partial_providers" => []
        }
      }
    }
  end

  defp routine_message(now) do
    %{
      "id" => "routine-message",
      "thread_id" => "routine-thread",
      "subject" => "Newsletter",
      "snippet" => "A routine informational update with no request.",
      "body" => "A routine informational update with no request.",
      "from" => "newsletter@example.com",
      "to" => ["owner@example.com"],
      "label_ids" => ["INBOX"],
      "internal_date" => DateTime.to_unix(now, :millisecond)
    }
  end

  defp skip_decisions(count) do
    decisions =
      Enum.map(0..(count - 1), fn index ->
        %{
          "candidate_index" => index,
          "action" => "skip",
          "reasoning" => "The source contains no durable operator-owned work."
        }
      end)

    {:ok,
     %{
       content: Jason.encode!(%{"summary" => "No durable work", "decisions" => decisions})
     }}
  end
end
