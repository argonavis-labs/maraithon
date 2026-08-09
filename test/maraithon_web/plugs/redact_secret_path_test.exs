defmodule MaraithonWeb.Plugs.RedactSecretPathTest do
  use ExUnit.Case, async: true

  import Plug.Test

  alias MaraithonWeb.Plugs.RedactSecretPath

  test "redacts Telegram secret paths before telemetry, including suffix 404s" do
    for path <- [
          "/webhooks/telegram/super-secret",
          "/webhooks/telegram/super-secret/unmatched/suffix"
        ] do
      conn = conn(:post, path)
      original_path_info = conn.path_info
      redacted = RedactSecretPath.call(conn, [])

      assert redacted.request_path == "/webhooks/telegram/[REDACTED]"
      assert redacted.path_info == original_path_info
      refute redacted.request_path =~ "super-secret"
    end
  end

  test "leaves unrelated request paths unchanged" do
    conn = conn(:post, "/webhooks/github")
    assert RedactSecretPath.call(conn, []).request_path == "/webhooks/github"
  end

  test "Phoenix parameter filtering redacts webhook credential keys" do
    filtered =
      Phoenix.Logger.filter_values(%{
        "secret" => "path-secret",
        "token" => "api-token",
        "credential" => "operator-credential",
        "password" => "password-value",
        "safe" => "visible"
      })

    assert filtered == %{
             "secret" => "[FILTERED]",
             "token" => "[FILTERED]",
             "credential" => "[FILTERED]",
             "password" => "[FILTERED]",
             "safe" => "visible"
           }
  end
end
