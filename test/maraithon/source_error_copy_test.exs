defmodule Maraithon.SourceErrorCopyTest do
  use ExUnit.Case, async: true

  alias Maraithon.SourceErrorCopy

  test "keeps connection failures actionable" do
    assert SourceErrorCopy.reason(:no_token) == "not connected"
    assert SourceErrorCopy.reason("google_account_not_connected") == "not connected"
    assert SourceErrorCopy.reason({:error, "linear_not_connected"}) == "not connected"
  end

  test "keeps reauth failures actionable" do
    assert SourceErrorCopy.reason(:reauth_required) == "needs reconnect"
    assert SourceErrorCopy.reason("oauth_reauth_required: invalid_grant") == "needs reconnect"
    assert SourceErrorCopy.reason({:http_status, 401, "token expired"}) == "needs reconnect"
  end

  test "hides provider bodies and local internals" do
    reasons = [
      {:http_status, 500, ~s({"error":"internal_stacktrace: db_timeout token=secret"})},
      {:http_error, %RuntimeError{message: "connect failed for token secret"}},
      "google_calendar_api_failed: 500 %{secret: true}",
      "Slack is temporarily unavailable. Wait a minute before running this action.",
      "HTTP request failed for token=secret",
      {:provider_error, "raw local path /Users/kent/Library/secret"}
    ]

    copies = Enum.map(reasons, &SourceErrorCopy.reason/1)

    assert copies == [
             "service problem",
             "service problem",
             "service problem",
             "service problem",
             "service problem",
             "source check failed"
           ]

    encoded = inspect(copies)
    refute encoded =~ "internal_stacktrace"
    refute encoded =~ "secret"
    refute encoded =~ "/Users/kent"
    refute encoded =~ "temporarily unavailable"
    refute encoded =~ "unavailable"
  end

  test "keeps rate limits and timeouts specific" do
    assert SourceErrorCopy.reason({:rate_limited, "provider body"}) == "rate limited"
    assert SourceErrorCopy.reason({:http_status, 429, "provider body"}) == "rate limited"
    assert SourceErrorCopy.reason("slack_rate_limited token=secret") == "rate limited"
    assert SourceErrorCopy.reason({:http_status, 408, "provider body"}) == "timed out"
    assert SourceErrorCopy.reason("request timed out with token=secret") == "timed out"
  end
end
