defmodule Maraithon.DiagnosticsExportTest do
  use Maraithon.DataCase, async: false

  alias Maraithon.Accounts
  alias Maraithon.ActionLedger
  alias Maraithon.Agents
  alias Maraithon.Agents.AgentRun
  alias Maraithon.ConnectedAccounts
  alias Maraithon.Diagnostics.Export
  alias Maraithon.LogBuffer
  alias Maraithon.Repo
  alias Maraithon.Runtime.BackgroundJob
  alias Maraithon.TelegramAssistant.Run, as: AssistantRun

  test "exports a redacted diagnostics bundle without raw secrets or prompts" do
    user_id = "diagnostics-#{System.unique_integer([:positive])}@example.com"
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

    {:ok, _account} =
      ConnectedAccounts.upsert_manual(user_id, "telegram", %{
        external_account_id: "12345",
        metadata: %{"access_token" => "xoxb-1234567890-secret"}
      })

    {:ok, _action} =
      ActionLedger.record(%{
        user_id: user_id,
        surface: "telegram",
        event_type: "tool.executed",
        status: "completed",
        source_evidence: %{"authorization" => "Bearer sk-abcdefghijklmnopqrstuvwxyz123456"},
        model_summary: "Used token sk-abcdefghijklmnopqrstuvwxyz123456 to test redaction.",
        metadata: %{"prompt_snapshot" => "raw hidden prompt", "safe" => "visible"}
      })

    raw_error = "http_status: 500 internal_stacktrace db_timeout token=secret"
    now = DateTime.utc_now()

    Repo.insert!(%AssistantRun{
      user_id: user_id,
      chat_id: "123456789",
      surface: "mobile",
      trigger_type: "inbound_message",
      status: "failed",
      model_provider: "openai",
      model_name: "gpt-5",
      prompt_snapshot: %{"system_prompt" => "raw hidden prompt"},
      started_at: now,
      finished_at: now,
      error: raw_error
    })

    {:ok, agent} =
      Agents.create_agent(%{
        user_id: user_id,
        behavior: "inbox_calendar_advisor",
        config: %{},
        status: "running",
        started_at: now
      })

    Repo.insert!(%AgentRun{
      user_id: user_id,
      agent_id: agent.id,
      behavior: agent.behavior,
      status: "failed",
      trigger_type: "manual",
      started_at: now,
      completed_at: now,
      error: raw_error
    })

    Repo.insert!(%BackgroundJob{
      user_id: user_id,
      queue: "default",
      job_type: "source_ingest",
      status: "failed",
      scheduled_at: now,
      failed_at: now,
      attempts: 1,
      last_error: raw_error
    })

    LogBuffer.clear()
    LogBuffer.record(%{level: :info, message: "Bearer sk-abcdefghijklmnopqrstuvwxyz123456"})
    _ = :sys.get_state(LogBuffer)

    output_dir =
      Path.join(System.tmp_dir!(), "maraithon-diagnostics-test-#{System.unique_integer()}")

    assert {:ok, result} = Export.run(output_dir: output_dir, user_id: user_id, limit: 10)
    assert File.dir?(result.output_dir)

    files = Path.wildcard(Path.join(output_dir, "*.json"))
    assert Path.join(output_dir, "manifest.json") in files
    assert Path.join(output_dir, "action_ledger.json") in files
    assert Path.join(output_dir, "trust_metrics.json") in files

    encoded = Enum.map_join(files, "\n", &File.read!/1)
    refute encoded =~ "abcdefghijklmnopqrstuvwxyz123456"
    refute encoded =~ "xoxb-1234567890-secret"
    refute encoded =~ "raw hidden prompt"
    refute encoded =~ "internal_stacktrace"
    refute encoded =~ "db_timeout"
    refute encoded =~ "token=secret"

    assert encoded =~
             "I could not finish that response. Ask for a narrower check or refresh the conversation before continuing."

    assert encoded =~ "That run did not complete. Review the last action before running it again."

    assert encoded =~
             "Background job did not complete. Review the latest status before rerunning it."

    assert encoded =~ "<redacted>"
  end
end
