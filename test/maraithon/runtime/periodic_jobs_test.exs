defmodule Maraithon.Runtime.PeriodicJobsTest do
  use Maraithon.DataCase, async: false

  import Ecto.Query

  alias Maraithon.Accounts
  alias Maraithon.Agents
  alias Maraithon.ConnectedAccounts
  alias Maraithon.Connectors.SourceCursors
  alias Maraithon.OAuth
  alias Maraithon.Repo
  alias Maraithon.Runtime.BackgroundJob
  alias Maraithon.Runtime.BackgroundJobs
  alias Maraithon.Runtime.GmailSourceReplay
  alias Maraithon.Runtime.PeriodicJobs
  alias Maraithon.Runtime.SourceCycleProofs
  alias Maraithon.TelegramAssistant.ProactiveQueue
  alias Maraithon.Todos

  test "closure fan-out workers use distinct opaque partitions" do
    keys =
      Enum.map(1..3, fn fanout_index ->
        PeriodicJobs.source_closure_reason_partition_key(
          "worker@example.com",
          "acquisition-id",
          fanout_index
        )
      end)

    assert length(Enum.uniq(keys)) == 3
    assert Enum.all?(keys, &String.starts_with?(&1, "source-closure-reason:"))
    refute Enum.any?(keys, &String.contains?(&1, "worker@example.com"))
  end

  test "Slack reconciliation fan-outs are evenly spread across one minute" do
    started_at = ~U[2026-08-31 12:00:00Z]

    scheduled_at =
      Enum.map(1..10, &PeriodicJobs.slack_reconciliation_fanout_scheduled_at(started_at, &1))

    assert hd(scheduled_at) == started_at
    assert List.last(scheduled_at) == DateTime.add(started_at, 54, :second)

    assert scheduled_at
           |> Enum.chunk_every(2, 1, :discard)
           |> Enum.all?(fn [left, right] -> DateTime.diff(right, left, :second) == 6 end)
  end

  test "Gmail source replay enqueues fenced discovery and closure without moving live cursors" do
    user_id = "periodic-gmail-replay-#{System.unique_integer([:positive])}@example.com"
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

    {:ok, account} =
      ConnectedAccounts.upsert_manual(user_id, "google:#{user_id}", %{
        metadata: %{"account_email" => user_id, "services" => ["gmail"]}
      })

    lower = DateTime.utc_now() |> DateTime.add(-24, :hour) |> DateTime.to_unix(:second)
    upper = DateTime.utc_now() |> DateTime.add(-1, :second) |> DateTime.to_unix(:second)

    assert {:ok,
            %{
              outcome: "enqueued",
              source_replay_reference: reference,
              discovery_job_id: discovery_job_id,
              closure_job_id: closure_job_id
            }} = PeriodicJobs.enqueue_gmail_source_replay(account.id, lower, upper)

    discovery = Repo.get!(BackgroundJob, discovery_job_id)
    closure = Repo.get!(BackgroundJob, closure_job_id)

    assert discovery.job_type == "runtime_partition:source_account_discovery"
    assert closure.job_type == "runtime_partition:source_account_closure_acquire"
    assert closure.payload["discovery_job_id"] == discovery.id

    for job <- [discovery, closure] do
      assert job.payload["source_replay_mode"] == "historical"
      assert job.payload["source_replay_lower"] == lower
      assert job.payload["source_replay_upper"] == upper
      assert job.payload["source_replay_reference"] == reference
    end

    refute Maraithon.Connectors.SourceCursors.get(account.id, "gmail_discovery_watermark")
    refute Maraithon.Connectors.SourceCursors.get(account.id, "gmail_closure_watermark")

    replay_cursors =
      Maraithon.Connectors.SourceCursor
      |> where([cursor], cursor.connected_account_id == ^account.id)
      |> where([cursor], like(cursor.kind, "gmail_%_replay:%"))
      |> Repo.all()

    assert length(replay_cursors) == 2
    assert Enum.all?(replay_cursors, &(&1.value == Integer.to_string(lower)))
  end

  test "Gmail source replay resumes closure from a verified completed discovery" do
    user_id = "periodic-gmail-replay-resume-#{System.unique_integer([:positive])}@example.com"
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

    {:ok, account} =
      ConnectedAccounts.upsert_manual(user_id, "google:#{user_id}", %{
        metadata: %{"account_email" => user_id, "services" => ["gmail"]}
      })

    lower = DateTime.utc_now() |> DateTime.add(-24, :hour) |> DateTime.to_unix(:second)
    upper = DateTime.utc_now() |> DateTime.add(-1, :second) |> DateTime.to_unix(:second)

    assert {:ok,
            %{
              discovery_job_id: discovery_job_id,
              closure_job_id: first_closure_job_id
            }} = PeriodicJobs.enqueue_gmail_source_replay(account.id, lower, upper)

    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    BackgroundJob
    |> where([job], job.id == ^discovery_job_id)
    |> Repo.update_all(set: [status: "completed", completed_at: now, updated_at: now])

    BackgroundJob
    |> where([job], job.id == ^first_closure_job_id)
    |> Repo.update_all(set: [status: "failed", failed_at: now, updated_at: now])

    assert {:ok, replay} = GmailSourceReplay.build(account, lower, upper, now)

    assert %{job_type: "runtime_partition:source_account_discovery", user_id: ^user_id} =
             Repo.get!(BackgroundJob, discovery_job_id)

    assert {:ok, cycle} =
             SourceCycleProofs.create_cycle(
               %{
                 user_id: account.user_id,
                 connected_account_id: account.id,
                 provider: account.provider,
                 role: "discovery",
                 cursor_kind: replay.discovery_kind,
                 lower_cursor: Integer.to_string(lower),
                 upper_cursor: Integer.to_string(upper),
                 boundary: "lower_inclusive_upper_exclusive",
                 acquisition_job_id: discovery_job_id,
                 reason_job_ids: [],
                 finalizer_job_id: nil,
                 captured_at: now
               },
               [],
               []
             )

    assert cycle.proof_version == 2

    assert {:ok, _cursor} =
             SourceCursors.put(account, replay.discovery_kind, %{
               "value" => Integer.to_string(upper)
             })

    assert {:ok,
            %{
              outcome: "closure_resumed",
              discovery_job_id: ^discovery_job_id,
              closure_job_id: resumed_closure_job_id
            }} = PeriodicJobs.enqueue_gmail_source_replay(account.id, lower, upper)

    refute resumed_closure_job_id == first_closure_job_id
    assert Repo.get!(BackgroundJob, resumed_closure_job_id).status == "pending"
  end

  test "waking a Slack workspace also enqueues one stable reconciliation planner" do
    user_id = "periodic-slack-reconciliation-#{System.unique_integer([:positive])}@example.com"
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

    {:ok, account} =
      ConnectedAccounts.upsert_manual(user_id, "slack:T-RECONCILIATION", %{
        external_account_id: "T-RECONCILIATION",
        metadata: %{"team_id" => "T-RECONCILIATION"}
      })

    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    assert {:ok, %{discovery: %{outcome: "enqueued"}}} =
             PeriodicJobs.wake_source_account(account, now: now)

    planner =
      Repo.one!(
        from(job in BackgroundJob,
          where:
            job.user_id == ^user_id and
              job.job_type == "runtime_partition:slack_reconciliation_plan"
        )
      )

    assert planner.queue == "runtime_provider_account"
    assert planner.payload["account_id"] == account.id
    assert planner.payload["role"] == "discovery"
    assert planner.rate_limit_key == "slack"
    refute String.contains?(planner.partition_key, user_id)

    planner
    |> Ecto.Changeset.change(status: "completed", completed_at: now)
    |> Repo.update!()

    assert {:ok, %{discovery: %{job_id: _job_id}}} =
             PeriodicJobs.wake_source_account(account, now: DateTime.add(now, 30, :second))

    assert 1 ==
             Repo.aggregate(
               from(job in BackgroundJob,
                 where:
                   job.user_id == ^user_id and
                     job.job_type == "runtime_partition:slack_reconciliation_plan"
               ),
               :count
             )

    assert {:ok, %{discovery: %{job_id: _job_id}}} =
             PeriodicJobs.wake_source_account(account, now: DateTime.add(now, 56, :second))

    assert 2 ==
             Repo.aggregate(
               from(job in BackgroundJob,
                 where:
                   job.user_id == ^user_id and
                     job.job_type == "runtime_partition:slack_reconciliation_plan"
               ),
               :count
             )
  end

  test "Slack planner stays Activity-visible but does not fan out over an active workspace child" do
    user_id = "periodic-slack-active-#{System.unique_integer([:positive])}@example.com"
    team_id = "T-ACTIVE-PLANNER"
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

    {:ok, account} =
      ConnectedAccounts.upsert_manual(user_id, "slack:#{team_id}", %{
        external_account_id: team_id,
        metadata: %{"team_id" => team_id}
      })

    assert {:ok, %BackgroundJob{}} =
             BackgroundJobs.enqueue("runtime_partition:slack_conversation_reconcile", %{
               user_id: user_id,
               queue: "runtime_provider_account",
               dedupe_key: "runtime-partition:slack-conversation:active-child:#{account.id}",
               scheduled_at: DateTime.utc_now(),
               payload: %{
                 "account_id" => account.id,
                 "channel_id" => "C-ACTIVE",
                 "conversation_kind" => "public_channel"
               }
             })

    planner = %BackgroundJob{
      id: Ecto.UUID.generate(),
      user_id: user_id,
      queue: "runtime_provider_account",
      job_type: "runtime_partition:slack_reconciliation_plan",
      payload: %{"account_id" => account.id, "role" => "discovery"}
    }

    assert {:ok,
            %{
              outcome: "deferred_active_child",
              planned_fanouts: 0,
              fanout_count: 0,
              enqueued_fanouts: 0,
              readable_conversations: nil
            }} = PeriodicJobs.execute(planner)

    assert 1 ==
             Repo.aggregate(
               from(job in BackgroundJob,
                 where:
                   job.user_id == ^user_id and
                     job.job_type == "runtime_partition:slack_conversation_reconcile" and
                     job.status in ["pending", "running"]
               ),
               :count
             )
  end

  test "Slack planner enforces one workspace child at the enqueue boundary" do
    bypass = Bypass.open()
    previous_slack = Application.get_env(:maraithon, :slack, [])
    previous_runtime = Application.get_env(:maraithon, Maraithon.Runtime, [])

    Application.put_env(:maraithon, :slack, api_base_url: "http://localhost:#{bypass.port}/api")

    Application.put_env(
      :maraithon,
      Maraithon.Runtime,
      Keyword.put(previous_runtime, :slack_reconciliation_batch_size, 2)
    )

    on_exit(fn ->
      Application.put_env(:maraithon, :slack, previous_slack)
      Application.put_env(:maraithon, Maraithon.Runtime, previous_runtime)
    end)

    user_id = "periodic-slack-one-child-#{System.unique_integer([:positive])}@example.com"
    team_id = "T-ONE-CHILD"
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

    assert {:ok, _token} =
             OAuth.store_tokens(user_id, "slack:#{team_id}", %{
               access_token: "xoxb-bot-token",
               scopes: ["channels:read"],
               metadata: %{"team_id" => team_id}
             })

    assert {:ok, _token} =
             OAuth.store_tokens(user_id, "slack:#{team_id}:user:U-SELF", %{
               access_token: "xoxp-user-token",
               scopes: ["channels:read", "channels:history"],
               metadata: %{"team_id" => team_id}
             })

    account = ConnectedAccounts.get(user_id, "slack:#{team_id}")

    Bypass.expect_once(bypass, "GET", "/api/conversations.list", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(
        200,
        Jason.encode!(%{
          "ok" => true,
          "channels" => [
            %{"id" => "C-FIRST", "is_member" => true},
            %{"id" => "C-SECOND", "is_member" => true}
          ]
        })
      )
    end)

    planner = %BackgroundJob{
      id: Ecto.UUID.generate(),
      user_id: user_id,
      queue: "runtime_provider_account",
      job_type: "runtime_partition:slack_reconciliation_plan",
      payload: %{"account_id" => account.id, "role" => "discovery"}
    }

    assert {:ok,
            %{
              outcome: "fanout_ready",
              planned_fanouts: 2,
              fanout_count: 1,
              enqueued_fanouts: 1
            }} = PeriodicJobs.execute(planner)

    assert 1 ==
             Repo.aggregate(
               from(job in BackgroundJob,
                 where:
                   job.user_id == ^user_id and
                     job.job_type == "runtime_partition:slack_conversation_reconcile" and
                     job.status in ["pending", "running"]
               ),
               :count
             )
  end

  test "source account wake makes the Activity-visible closure acquisition wait for discovery" do
    user_id = "periodic-wake-dependency-#{System.unique_integer([:positive])}@example.com"
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

    {:ok, account} =
      ConnectedAccounts.upsert_manual(user_id, "google:#{user_id}", %{
        metadata: %{"account_email" => user_id, "services" => ["gmail"]}
      })

    {:ok, [_todo]} =
      Todos.upsert_many(user_id, [
        %{
          "source" => "gmail",
          "kind" => "gmail_triage",
          "title" => "Wait for discovery before checking closure",
          "summary" => "This todo belongs to the source account being woken.",
          "next_action" => "Reply after the discovery cycle settles.",
          "source_account_id" => account.id,
          "source_account_label" => user_id,
          "source_item_id" => "wake-dependency-thread",
          "dedupe_key" => "periodic-wake-dependency"
        }
      ])

    now = DateTime.utc_now()

    assert {:ok,
            %{
              discovery: %{outcome: "enqueued", job_id: discovery_job_id},
              closure: %{outcome: "enqueued", job_id: closure_job_id}
            }} = PeriodicJobs.wake_source_account(account, now: now)

    discovery_job = Repo.get!(BackgroundJob, discovery_job_id)
    closure_job = Repo.get!(BackgroundJob, closure_job_id)

    assert discovery_job.job_type == "runtime_partition:source_account_discovery"
    assert closure_job.job_type == "runtime_partition:source_account_closure_acquire"
    assert closure_job.payload["discovery_job_id"] == discovery_job.id

    assert {:ok, %{outcome: "waiting_for_discovery", dependency_stage: "acquisition"},
            {:reschedule_in, 10_000}} = PeriodicJobs.execute(closure_job)
  end

  test "closure acquisition waits for the exact discovery finalizer and proceeds after it settles" do
    user_id = "periodic-finalizer-dependency-#{System.unique_integer([:positive])}@example.com"
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

    {:ok, account} =
      ConnectedAccounts.upsert_manual(user_id, "google:#{user_id}", %{
        metadata: %{"account_email" => user_id, "services" => ["gmail"]}
      })

    {:ok, discovery_job} =
      BackgroundJobs.enqueue("runtime_partition:source_account_discovery", %{
        user_id: user_id,
        queue: "runtime_provider_account",
        dedupe_key: "periodic-finalizer-dependency-discovery:#{account.id}",
        payload: %{"account_id" => account.id, "role" => "discovery"}
      })

    {:ok, finalizer_job} =
      BackgroundJobs.enqueue("runtime_partition:source_account_discovery_finalize", %{
        user_id: user_id,
        queue: "runtime_model_user",
        dedupe_key: "periodic-finalizer-dependency-finalizer:#{account.id}",
        payload: %{
          "account_id" => account.id,
          "acquisition_job_id" => discovery_job.id,
          "reason_job_ids" => [Ecto.UUID.generate()]
        }
      })

    discovery_job =
      discovery_job
      |> BackgroundJob.changeset(%{
        status: "completed",
        completed_at: DateTime.utc_now(),
        result: %{
          "outcome" => "fanout_ready",
          "finalizer_job_id" => finalizer_job.id
        }
      })
      |> Repo.update!()

    closure_job = %BackgroundJob{
      id: Ecto.UUID.generate(),
      user_id: user_id,
      queue: "runtime_provider_account",
      job_type: "runtime_partition:source_account_closure_acquire",
      payload: %{
        "account_id" => account.id,
        "discovery_job_id" => discovery_job.id,
        "role" => "closure"
      }
    }

    assert {:ok, %{outcome: "waiting_for_discovery", dependency_stage: "finalizer"},
            {:reschedule_in, 10_000}} = PeriodicJobs.execute(closure_job)

    finalizer_job
    |> Ecto.Changeset.change(status: "completed", completed_at: DateTime.utc_now())
    |> Repo.update!()

    account
    |> Ecto.Changeset.change(status: "disconnected")
    |> Repo.update!()

    assert {:ok, %{outcome: "skipped", reason: :account_not_connected}} =
             PeriodicJobs.execute(closure_job)
  end

  test "source account wake reuses acquisitions while either fan-out graph is active" do
    user_id = "periodic-active-graph-#{System.unique_integer([:positive])}@example.com"
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

    {:ok, account} =
      ConnectedAccounts.upsert_manual(user_id, "google:#{user_id}", %{
        metadata: %{"account_email" => user_id, "services" => ["gmail"]}
      })

    {:ok, [_todo]} =
      Todos.upsert_many(user_id, [
        %{
          "source" => "gmail",
          "kind" => "gmail_triage",
          "title" => "Keep one source graph per account and role",
          "summary" => "An active graph still owns this cursor interval.",
          "next_action" => "Wait for its finalizer.",
          "dedupe_key" => "periodic-active-source-graph"
        }
      ])

    assert {:ok,
            %{
              discovery: %{job_id: discovery_job_id},
              closure: %{job_id: closure_job_id}
            }} = PeriodicJobs.wake_source_account(account, now: DateTime.utc_now())

    Enum.each([discovery_job_id, closure_job_id], fn job_id ->
      BackgroundJob
      |> Repo.get!(job_id)
      |> Ecto.Changeset.change(status: "completed", completed_at: DateTime.utc_now())
      |> Repo.update!()
    end)

    {:ok, discovery_reason} =
      BackgroundJobs.enqueue("runtime_partition:source_account_discovery_reason", %{
        user_id: user_id,
        queue: "runtime_model_user",
        dedupe_key:
          "runtime-partition:source-account-discovery-reason:#{discovery_job_id}:1-of-1:#{account.id}",
        payload: %{
          "account_id" => account.id,
          "acquisition_job_id" => discovery_job_id,
          "fanout_index" => 1,
          "fanout_count" => 1
        }
      })

    {:ok, closure_reason} =
      BackgroundJobs.enqueue("runtime_partition:source_account_closure_reason", %{
        user_id: user_id,
        queue: "runtime_model_user",
        dedupe_key:
          "runtime-partition:source-account-closure-reason:#{closure_job_id}:source-1-of-1:todo-1-of-1:1-of-1:#{account.id}",
        payload: %{
          "account_id" => account.id,
          "acquisition_job_id" => closure_job_id,
          "fanout_index" => 1,
          "fanout_count" => 1
        }
      })

    assert {:ok,
            %{
              discovery: %{job_id: ^discovery_job_id},
              closure: %{job_id: ^closure_job_id}
            }} = PeriodicJobs.wake_source_account(account, now: DateTime.utc_now())

    Enum.each([discovery_reason, closure_reason], fn reason_job ->
      reason_job
      |> Ecto.Changeset.change(status: "completed", completed_at: DateTime.utc_now())
      |> Repo.update!()
    end)

    {:ok, _legacy_discovery_finalizer} =
      BackgroundJobs.enqueue("runtime_partition:source_account_discovery_finalize", %{
        user_id: user_id,
        queue: "runtime_model_user",
        dedupe_key: "runtime-partition:source-account-discovery-finalize:#{account.id}",
        payload: %{
          "account_id" => account.id,
          "acquisition_job_id" => discovery_job_id
        }
      })

    {:ok, _legacy_closure_finalizer} =
      BackgroundJobs.enqueue("runtime_partition:source_account_closure_finalize", %{
        user_id: user_id,
        queue: "runtime_model_user",
        dedupe_key: "runtime-partition:source-account-closure-finalize:#{account.id}",
        payload: %{
          "account_id" => account.id,
          "acquisition_job_id" => closure_job_id
        }
      })

    assert {:ok,
            %{
              discovery: %{job_id: ^discovery_job_id},
              closure: %{job_id: ^closure_job_id}
            }} = PeriodicJobs.wake_source_account(account, now: DateTime.utc_now())

    assert Repo.aggregate(
             from(job in BackgroundJob,
               where:
                 job.user_id == ^user_id and
                   job.job_type == "runtime_partition:source_account_discovery"
             ),
             :count
           ) == 1

    assert Repo.aggregate(
             from(job in BackgroundJob,
               where:
                 job.user_id == ^user_id and
                   job.job_type == "runtime_partition:source_account_closure_acquire"
             ),
             :count
           ) == 1
  end

  test "provider coordinator creates a stable account-partitioned refresh row" do
    user_id = "periodic-provider-#{System.unique_integer([:positive])}@example.com"
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

    {:ok, token} =
      OAuth.store_tokens(user_id, "google", %{
        access_token: "expiring-access",
        refresh_token: "refresh-token",
        expires_at: DateTime.add(DateTime.utc_now(), 60, :second)
      })

    assert {:ok, %{discovered: 1, enqueued: 1}} = PeriodicJobs.schedule("token_refresher")

    job =
      Repo.one!(
        from(job in BackgroundJob,
          where: job.queue == "runtime_provider_account",
          where: job.job_type == "runtime_partition:token_refresh"
        )
      )

    assert job.user_id == user_id
    assert job.payload["token_id"] == token.id
    assert job.rate_limit_key == "google"
    assert String.starts_with?(job.partition_key, "provider-account:")
    refute String.contains?(job.partition_key, user_id)

    assert {:ok, %{discovered: 0, enqueued: 0}} = PeriodicJobs.schedule("token_refresher")

    assert Repo.aggregate(
             from(candidate in BackgroundJob,
               where: candidate.dedupe_key == ^job.dedupe_key
             ),
             :count
           ) == 1
  end

  test "wrapped provider Retry-After reaches the durable cooldown contract" do
    bypass = Bypass.open()
    previous_google = Application.get_env(:maraithon, :google, [])

    Application.put_env(:maraithon, :google,
      token_url: "http://localhost:#{bypass.port}/token",
      client_id: "test-client",
      client_secret: "test-secret"
    )

    on_exit(fn -> Application.put_env(:maraithon, :google, previous_google) end)

    user_id = "periodic-rate-limit-#{System.unique_integer([:positive])}@example.com"
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

    {:ok, token} =
      OAuth.store_tokens(user_id, "google", %{
        access_token: "expiring-access",
        refresh_token: "refresh-token",
        expires_at: DateTime.add(DateTime.utc_now(), 60, :second)
      })

    Bypass.expect_once(bypass, "POST", "/token", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("retry-after", "42")
      |> Plug.Conn.resp(429, "provider limited")
    end)

    job = %BackgroundJob{
      queue: "runtime_provider_account",
      job_type: "runtime_partition:token_refresh",
      payload: %{"token_id" => token.id, "lookahead_seconds" => 300}
    }

    assert {:error,
            {:retry_after, 42, {:token_refresh_failed, {:rate_limited, 42, :provider_limited}}}} =
             PeriodicJobs.execute(job)
  end

  test "model coordinator creates one opaque durable tenant partition" do
    user_id = "periodic-model-#{System.unique_integer([:positive])}@example.com"
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)
    :ok = Maraithon.TestSupport.CapturingAPNS.enable(user_id)

    unique = System.unique_integer([:positive])

    assert {:ok, _candidate} =
             ProactiveQueue.enqueue(%{
               user_id: user_id,
               source: "insight",
               source_id: "periodic-source-#{unique}",
               dedupe_key: "periodic-candidate:#{unique}",
               title: "A due proactive candidate",
               body: "This candidate should be discovered for its tenant.",
               urgency: 0.7,
               why_now: "It is pending now.",
               structured_data: %{},
               telegram_opts: %{}
             })

    assert {:ok, %{discovered: 1, enqueued: 1}} =
             PeriodicJobs.schedule("proactive_check_in")

    job =
      Repo.one!(
        from(job in BackgroundJob,
          where: job.queue == "runtime_model_user",
          where: job.job_type == "runtime_partition:proactive_check_in"
        )
      )

    assert job.user_id == user_id
    assert job.payload == %{"user_id" => user_id}
    assert job.rate_limit_key == "model"
    assert String.starts_with?(job.partition_key, "tenant:")
    refute String.contains?(job.partition_key, user_id)

    assert {:ok, %{discovered: 0, enqueued: 0}} =
             PeriodicJobs.schedule("proactive_check_in")
  end

  test "discovery coordinator fans out one provider job per Gmail account" do
    user_id = "periodic-discovery-#{System.unique_integer([:positive])}@example.com"
    provider = "google:#{user_id}"
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

    {:ok, account} =
      ConnectedAccounts.upsert_manual(user_id, provider, %{
        metadata: %{"account_email" => user_id, "services" => ["gmail"]}
      })

    {:ok, _token} =
      OAuth.store_tokens(user_id, provider, %{
        access_token: "discovery-access",
        refresh_token: "discovery-refresh",
        metadata: %{"account_email" => user_id, "services" => ["gmail"]}
      })

    {:ok, agent} =
      Agents.create_agent(%{
        user_id: user_id,
        behavior: "ai_chief_of_staff",
        config: %{},
        status: "running"
      })

    {:ok, completed_finalizer} =
      BackgroundJobs.enqueue("runtime_partition:source_account_discovery_finalize", %{
        user_id: user_id,
        queue: "runtime_model_user",
        dedupe_key: "runtime-partition:source-account-discovery-finalize:#{account.id}",
        payload: %{"account_id" => account.id}
      })

    completed_finalizer
    |> Ecto.Changeset.change(status: "completed", completed_at: DateTime.utc_now())
    |> Repo.update!()

    assert {:ok, %{discovered: 1, enqueued: 1}} =
             PeriodicJobs.schedule("source_account_discovery")

    job =
      Repo.one!(
        from(job in BackgroundJob,
          where:
            job.user_id == ^user_id and
              job.job_type == "runtime_partition:source_account_discovery"
        )
      )

    assert job.queue == "runtime_provider_account"
    assert job.user_id == user_id
    assert job.payload["agent_id"] == agent.id
    assert job.payload["role"] == "discovery"
    assert job.rate_limit_key == "google"
    assert String.starts_with?(job.partition_key, "provider-account:")
    refute String.contains?(job.partition_key, user_id)

    assert {:ok, %{discovered: 0, enqueued: 0}} =
             PeriodicJobs.schedule("source_account_discovery")
  end

  test "discovery coordinator does not require a preinstalled Chief row" do
    user_id = "periodic-default-discovery-#{System.unique_integer([:positive])}@example.com"
    provider = "google:#{user_id}"
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

    {:ok, account} =
      ConnectedAccounts.upsert_manual(user_id, provider, %{
        metadata: %{"account_email" => user_id, "services" => ["gmail"]}
      })

    {:ok, _token} =
      OAuth.store_tokens(user_id, provider, %{
        access_token: "default-discovery-access",
        refresh_token: "default-discovery-refresh",
        metadata: %{"account_email" => user_id, "services" => ["gmail"]}
      })

    assert {:ok, %{discovered: 1, enqueued: 1}} =
             PeriodicJobs.schedule("source_account_discovery")

    job =
      Repo.one!(
        from(job in BackgroundJob,
          where:
            job.user_id == ^user_id and
              job.job_type == "runtime_partition:source_account_discovery"
        )
      )

    assert job.payload["account_id"] == account.id
    refute Map.has_key?(job.payload, "agent_id")
  end

  test "discovery coordinator waits for an orphan reason only while it has attempts left" do
    user_id = "periodic-orphan-discovery-#{System.unique_integer([:positive])}@example.com"
    provider = "google:#{user_id}"
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

    {:ok, account} =
      ConnectedAccounts.upsert_manual(user_id, provider, %{
        metadata: %{"account_email" => user_id, "services" => ["gmail"]}
      })

    {:ok, _token} =
      OAuth.store_tokens(user_id, provider, %{
        access_token: "orphan-discovery-access",
        refresh_token: "orphan-discovery-refresh",
        metadata: %{"account_email" => user_id, "services" => ["gmail"]}
      })

    {:ok, reason_job} =
      BackgroundJobs.enqueue("runtime_partition:source_account_discovery_reason", %{
        user_id: user_id,
        queue: "runtime_model_user",
        dedupe_key:
          "runtime-partition:source-account-discovery-reason:orphan:1-of-1:#{account.id}",
        max_attempts: 1,
        payload: %{"account_id" => account.id, "acquisition_job_id" => "orphan"}
      })

    assert {:ok, %{discovered: 0, enqueued: 0}} =
             PeriodicJobs.schedule("source_account_discovery")

    reason_job
    |> Ecto.Changeset.change(attempts: reason_job.max_attempts)
    |> Repo.update!()

    assert {:ok, %{discovered: 1, enqueued: 1}} =
             PeriodicJobs.schedule("source_account_discovery")
  end

  test "discovery finalizer discards a graph whose reason worker failed" do
    user_id = "periodic-failed-discovery-#{System.unique_integer([:positive])}@example.com"
    provider = "google:#{user_id}"
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

    {:ok, account} =
      ConnectedAccounts.upsert_manual(user_id, provider, %{
        metadata: %{"account_email" => user_id, "services" => ["gmail"]}
      })

    {:ok, reason_job} =
      BackgroundJobs.enqueue("runtime_partition:source_account_discovery_reason", %{
        user_id: user_id,
        queue: "runtime_model_user",
        dedupe_key:
          "runtime-partition:source-account-discovery-reason:failed:1-of-1:#{account.id}",
        max_attempts: 1,
        payload: %{"account_id" => account.id, "acquisition_job_id" => "failed"}
      })

    reason_job
    |> Ecto.Changeset.change(
      status: "failed",
      attempts: 1,
      failed_at: DateTime.utc_now()
    )
    |> Repo.update!()

    finalizer = %BackgroundJob{
      user_id: user_id,
      queue: "runtime_model_user",
      job_type: "runtime_partition:source_account_discovery_finalize",
      payload: %{
        "account_id" => account.id,
        "acquisition_job_id" => "failed",
        "reason_job_ids" => [reason_job.id]
      }
    }

    assert {:error, {:discard, :source_discovery_child_failed}} =
             PeriodicJobs.execute(finalizer)
  end

  test "closure finalizer discards a graph whose reason worker failed" do
    user_id = "periodic-failed-closure-#{System.unique_integer([:positive])}@example.com"
    provider = "google:#{user_id}"
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

    {:ok, account} =
      ConnectedAccounts.upsert_manual(user_id, provider, %{
        metadata: %{"account_email" => user_id, "services" => ["gmail"]}
      })

    {:ok, reason_job} =
      BackgroundJobs.enqueue("runtime_partition:source_account_closure_reason", %{
        user_id: user_id,
        queue: "runtime_model_user",
        dedupe_key: "runtime-partition:source-account-closure-reason:#{account.id}",
        max_attempts: 1,
        payload: %{"account_id" => account.id, "acquisition_job_id" => "failed"}
      })

    reason_job
    |> Ecto.Changeset.change(
      status: "failed",
      attempts: 1,
      failed_at: DateTime.utc_now()
    )
    |> Repo.update!()

    finalizer = %BackgroundJob{
      user_id: user_id,
      queue: "runtime_model_user",
      job_type: "runtime_partition:source_account_closure_finalize",
      payload: %{
        "account_id" => account.id,
        "acquisition_job_id" => "failed",
        "reason_job_ids" => [reason_job.id]
      }
    }

    assert {:error, {:discard, :source_closure_child_failed}} =
             PeriodicJobs.execute(finalizer)
  end

  test "discovery coordinator rotates beyond a bounded account batch" do
    previous_runtime = Application.get_env(:maraithon, Maraithon.Runtime, [])

    Application.put_env(
      :maraithon,
      Maraithon.Runtime,
      Keyword.put(previous_runtime, :source_account_discovery_batch_size, 1)
    )

    on_exit(fn -> Application.put_env(:maraithon, Maraithon.Runtime, previous_runtime) end)

    Repo.delete_all(
      from(cursor in "runtime_sweep_cursors",
        where: field(cursor, :sweep_key) == "durable_source_account_discovery"
      )
    )

    accounts =
      Enum.map(1..2, fn index ->
        user_id =
          "periodic-rotating-discovery-#{index}-#{System.unique_integer([:positive])}@example.com"

        provider = "google:#{user_id}"
        {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

        {:ok, account} =
          ConnectedAccounts.upsert_manual(user_id, provider, %{
            metadata: %{"account_email" => user_id, "services" => ["gmail"]}
          })

        {:ok, _token} =
          OAuth.store_tokens(user_id, provider, %{
            access_token: "rotating-discovery-access",
            refresh_token: "rotating-discovery-refresh",
            metadata: %{"account_email" => user_id, "services" => ["gmail"]}
          })

        account
      end)
      |> Enum.sort_by(& &1.id)

    assert {:ok, %{discovered: 1, enqueued: 1}} =
             PeriodicJobs.schedule("source_account_discovery")

    assert {:ok, %{discovered: 1, enqueued: 1}} =
             PeriodicJobs.schedule("source_account_discovery")

    user_ids = Enum.map(accounts, & &1.user_id)

    enqueued_account_ids =
      BackgroundJob
      |> where(
        [job],
        job.user_id in ^user_ids and job.job_type == "runtime_partition:source_account_discovery"
      )
      |> Repo.all()
      |> Enum.map(& &1.payload["account_id"])
      |> Enum.sort()

    assert enqueued_account_ids == Enum.map(accounts, & &1.id)
  end

  test "discovery coordinator respects an explicitly stopped Chief" do
    user_id = "periodic-paused-discovery-#{System.unique_integer([:positive])}@example.com"
    provider = "google:#{user_id}"
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

    {:ok, _account} =
      ConnectedAccounts.upsert_manual(user_id, provider, %{
        metadata: %{"account_email" => user_id, "services" => ["gmail"]}
      })

    {:ok, _token} =
      OAuth.store_tokens(user_id, provider, %{
        access_token: "paused-discovery-access",
        refresh_token: "paused-discovery-refresh",
        metadata: %{"account_email" => user_id, "services" => ["gmail"]}
      })

    {:ok, _agent} =
      Agents.create_agent(%{
        user_id: user_id,
        behavior: "ai_chief_of_staff",
        config: %{},
        status: "stopped"
      })

    assert {:ok, %{discovered: 0, enqueued: 0}} =
             PeriodicJobs.schedule("source_account_discovery")
  end

  test "completion coordinator fans out paired discovery and closure jobs per source account" do
    user_id = "periodic-closure-#{System.unique_integer([:positive])}@example.com"
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

    {:ok, account} =
      ConnectedAccounts.upsert_manual(user_id, "google:closure@example.com", %{
        metadata: %{"account_email" => "closure@example.com"}
      })

    {:ok, _token} =
      OAuth.store_tokens(user_id, "google:closure@example.com", %{
        access_token: "closure-access"
      })

    {:ok, completed_finalizer} =
      BackgroundJobs.enqueue("runtime_partition:source_account_closure_finalize", %{
        user_id: user_id,
        queue: "runtime_model_user",
        dedupe_key: "runtime-partition:source-account-closure-finalize:#{account.id}",
        payload: %{"account_id" => account.id}
      })

    completed_finalizer
    |> Ecto.Changeset.change(status: "completed", completed_at: DateTime.utc_now())
    |> Repo.update!()

    {:ok, [_todo]} =
      Todos.upsert_many(user_id, [
        %{
          "source" => "gmail",
          "kind" => "gmail_triage",
          "title" => "Reply from the closure account",
          "summary" => "A source-account todo remains open.",
          "next_action" => "Reply in the Gmail thread.",
          "priority" => 85,
          "source_account_id" => account.id,
          "source_account_label" => "closure@example.com",
          "source_item_id" => "closure-thread",
          "dedupe_key" => "periodic-account-closure"
        }
      ])

    assert {:ok,
            %{
              discovered: 1,
              enqueued: 1,
              account_partitions: 1,
              legacy_partitions: 0
            }} = PeriodicJobs.schedule("todo_completion_sweep")

    job =
      Repo.one!(
        from(job in BackgroundJob,
          where:
            job.user_id == ^user_id and
              job.job_type == "runtime_partition:source_account_closure_acquire"
        )
      )

    discovery_job =
      Repo.one!(
        from(job in BackgroundJob,
          where:
            job.user_id == ^user_id and
              job.job_type == "runtime_partition:source_account_discovery"
        )
      )

    assert job.queue == "runtime_provider_account"
    assert job.user_id == user_id
    assert job.payload["account_id"] == account.id
    assert job.payload["role"] == "closure"
    assert job.payload["discovery_job_id"] == discovery_job.id
    assert job.rate_limit_key == "google"
    assert String.starts_with?(job.partition_key, "provider-account:")
    refute String.contains?(job.partition_key, user_id)

    assert {:ok, %{discovered: 0, enqueued: 0}} =
             PeriodicJobs.schedule("todo_completion_sweep")
  end

  test "completion coordinator waits for an orphan reason only while it has attempts left" do
    user_id = "periodic-orphan-closure-#{System.unique_integer([:positive])}@example.com"
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

    {:ok, account} =
      ConnectedAccounts.upsert_manual(user_id, "google:orphan-closure@example.com", %{
        metadata: %{"account_email" => "orphan-closure@example.com"}
      })

    {:ok, _token} =
      OAuth.store_tokens(user_id, "google:orphan-closure@example.com", %{
        access_token: "orphan-closure-access"
      })

    {:ok, [_todo]} =
      Todos.upsert_many(user_id, [
        %{
          "source" => "gmail",
          "kind" => "gmail_triage",
          "title" => "Wait for an orphaned closure reason",
          "summary" => "An active source-account reason already owns this account.",
          "next_action" => "Wait for the existing reason job.",
          "priority" => 80,
          "source_account_id" => account.id,
          "source_account_label" => "orphan-closure@example.com",
          "source_item_id" => "orphan-closure-thread",
          "dedupe_key" => "periodic-orphan-account-closure"
        }
      ])

    {:ok, reason_job} =
      BackgroundJobs.enqueue("runtime_partition:source_account_closure_reason", %{
        user_id: user_id,
        queue: "runtime_model_user",
        dedupe_key: "runtime-partition:source-account-closure-reason:orphan:1-of-1:#{account.id}",
        max_attempts: 1,
        payload: %{"account_id" => account.id, "acquisition_job_id" => "orphan"}
      })

    assert {:ok, %{discovered: 0, enqueued: 0}} =
             PeriodicJobs.schedule("todo_completion_sweep")

    reason_job
    |> Ecto.Changeset.change(attempts: reason_job.max_attempts)
    |> Repo.update!()

    assert {:ok,
            %{
              discovered: 1,
              enqueued: 1,
              account_partitions: 1,
              legacy_partitions: 0
            }} = PeriodicJobs.schedule("todo_completion_sweep")
  end

  test "completion coordinator covers every token-backed source account for an open-todo user" do
    user_id = "periodic-cross-source-#{System.unique_integer([:positive])}@example.com"
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

    providers = ["google:first@example.com", "google:second@example.com", "slack:T-CROSS"]

    accounts =
      Enum.map(providers, fn provider ->
        {:ok, account} = ConnectedAccounts.upsert_manual(user_id, provider, %{})
        {:ok, _token} = OAuth.store_tokens(user_id, provider, %{access_token: "source-access"})
        account
      end)

    {:ok, _tokenless} =
      ConnectedAccounts.upsert_manual(user_id, "google:tokenless@example.com", %{})

    {:ok, disconnected} =
      ConnectedAccounts.upsert_manual(user_id, "slack:T-DISCONNECTED", %{})

    {:ok, _token} =
      OAuth.store_tokens(user_id, disconnected.provider, %{access_token: "disconnected-access"})

    disconnected
    |> Ecto.Changeset.change(status: "disconnected")
    |> Repo.update!()

    {:ok, [_todo]} =
      Todos.upsert_many(user_id, [
        %{
          "source" => "manual",
          "title" => "Cross-source completion evidence",
          "summary" => "Any connected source may contain completion evidence.",
          "next_action" => "Check every connected source account.",
          "dedupe_key" => "periodic-cross-source-coverage"
        }
      ])

    assert {:ok,
            %{
              discovered: 3,
              enqueued: 3,
              account_partitions: 3,
              legacy_partitions: 0
            }} = PeriodicJobs.schedule("todo_completion_sweep")

    expected_account_ids = accounts |> Enum.map(& &1.id) |> Enum.sort()

    covered_account_ids =
      BackgroundJob
      |> where(
        [job],
        job.user_id == ^user_id and
          job.job_type == "runtime_partition:source_account_closure_acquire"
      )
      |> Repo.all()
      |> Enum.map(&BackgroundJob.hydrate_payloads/1)
      |> Enum.map(& &1.payload["account_id"])
      |> Enum.sort()

    assert expected_account_ids == covered_account_ids
  end
end
