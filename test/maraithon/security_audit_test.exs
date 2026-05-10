defmodule Maraithon.SecurityAuditTest do
  use Maraithon.DataCase, async: false

  alias Maraithon.SecurityAudit

  setup do
    original = %{
      github: Application.get_env(:maraithon, :github, []),
      telegram: Application.get_env(:maraithon, :telegram, []),
      api_auth: Application.get_env(:maraithon, :api_auth, []),
      admin_auth: Application.get_env(:maraithon, :admin_auth, []),
      runtime: Application.get_env(:maraithon, Maraithon.Runtime, [])
    }

    on_exit(fn ->
      Application.put_env(:maraithon, :github, original.github)
      Application.put_env(:maraithon, :telegram, original.telegram)
      Application.put_env(:maraithon, :api_auth, original.api_auth)
      Application.put_env(:maraithon, :admin_auth, original.admin_auth)
      Application.put_env(:maraithon, Maraithon.Runtime, original.runtime)
    end)

    :ok
  end

  test "fails loudly for representative dangerous production settings" do
    Application.put_env(:maraithon, :github, webhook_secret: "", allow_unsigned: true)
    Application.put_env(:maraithon, :telegram, webhook_secret_path: "", allow_unsigned: false)
    Application.put_env(:maraithon, :api_auth, bearer_token: "short")
    Application.put_env(:maraithon, :admin_auth, username: "", password: "tiny")
    Application.put_env(:maraithon, Maraithon.Runtime, tool_allowed_paths: ["/"])

    audit = SecurityAudit.run(env: :prod)
    finding_ids = Enum.map(audit.findings, & &1.id)

    assert audit.status == "fail"
    assert "webhook_unsigned_github" in finding_ids
    assert "webhook_secret_missing_telegram" in finding_ids
    assert "api_bearer_token_weak" in finding_ids
    assert "admin_password_weak" in finding_ids
    assert "tool_file_roots_too_broad" in finding_ids

    assert Enum.all?(audit.findings, &is_binary(&1.remediation))
  end

  test "keeps ToolPolicy and redaction self-check findings clean" do
    audit = SecurityAudit.run(env: :test)
    finding_ids = Enum.map(audit.findings, & &1.id)

    refute "tool_policy_confirmation_missing" in finding_ids
    refute "tool_policy_metadata_missing" in finding_ids
    refute "redaction_self_test_failed" in finding_ids
  end
end
