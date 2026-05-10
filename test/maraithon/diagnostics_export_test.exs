defmodule Maraithon.DiagnosticsExportTest do
  use Maraithon.DataCase, async: false

  alias Maraithon.Accounts
  alias Maraithon.ActionLedger
  alias Maraithon.ConnectedAccounts
  alias Maraithon.Diagnostics.Export
  alias Maraithon.LogBuffer

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
    assert encoded =~ "<redacted>"
  end
end
