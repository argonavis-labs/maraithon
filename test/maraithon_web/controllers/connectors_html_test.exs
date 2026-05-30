defmodule MaraithonWeb.ConnectorsHTMLTest do
  use ExUnit.Case, async: true

  alias MaraithonWeb.ConnectorsHTML

  test "connection error details hide implementation failures" do
    detail =
      ConnectorsHTML.connection_error_detail(%{
        details: "DBConnection.ConnectionError queue timeout on select * from oauth_tokens"
      })

    assert detail == "Refresh this page before continuing."
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
    assert ConnectorsHTML.connection_status_label(:unknown) == "status unavailable"
    assert ConnectorsHTML.refresh_token_status_label(:active) == "background access on"
    assert ConnectorsHTML.refresh_token_status_label(:inactive) == "reconnect needed"
    assert ConnectorsHTML.refresh_token_status_label(:missing) == "reconnect needed"
    assert ConnectorsHTML.refresh_token_status_label(:unknown) == "background access not checked"
    assert ConnectorsHTML.setup_status_label(:unexpected) == "setup not checked"
    assert ConnectorsHTML.format_datetime(:unexpected) == "not recorded"
    assert ConnectorsHTML.provider_subtitle(%{}) == "Connection details unavailable."
    refute ConnectorsHTML.provider_subtitle(%{}) =~ "not available yet"
    refute ConnectorsHTML.provider_subtitle(%{}) =~ "No details yet"
  end

  test "connection token summary avoids implementation terms" do
    summary =
      ConnectorsHTML.connection_token_summary(%{
        scopes: ["gmail.readonly"],
        expires_at: ~U[2026-05-29 12:00:00Z]
      })

    assert summary =~ "Permissions: gmail.readonly"
    assert summary =~ "Access expires May 29, 2026 at 12:00 PM UTC"
    refute summary =~ "Scopes"
    refute summary =~ "Expires "
  end

  test "connection token summary can render in the user's local timezone" do
    summary =
      ConnectorsHTML.connection_token_summary(
        %{
          scopes: ["gmail.readonly"],
          expires_at: ~U[2026-05-29 18:00:00Z]
        },
        %{name: "America/Toronto", offset_hours: -5}
      )

    assert summary =~ "Access expires May 29, 2026 at 2:00 PM ET"
    refute summary =~ "2026-05-29"
    refute summary =~ "18:00"
  end
end
