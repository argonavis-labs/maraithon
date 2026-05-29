defmodule MaraithonWeb.OAuthFlashCopyTest do
  use ExUnit.Case, async: true

  alias MaraithonWeb.OAuthFlashCopy

  test "technical OAuth failures fall back to actionable connection copy" do
    copy =
      OAuthFlashCopy.message(
        "error",
        "DBConnection.ConnectionError token=secret oauth_tokens stacktrace"
      )

    assert copy == "App connection did not finish. Reopen the connector and complete sign-in."
    refute copy =~ "DBConnection"
    refute copy =~ "token=secret"
    refute copy =~ "oauth_tokens"
    refute String.contains?(String.downcase(copy), "try again")
  end

  test "safe provider messages are preserved" do
    assert OAuthFlashCopy.message("error", "GitHub authorization was cancelled.") ==
             "GitHub authorization was cancelled."

    assert OAuthFlashCopy.message("connected", "Linear connected") == "Linear connected"
  end
end
