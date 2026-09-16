defmodule Maraithon.OAuth.SlackAdmissionTest do
  use Maraithon.DataCase, async: false
  alias Maraithon.OAuth.Slack

  setup do
    bypass = Bypass.open()
    previous = Application.get_env(:maraithon, :slack, [])
    Application.put_env(:maraithon, :slack, api_base_url: "http://localhost:#{bypass.port}/api")
    on_exit(fn -> Application.put_env(:maraithon, :slack, previous) end)
    %{bypass: bypass}
  end

  test "workspace and method cooldown spans member and bot tokens, but isolates other lanes", c do
    Bypass.expect_once(c.bypass, "GET", "/api/conversations.replies", fn conn ->
      conn |> Plug.Conn.put_resp_header("retry-after", "90") |> Plug.Conn.resp(429, "limited")
    end)

    assert {:error, {:rate_limited, 90, :provider_limited}} =
             Slack.api_request(:get, "conversations.replies?channel=C1", access("T1", "U1"))

    assert {:error, {:rate_limited, seconds, :provider_cooldown}} =
             Slack.api_request(:get, "conversations.replies?channel=C2", access("T1"))

    assert seconds in 89..90

    Bypass.expect_once(c.bypass, "GET", "/api/conversations.history", &ok/1)
    assert {:ok, _} = Slack.api_request(:get, "conversations.history?channel=C1", access("T1"))

    Bypass.expect_once(c.bypass, "GET", "/api/conversations.replies", &ok/1)
    assert {:ok, _} = Slack.api_request(:get, "conversations.replies?channel=C1", access("T2"))
  end

  test "posts share channel pacing across actors, while another channel can send", c do
    Bypass.expect_once(c.bypass, "POST", "/api/chat.postMessage", &ok/1)
    assert {:ok, _} = Slack.api_request(:post, "chat.postMessage", access("T1"), %{channel: "C1"})

    # Inspect the one-second deadline, then lengthen only this fixture's window
    # so a slow test machine cannot make the cross-token assertion race time.
    assert %{rows: [[1]]} =
             Repo.query!(
               "SELECT EXTRACT(EPOCH FROM blocked_until - updated_at)::int FROM background_job_rate_limits WHERE queue = 'http_slack_channel'"
             )

    Repo.query!(
      "UPDATE background_job_rate_limits SET blocked_until = timezone('UTC', clock_timestamp()) + interval '30 seconds' WHERE queue = 'http_slack_channel'"
    )

    assert {:error, {:rate_limited, _, :provider_cooldown}} =
             Slack.api_request(:post, "chat.postMessage", access("T1", "U1"), %{channel: "C1"})

    Bypass.expect_once(c.bypass, "POST", "/api/chat.postMessage", &ok/1)

    assert {:ok, _} =
             Slack.api_request(:post, "chat.postMessage", access("T1", "U1"), %{channel: "C2"})
  end

  for status <- [200, 429] do
    @tag status: status
    test "HTTP #{status} rate limit blocks posts to other channels too", c do
      Bypass.expect_once(c.bypass, "POST", "/api/chat.postMessage", fn conn ->
        conn
        |> Plug.Conn.put_resp_header("retry-after", "90")
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(c.status, Jason.encode!(%{"ok" => false, "error" => "ratelimited"}))
      end)

      assert {:error, {:rate_limited, 90, :provider_limited}} =
               Slack.api_request(:post, "chat.postMessage", access("T1"), %{channel: "C1"})

      assert {:error, {:rate_limited, seconds, :provider_cooldown}} =
               Slack.api_request(:post, "chat.postMessage", access("T1", "U1"), %{channel: "C2"})

      assert seconds in 89..90
    end
  end

  test "missing Retry-After on a Slack JSON error gets a durable default", c do
    Bypass.expect_once(c.bypass, "GET", "/api/users.info", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(%{"ok" => false, "error" => "ratelimited"}))
    end)

    assert {:error, {:rate_limited, :provider_limited}} =
             Slack.api_request(:get, "users.info?user=U1", access("T1"))

    assert {:error, {:rate_limited, seconds, :provider_cooldown}} =
             Slack.api_request(:get, "users.info?user=U2", access("T1", "U1"))

    assert seconds in 29..30
  end

  test "a bare token or malformed workspace cannot bypass shared admission" do
    for access <- [
          "raw-token",
          %{access_token: "token", provider: "google"},
          %{access_token: "token", provider: "slack:"}
        ] do
      assert {:error, :slack_workspace_required} = Slack.api_request(:get, "users.info", access)
    end
  end

  defp access(team, user \\ nil),
    do: %{
      access_token: "fixture-#{user || "bot"}",
      provider: "slack:#{team}" <> if(user, do: ":user:#{user}", else: "")
    }

  defp ok(conn),
    do:
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, ~s({"ok":true}))
end
