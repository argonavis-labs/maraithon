defmodule Maraithon.Runtime.PeriodicJobsTest do
  use Maraithon.DataCase, async: false

  import Ecto.Query

  alias Maraithon.Accounts
  alias Maraithon.Agents
  alias Maraithon.ConnectedAccounts
  alias Maraithon.OAuth
  alias Maraithon.Repo
  alias Maraithon.Runtime.BackgroundJob
  alias Maraithon.Runtime.PeriodicJobs
  alias Maraithon.TelegramAssistant.ProactiveQueue
  alias Maraithon.Todos

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

    {:ok, _account} =
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

    assert {:ok, %{discovered: 1, enqueued: 1}} =
             PeriodicJobs.schedule("source_account_discovery")

    job =
      Repo.one!(
        from(job in BackgroundJob,
          where: job.job_type == "runtime_partition:source_account_discovery"
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
          where: job.job_type == "runtime_partition:source_account_discovery"
        )
      )

    assert job.payload["account_id"] == account.id
    refute Map.has_key?(job.payload, "agent_id")
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

  test "completion coordinator fans out one durable closure job per source account" do
    user_id = "periodic-closure-#{System.unique_integer([:positive])}@example.com"
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

    {:ok, account} =
      ConnectedAccounts.upsert_manual(user_id, "google:closure@example.com", %{
        metadata: %{"account_email" => "closure@example.com"}
      })

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
          where: job.job_type == "runtime_partition:source_account_closure_acquire"
        )
      )

    assert job.queue == "runtime_provider_account"
    assert job.user_id == user_id
    assert job.payload["account_id"] == account.id
    assert job.payload["role"] == "closure"
    assert job.rate_limit_key == "google"
    assert String.starts_with?(job.partition_key, "provider-account:")
    refute String.contains?(job.partition_key, user_id)

    assert {:ok, %{discovered: 0, enqueued: 0}} =
             PeriodicJobs.schedule("todo_completion_sweep")
  end
end
