defmodule Maraithon.Runtime.SourceAccountDiscoveryTest do
  use Maraithon.DataCase, async: false

  alias Maraithon.Accounts
  alias Maraithon.Agents
  alias Maraithon.ChiefOfStaff.SourceBundle
  alias Maraithon.ConnectedAccounts
  alias Maraithon.Connectors.SourceCursors
  alias Maraithon.DurablePayload
  alias Maraithon.OAuth
  alias Maraithon.Runtime.BackgroundJob
  alias Maraithon.Runtime.SourceAccountDiscovery

  test "proof items hash canonical identities and normalize Gmail milliseconds" do
    internal_date = 1_777_593_600_000

    bundle =
      SourceBundle.empty(%{timestamp: ~U[2026-05-01 00:00:00Z]})
      |> SourceBundle.put_gmail(%{
        "messages" => [
          %{
            "google_provider" => "google:proof@example.com",
            "message_id" => "message-1",
            "thread_id" => "thread-1",
            "internal_date" => Integer.to_string(internal_date)
          }
        ]
      })

    assert [proof] = SourceAccountDiscovery.source_proof_items(bundle)

    identity = "google:proof@example.com:message-1"
    source_ref = "gmail:" <> identity

    assert proof.source_identity_digest == :crypto.hash(:sha256, identity)
    assert proof.source_ref_digest == :crypto.hash(:sha256, source_ref)
    refute proof.source_identity_digest == proof.source_ref_digest
    assert DateTime.to_unix(proof.provider_occurred_at, :millisecond) == internal_date
  end

  test "rejects malformed replay options before acquisition" do
    {account, agent} = discovery_identity("invalid-replay")

    assert {:error, :invalid_gmail_source_replay_payload} =
             SourceAccountDiscovery.acquire(account, agent,
               source_replay: %{lower: 1, upper: 2, reference: "tampered", kind: "tampered"},
               acquisition: fn _user_id, _skills, _configs, _context ->
                 flunk("malformed replay must fail before acquisition")
               end
             )
  end

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

    tampered_manifest =
      update_in(first_result.decision_manifest, fn [entry | rest] ->
        [Map.put(entry, :action, "create") | rest]
      end)

    assert {:error, :source_discovery_incomplete_decisions} =
             SourceAccountDiscovery.finalize(
               account,
               agent,
               finalizer,
               [%{first_result | decision_manifest: tampered_manifest} | remaining_results]
             )

    refute SourceCursors.get(account.id, "gmail_discovery_watermark")

    assert {:ok, %{source_items: 12, decision_count: 12, fanout_count: 3}} =
             SourceAccountDiscovery.finalize(account, agent, finalizer, child_results)

    assert %{value: "1700000300"} =
             SourceCursors.get(account.id, "gmail_discovery_watermark")
  end

  test "re-splits a structurally oversized handoff and finalizes the post-split graph" do
    {account, agent} = discovery_identity("durable-resplit")
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    first_large_field = String.duplicate("a", 2_600_000)
    second_large_field = String.duplicate("b", 2_600_000)

    messages =
      Enum.map(1..2, fn index ->
        now
        |> routine_message()
        |> Map.put("id", "resplit-message-#{index}")
        |> Map.put("thread_id", "resplit-thread-#{index}")
        |> Map.put("body", first_large_field)
        |> Map.put("raw_source", second_large_field)
      end)

    bundle =
      %{trigger: %{type: :wakeup}, timestamp: now}
      |> SourceBundle.empty()
      |> SourceBundle.put_gmail(%{
        "messages" => messages,
        "inbox_messages" => [],
        "sent_messages" => [],
        "status" => "ready",
        "fetched_at" => now
      })

    acquisition = fn _user_id, _skills, _configs, _context ->
      {bundle, complete_telemetry(),
       [%{account: account, kind: "gmail_discovery_watermark", value: "1700000350"}]}
    end

    assert {:ok,
            %{
              source_items: 2,
              fanout_count: 2,
              handoffs: handoffs,
              finalizer: finalizer
            }} =
             SourceAccountDiscovery.acquire(account, agent,
               acquisition: acquisition,
               acquisition_job_id: "durable-resplit-acquisition",
               now: now
             )

    assert Enum.map(handoffs, & &1["fanout_count"]) == [2, 2]
    assert Enum.map(handoffs, &length(&1["source_item_refs"])) == [1, 1]
    assert finalizer["expected_fanouts"] == 2

    child_results =
      Enum.map(handoffs, fn handoff ->
        decision_manifest =
          Enum.map(handoff["source_item_refs"], fn source_ref ->
            %{source_ref: source_ref, action: "skip", persisted_todo_id: nil}
          end)

        %{
          fanout_index: handoff["fanout_index"],
          decision_count: 1,
          source_items: 1,
          decision_refs: handoff["source_item_refs"],
          decision_manifest: decision_manifest,
          model_calls: 1
        }
      end)

    assert {:ok, %{fanout_count: 2, source_items: 2, decision_count: 2}} =
             SourceAccountDiscovery.finalize(account, agent, finalizer, child_results)

    assert %{value: "1700000350"} =
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
          |> Map.put("thread_context", [
            now
            |> routine_message()
            |> Map.put("id", "historical-root")
            |> Map.put("thread_id", "shared-thread")
          ])
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

    refute "gmail:unknown:historical-root" in Enum.flat_map(
             [first, second],
             &SourceAccountDiscovery.source_item_refs/1
           )
  end

  test "deterministically splits a Gmail thread larger than the fan-out item limit" do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    messages =
      Enum.map(1..12, fn index ->
        now
        |> routine_message()
        |> Map.put("id", "shared-message-#{index}")
        |> Map.put("thread_id", "shared-thread")
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

    assert {:ok, partitions} = SourceAccountDiscovery.partition_bundle(bundle)
    assert Enum.map(partitions, &SourceAccountDiscovery.source_item_count/1) == [5, 5, 2]

    assert partitions
           |> Enum.flat_map(&SourceAccountDiscovery.source_item_refs/1)
           |> Enum.uniq()
           |> length() == 12
  end

  test "losslessly seals and restores a single source record larger than the handoff limit" do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    body =
      String.duplicate("oversized exact source evidence ", 24_000) <>
        " TAIL ACTION: send the signed quarterly plan to Alex."

    message =
      now
      |> routine_message()
      |> Map.put("id", "oversized-message")
      |> Map.put("thread_id", "oversized-thread")
      |> Map.put("body", body)

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

    assert byte_size(Jason.encode!(bundle)) > 500_000
    assert {:ok, [partition]} = SourceAccountDiscovery.partition_bundle(bundle)
    assert byte_size(Jason.encode!(partition)) <= 500_000
    assert SourceAccountDiscovery.source_item_count(partition) == 1

    assert SourceAccountDiscovery.source_item_refs(partition) == [
             "gmail:unknown:oversized-message"
           ]

    assert {:ok, restored} = SourceAccountDiscovery.restore_partition_bundle(partition)
    assert [restored_message] = SourceBundle.gmail_messages(restored)
    assert restored_message["body"] == body

    assert SourceAccountDiscovery.source_item_refs(restored) == [
             "gmail:unknown:oversized-message"
           ]
  end

  test "losslessly seals aggregate Gmail evidence larger than the durable payload" do
    {account, agent} = discovery_identity("aggregate-oversized")
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    aggregate_fields =
      Map.new(1..8, fn index ->
        {"provider_field_#{index}", String.duplicate("exact field #{index} ", 5_000)}
      end)

    message =
      now
      |> routine_message()
      |> Map.put("id", "aggregate-oversized-message")
      |> Map.put("thread_id", "aggregate-oversized-thread")
      |> Map.merge(aggregate_fields)

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

    acquisition = fn _user_id, _skills, _configs, _context ->
      {bundle, complete_telemetry(),
       [%{account: account, kind: "gmail_discovery_watermark", value: "1700000360"}]}
    end

    assert {:ok, [partition]} = SourceAccountDiscovery.partition_bundle(bundle)
    assert byte_size(Jason.encode!(partition)) > BackgroundJob.max_payload_bytes()

    assert {:ok, %{handoffs: [handoff], finalizer: finalizer}} =
             SourceAccountDiscovery.acquire(account, agent,
               acquisition: acquisition,
               acquisition_job_id: "aggregate-oversized-acquisition",
               now: now
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

    assert SourceAccountDiscovery.source_item_refs(restored) == [
             "gmail:unknown:aggregate-oversized-message"
           ]

    assert {:ok, %{decision_count: 1} = child_result} =
             SourceAccountDiscovery.reason(account, agent, handoff,
               now: now,
               llm_complete: fn _prompt -> skip_decisions(1) end
             )

    refute SourceCursors.get(account.id, "gmail_discovery_watermark")

    assert {:ok, %{advanced_watermarks: 1}} =
             SourceAccountDiscovery.finalize(account, agent, finalizer, [child_result])

    assert %{value: "1700000360"} =
             SourceCursors.get(account.id, "gmail_discovery_watermark")
  end

  test "fails closed without advancing Gmail when complete evidence exceeds the model budget" do
    {account, agent} = discovery_identity("oversized-reason")
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    body =
      String.duplicate("oversized exact source evidence ", 24_000) <>
        " TAIL ACTION: send the signed quarterly plan to Alex."

    message =
      now
      |> routine_message()
      |> Map.put("id", "oversized-reason-message")
      |> Map.put("message_id", "oversized-reason-message")
      |> Map.put("thread_id", "oversized-reason-thread")
      |> Map.put("google_provider", account.provider)
      |> Map.put("subject", "Quarterly review " <> String.duplicate("important context ", 20_000))
      |> Map.put("body", body)
      |> Map.put("body_text", body)
      |> Map.put("body_available", true)
      |> Map.put("body_status", "available")
      |> Map.put("provider_payload", %{"raw" => String.duplicate("provider-envelope", 40_000)})

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

    acquisition = fn _user_id, _skills, _configs, _context ->
      {bundle, complete_telemetry(),
       [%{account: account, kind: "gmail_discovery_watermark", value: "1700000375"}]}
    end

    assert {:ok, %{handoffs: [handoff], finalizer: finalizer}} =
             SourceAccountDiscovery.acquire(account, agent,
               acquisition: acquisition,
               acquisition_job_id: "oversized-reason-acquisition",
               now: now
             )

    refute SourceCursors.get(account.id, "gmail_discovery_watermark")

    assert {:ok, restored} =
             SourceAccountDiscovery.restore_partition_bundle(handoff["source_bundle"])

    assert [restored_message] = SourceBundle.gmail_messages(restored)
    assert restored_message["body"] == body

    assert {:error, :source_discovery_incomplete_decisions} =
             SourceAccountDiscovery.reason(account, agent, handoff,
               now: now,
               llm_complete: fn _prompt ->
                 flunk("incomplete evidence must not reach the model")
               end
             )

    refute SourceCursors.get(account.id, "gmail_discovery_watermark")
    assert finalizer["expected_source_items"] == 1
  end

  test "fails closed without advancing Slack when complete evidence exceeds the model budget" do
    {account, agent, team_id} = slack_discovery_identity("bounded-reason")
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    text =
      "Please review the incident response today. " <>
        String.duplicate("context ", 80_000) <>
        " TAIL ACTION: page the incident commander before 4pm."

    message_ts = "1700000400.000100"

    message = %{
      "ts" => message_ts,
      "thread_ts" => message_ts,
      "date" => DateTime.to_iso8601(now),
      "user" => "U-owner",
      "user_display_name" => "Kent Owner",
      "bot_id" => "B-helper",
      "subtype" => "bot_message",
      "text" => text,
      "text_resolved" => text,
      "permalink" => "https://example.slack.com/archives/D-request/p1700000400000100",
      "provider_payload" => %{"raw" => String.duplicate("slack-envelope", 40_000)}
    }

    bundle =
      %{trigger: %{type: :wakeup}, timestamp: now}
      |> SourceBundle.empty()
      |> SourceBundle.put_slack(%{
        "workspaces" => [
          %{
            "team_id" => team_id,
            "team_name" => "Example Workspace",
            "channels" => [
              %{
                "id" => "D-request",
                "name" => nil,
                "conversation_kind" => "im",
                "is_im" => true,
                "counterparty_user_id" => "U-requester",
                "counterparty_display_name" => "Alex Requester",
                "messages" => [message]
              }
            ]
          }
        ],
        "status" => "ready",
        "fetched_at" => now
      })

    acquisition = fn _user_id, _skills, _configs, _context ->
      {bundle, complete_telemetry("slack"),
       [%{account: account, kind: "slack_discovery_watermark", value: message_ts}]}
    end

    assert {:ok, %{handoffs: [handoff], finalizer: finalizer}} =
             SourceAccountDiscovery.acquire(account, agent,
               acquisition: acquisition,
               acquisition_job_id: "slack-bounded-reason-acquisition",
               now: now
             )

    refute SourceCursors.get(account.id, "slack_discovery_watermark")

    assert {:error, :source_discovery_incomplete_decisions} =
             SourceAccountDiscovery.reason(account, agent, handoff,
               now: now,
               llm_complete: fn _prompt ->
                 flunk("incomplete evidence must not reach the model")
               end
             )

    refute SourceCursors.get(account.id, "slack_discovery_watermark")
    assert finalizer["expected_source_items"] == 1
  end

  test "losslessly seals a structurally deep bundle at the durable handoff boundary" do
    {account, agent} = discovery_identity("deep-handoff")
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    deep_payload =
      Enum.reduce(1..20, "exact leaf", fn index, nested ->
        %{"level_#{index}" => nested}
      end)

    message =
      now
      |> routine_message()
      |> Map.put("id", "deep-message")
      |> Map.put("thread_id", "deep-thread")
      |> Map.put("payload", deep_payload)

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

    acquisition = fn _user_id, _skills, _configs, _context ->
      {bundle, complete_telemetry(),
       [%{account: account, kind: "gmail_discovery_watermark", value: "1700000400"}]}
    end

    assert {:ok, %{handoffs: [handoff]}} =
             SourceAccountDiscovery.acquire(account, agent,
               acquisition: acquisition,
               acquisition_job_id: "deep-acquisition",
               now: now
             )

    assert {:ok, _canonical} =
             DurablePayload.prepare_map(
               handoff,
               BackgroundJob.max_payload_bytes(),
               BackgroundJob.payload_bounds()
             )

    assert %{"__maraithon_bounded_source_bundle_v1__" => _sealed} =
             handoff["source_bundle"]

    assert {:ok, restored} =
             SourceAccountDiscovery.restore_partition_bundle(handoff["source_bundle"])

    assert [restored_message] = SourceBundle.gmail_messages(restored)
    assert restored_message["payload"] == deep_payload
  end

  test "rejects a compressed partition that expands beyond its authenticated size" do
    expanded = String.duplicate("amplified source evidence", 10_000)
    compressed = :zlib.gzip(expanded)

    partition = %{
      "__maraithon_bounded_binary_v1__" => %{
        "byte_size" => 1,
        "chunks" => [Base.encode64(compressed)],
        "codec" => "gzip-base64",
        "sha256" => Base.url_encode64(:crypto.hash(:sha256, expanded), padding: false)
      }
    }

    assert {:error, :source_discovery_partition_corrupt} =
             SourceAccountDiscovery.restore_partition_bundle(partition)
  end

  test "rejects nested whole-bundle markers instead of resetting the restore budget" do
    inner_encoded = Jason.encode!(%{})

    nested_marker = %{
      "__maraithon_bounded_source_bundle_v1__" => %{
        "byte_size" => byte_size(inner_encoded),
        "chunks" => [Base.encode64(:zlib.gzip(inner_encoded))],
        "codec" => "json-gzip-base64",
        "sha256" => Base.url_encode64(:crypto.hash(:sha256, inner_encoded), padding: false)
      }
    }

    outer_encoded = Jason.encode!(%{"nested" => nested_marker})

    partition = %{
      "__maraithon_bounded_source_bundle_v1__" => %{
        "byte_size" => byte_size(outer_encoded),
        "chunks" => [Base.encode64(:zlib.gzip(outer_encoded))],
        "codec" => "json-gzip-base64",
        "sha256" => Base.url_encode64(:crypto.hash(:sha256, outer_encoded), padding: false)
      }
    }

    assert {:error, :source_discovery_partition_corrupt} =
             SourceAccountDiscovery.restore_partition_bundle(%{"nested" => nested_marker})

    assert {:error, :source_discovery_partition_corrupt} =
             SourceAccountDiscovery.restore_partition_bundle(partition)
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

  defp slack_discovery_identity(suffix) do
    unique = System.unique_integer([:positive])
    user_id = "source-account-discovery-slack-#{suffix}-#{unique}@example.com"
    team_id = "T-#{unique}"

    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

    {:ok, account} =
      ConnectedAccounts.upsert_manual(user_id, "slack:#{team_id}", %{
        metadata: %{"team_id" => team_id, "team_name" => "Example Workspace"}
      })

    {:ok, agent} =
      Agents.create_agent(%{
        user_id: user_id,
        behavior: "ai_chief_of_staff",
        config: %{},
        status: "running"
      })

    {account, agent, team_id}
  end

  defp complete_telemetry(source \\ "gmail") do
    %{
      "sources" => %{
        source => %{
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
      "labels" => ["INBOX"],
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

  defp prompt_candidates(prompt) do
    [_instructions, candidates_json] =
      String.split(prompt, "CANDIDATE_TODOS_JSON:\n", parts: 2)

    candidates_json |> String.trim() |> Jason.decode!()
  end
end
