defmodule Maraithon.Tools.ToolErrorCopyTest do
  use ExUnit.Case, async: true

  alias Maraithon.Tools.{
    ActionHelpers,
    GmailApiHelpers,
    GmailHelpers,
    GoogleCalendarHelpers,
    NotionApiHelpers,
    SlackHelpers,
    ToolErrorCopy
  }

  test "connected source copy keeps recovery states actionable without provider bodies" do
    opts = [
      label: "Google",
      not_connected: "google_account_not_connected",
      reauth_required: "google_account_reauth_required",
      reconnect_required: "google_account_reconnect_required"
    ]

    assert ToolErrorCopy.connected_source(:no_token, opts) == "google_account_not_connected"

    assert ToolErrorCopy.connected_source(
             {:http_status, 401, ~s({"error":"invalid_grant","token":"secret"})},
             opts
           ) == "google_account_reauth_required"

    assert ToolErrorCopy.connected_source(
             {:http_status, 500, ~s({"error":"stacktrace token=secret"})},
             opts
           ) == "Google is temporarily unavailable. Wait a minute before running this action."
  end

  test "safe messages preserve validation copy and hide technical detail" do
    fallback = ToolErrorCopy.action_failed("Linear", "create the issue")

    assert ToolErrorCopy.safe_message("title is required", fallback) == "title is required"

    assert ToolErrorCopy.safe_message("RuntimeError token=secret stacktrace", fallback) ==
             fallback

    assert ToolErrorCopy.safe_message("api_key=sk-or-v1-super-secret-token", fallback) ==
             fallback

    assert ToolErrorCopy.safe_message({:db, :timeout}, fallback) == fallback
    refute String.contains?(String.downcase(fallback), "try again")
  end

  test "action helper error copy redacts non-string failures before surfacing them" do
    message =
      ActionHelpers.safe_error(
        {:failed, %{api_key: "sk-or-v1-super-secret-token", error: "validation failed"}}
      )

    assert message == "Action did not complete. No confirmed change was recorded."
    refute inspect(message) =~ "sk-or-v1"
    refute inspect(message) =~ "super-secret-token"

    assert ActionHelpers.safe_error(:enoent) ==
             "Action did not complete. No confirmed change was recorded."
  end

  test "provider helper errors do not leak tokens, status bodies, or inspected terms" do
    checks = [
      GmailHelpers.normalize_error({:http_status, 500, "internal_stacktrace token=secret"}),
      GmailApiHelpers.normalize_error({:http_status, 403, "invalid_grant token=secret"}),
      GoogleCalendarHelpers.normalize_error(
        {:exit, {%RuntimeError{message: "token=secret"}, []}}
      ),
      NotionApiHelpers.normalize_error({:http_status, 500, "body token=secret"}),
      SlackHelpers.normalize_error({:slack_error, "invalid_auth"}),
      SlackHelpers.normalize_error({:exit, {:db_timeout, "token=secret"}})
    ]

    assert Enum.all?(checks, &match?({:error, message} when is_binary(message), &1))

    encoded = inspect(checks)
    refute encoded =~ "internal_stacktrace"
    refute encoded =~ "token=secret"
    refute encoded =~ "RuntimeError"
    refute encoded =~ "invalid_auth"
    refute encoded =~ "{:db_timeout"
  end
end
