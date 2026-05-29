defmodule MaraithonWeb.ConnectorsHTMLTest do
  use ExUnit.Case, async: true

  alias MaraithonWeb.ConnectorsHTML

  test "connection error details hide implementation failures" do
    detail =
      ConnectorsHTML.connection_error_detail(%{
        details: "DBConnection.ConnectionError queue timeout on select * from oauth_tokens"
      })

    assert detail == "Refresh this page or try again in a few minutes."
    refute detail =~ "DBConnection"
    refute detail =~ "oauth_tokens"
  end

  test "connection token summary uses product copy when no details are available" do
    assert ConnectorsHTML.connection_token_summary(%{}) == "No additional connection details"
  end

  test "connection helper labels use product copy" do
    assert ConnectorsHTML.setup_completion_text(%{setup_status: :configured}) ==
             "Connection ready"

    assert ConnectorsHTML.setup_completion_text(%{}) == "Connection setup needed"
    assert ConnectorsHTML.connection_status_label(:missing_scope) == "needs permission"
    assert ConnectorsHTML.connection_status_label(:needs_refresh) == "reconnect needed"
    assert ConnectorsHTML.connection_status_label(:not_configured) == "setup needed"
    assert ConnectorsHTML.refresh_token_status_label(:active) == "background access on"
    assert ConnectorsHTML.refresh_token_status_label(:inactive) == "background access off"
    assert ConnectorsHTML.refresh_token_status_label(:missing) == "reconnect needed"
  end

  test "connection token summary avoids implementation terms" do
    summary =
      ConnectorsHTML.connection_token_summary(%{
        scopes: ["gmail.readonly"],
        expires_at: ~U[2026-05-29 12:00:00Z]
      })

    assert summary =~ "Permissions: gmail.readonly"
    assert summary =~ "Access expires 2026-05-29 12:00 UTC"
    refute summary =~ "Scopes"
    refute summary =~ "Expires "
  end
end
