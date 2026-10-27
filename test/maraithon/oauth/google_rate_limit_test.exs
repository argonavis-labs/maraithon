defmodule Maraithon.OAuth.GoogleRateLimitTest do
  use Maraithon.DataCase, async: false
  alias Maraithon.{Accounts, ConnectedAccounts, HTTP, Repo}
  alias Maraithon.OAuth.Google

  test "Google quota errors retain retry timing across every verb without asking to reconnect" do
    user = "google-rate-#{Ecto.UUID.generate()}@example.invalid"
    {:ok, _} = Accounts.get_or_create_user_by_email(user)

    account =
      Repo.insert!(%Maraithon.Accounts.ConnectedAccount{
        user_id: user,
        provider: "google:rate-limit",
        status: "connected"
      })

    bypass = Bypass.open()

    for method <- [:get, :post, :put, :patch, :delete],
        reason <- ["rateLimitExceeded", "userRateLimitExceeded"] do
      path = "/#{method}/#{reason}"

      Bypass.expect_once(bypass, method |> to_string() |> String.upcase(), path, fn conn ->
        conn
        |> Plug.Conn.put_resp_header("retry-after", "57")
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(403, error_body([quota(reason)]))
      end)

      assert {:error, {:rate_limited, 57, :provider_limited} = error} =
               Google.api_request(
                 method,
                 "http://localhost:#{bypass.port}#{path}",
                 "test-token",
                 %{}
               )

      assert {:ok, 57} = Maraithon.Runtime.PeriodicJobs.retry_after_seconds_for(error)
      ConnectedAccounts.report_access_issue(user, account.provider, error)
      assert Repo.get!(Maraithon.Accounts.ConnectedAccount, account.id).status == "connected"
      refute Maraithon.Tools.GmailHelpers.normalize_error(error) |> inspect() =~ "reauth"
      refute inspect(error) =~ "private-provider-detail"
    end
  end

  test "permission, mixed and unknown errors stay distinct from transient throttles" do
    bypass = Bypass.open()
    permission = %{"domain" => "global", "reason" => "domainPolicy"}

    for {errors, i} <-
          Enum.with_index([
            [permission],
            [quota("userRateLimitExceeded"), permission],
            [quota("dailyLimitExceeded")],
            [],
            ["malformed"]
          ]) do
      path = "/denied/#{i}"

      Bypass.expect_once(bypass, "GET", path, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(403, error_body(errors))
      end)

      assert {:error, {:http_status, 403, _}} =
               Google.api_request(:get, "http://localhost:#{bypass.port}#{path}", "test-token")
    end
  end

  test "ordinary HTTP callers cannot reinterpret 403 using a Google-shaped body" do
    bypass = Bypass.open()

    Bypass.expect_once(bypass, "GET", "/other-provider", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(403, error_body([quota("userRateLimitExceeded")]))
    end)

    assert {:error, {:http_status, 403, _}} =
             HTTP.get("http://localhost:#{bypass.port}/other-provider")
  end

  defp quota(reason), do: %{"domain" => "usageLimits", "reason" => reason}

  defp error_body(errors),
    do:
      Jason.encode!(%{
        "error" => %{
          "code" => 403,
          "errors" => errors,
          "message" => "private-provider-detail"
        }
      })
end
