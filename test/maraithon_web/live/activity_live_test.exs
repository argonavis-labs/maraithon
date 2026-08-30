defmodule MaraithonWeb.ActivityLiveTest do
  use MaraithonWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Maraithon.Accounts
  alias Maraithon.Agents
  alias Maraithon.ConnectedAccounts
  alias Maraithon.Runtime.BackgroundJobs
  alias Maraithon.Todos

  @user_email "activity-live@example.com"

  setup %{conn: conn} do
    {:ok, user} = Accounts.get_or_create_user_by_email(@user_email)
    {:ok, conn: log_in_test_user(conn, @user_email), user: user}
  end

  test "shows user-owned OTP runs, safe steps, and authoritative todo creation", %{conn: conn} do
    {:ok, agent} =
      Agents.create_agent(%{
        behavior: "prompt_agent",
        user_id: @user_email,
        status: "running"
      })

    {:ok, run} =
      Agents.start_agent_run(agent, %{
        trigger_type: "schedule",
        budget_snapshot: %{"llm_calls" => 500, "tool_calls" => 520}
      })

    {:ok, step} =
      Agents.record_agent_run_step(run.id, agent.id, %{
        step_type: "tool_call",
        tool_name: "upsert_todos"
      })

    {:ok, _step} = Agents.update_agent_run_step(step.id, %{status: "completed"})
    {:ok, _run} = Agents.complete_agent_run(run.id)

    {:ok, [_todo]} =
      Todos.upsert_many(
        @user_email,
        [
          %{
            "source" => "gmail",
            "kind" => "general",
            "title" => "Send the Acme proposal",
            "dedupe_key" => "activity-live-created-todo"
          }
        ],
        actor_type: :agent
      )

    {:ok, view, html} = live(conn, "/activity")

    assert html =~ "Latest activity"
    assert html =~ "Custom assistant"
    assert html =~ "Completed"
    assert html =~ "Created or updated todos"
    assert has_element?(view, "#run-#{run.id}-summary", "Finished after 1 step")
    refute html =~ "Finished after 520 actions"
    assert has_element?(view, "#run-#{run.id}-llm-calls", "0")
    assert has_element?(view, "#run-#{run.id}-tool-calls", "1")
    assert html =~ "Todo created"
    assert html =~ "Send the Acme proposal"
    assert html =~ "Run details"
    assert html =~ ~s(aria-current="page")
  end

  test "keeps other users out and renders safe failure copy", %{conn: conn} do
    other_email = "other-activity-live@example.com"
    {:ok, _other_user} = Accounts.get_or_create_user_by_email(other_email)

    {:ok, other_agent} =
      Agents.create_agent(%{
        behavior: "prompt_agent",
        user_id: other_email,
        status: "running"
      })

    {:ok, other_run} = Agents.start_agent_run(other_agent, %{trigger_type: "message"})
    {:ok, _other_run} = Agents.complete_agent_run(other_run.id)

    {:ok, [_other_todo]} =
      Todos.upsert_many(other_email, [
        %{
          "source" => "manual",
          "kind" => "general",
          "title" => "Other user's private todo",
          "dedupe_key" => "other-activity-live-todo"
        }
      ])

    {:ok, own_agent} =
      Agents.create_agent(%{
        behavior: "prompt_agent",
        user_id: @user_email,
        status: "running"
      })

    {:ok, own_run} = Agents.start_agent_run(own_agent, %{trigger_type: "message"})

    {:ok, _own_run} =
      Agents.fail_agent_run(own_run.id, %{
        error: "secret token stacktrace provider body"
      })

    {:ok, _view, html} = live(conn, "/activity")

    assert html =~ "That run did not complete"
    refute html =~ "secret token stacktrace"
    refute html =~ "Other user&#39;s private todo"
    refute html =~ "Other user's private todo"
  end

  test "shows every latest Gmail and Slack fan-out without loading private handoffs", %{
    conn: conn
  } do
    {:ok, gmail_account} =
      ConnectedAccounts.upsert_manual(@user_email, "google:founder@example.com", %{
        metadata: %{"account_email" => "founder@example.com"}
      })

    {:ok, slack_account} =
      ConnectedAccounts.upsert_manual(@user_email, "slack:T123", %{
        metadata: %{"team_name" => "Maraithon HQ"}
      })

    fan_out_specs = [
      {"runtime_partition:source_account_discovery", "runtime_provider_account",
       "source-account-discovery"},
      {"runtime_partition:source_account_discovery_reason", "runtime_model_user",
       "source-account-discovery-reason"},
      {"runtime_partition:source_account_discovery_finalize", "runtime_model_user",
       "source-account-discovery-finalize"},
      {"runtime_partition:source_account_closure_acquire", "runtime_provider_account",
       "source-account-closure-acquire"},
      {"runtime_partition:source_account_closure_reason", "runtime_model_user",
       "source-account-closure-reason"},
      {"runtime_partition:source_account_closure_finalize", "runtime_model_user",
       "source-account-closure-finalize"}
    ]

    source_jobs =
      for account <- [gmail_account, slack_account],
          {job_type, queue, dedupe_prefix} <- fan_out_specs do
        {:ok, job} =
          enqueue_source_run(
            @user_email,
            account.id,
            job_type,
            queue,
            dedupe_prefix
          )

        job
      end

    other_email = "other-source-activity@example.com"
    {:ok, _other_user} = Accounts.get_or_create_user_by_email(other_email)

    {:ok, other_account} =
      ConnectedAccounts.upsert_manual(other_email, "google:private@example.com", %{
        metadata: %{"account_email" => "private@example.com"}
      })

    {:ok, _other_run} =
      enqueue_source_run(
        other_email,
        other_account.id,
        "runtime_partition:source_account_discovery",
        "runtime_provider_account",
        "source-account-discovery"
      )

    {:ok, view, html} = live(conn, "/activity")

    headers = BackgroundJobs.list_latest_source_account_runs_for_user(@user_email)

    assert length(headers) == 12
    assert Enum.all?(headers, &(not Map.has_key?(&1, :payload) and Map.has_key?(&1, :result)))
    assert html =~ "12 source fan-outs"
    assert html =~ "Gmail todo discovery"
    assert html =~ "Gmail todo completion"
    assert html =~ "Slack todo discovery"
    assert html =~ "Slack todo completion"
    assert html =~ "founder@example.com"
    assert html =~ "Maraithon HQ"
    refute html =~ "private@example.com"

    Enum.each(source_jobs, fn job ->
      assert has_element?(view, "#source-run-#{job.id}-summary")

      expected_policy =
        if job.queue == "runtime_model_user" and
             job.job_type not in [
               "runtime_partition:source_account_discovery_finalize",
               "runtime_partition:source_account_closure_finalize"
             ],
           do: "Pending · max 1",
           else: "0"

      assert has_element?(view, "#source-run-#{job.id}-ai-policy", expected_policy)
    end)
  end

  defp enqueue_source_run(user_id, account_id, job_type, queue, dedupe_prefix) do
    BackgroundJobs.enqueue(job_type, %{
      user_id: user_id,
      queue: queue,
      dedupe_key: "runtime-partition:#{dedupe_prefix}:#{account_id}",
      partition_key: "activity-test:#{account_id}",
      rate_limit_key: if(queue == "runtime_model_user", do: "model", else: "provider"),
      max_attempts: 3,
      scheduled_at: DateTime.utc_now(),
      payload: %{"account_id" => account_id}
    })
  end
end
