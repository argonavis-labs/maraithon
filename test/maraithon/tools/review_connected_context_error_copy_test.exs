defmodule Maraithon.Tools.ReviewConnectedContextErrorCopyTest do
  use Maraithon.DataCase, async: false

  alias Maraithon.Accounts
  alias Maraithon.OAuth
  alias Maraithon.Tools

  test "review_connected_context does not expose provider response bodies in source errors" do
    original_google_calendar = Application.get_env(:maraithon, :google_calendar, [])
    bypass = Bypass.open()

    Application.put_env(:maraithon, :google_calendar,
      api_base_url: "http://localhost:#{bypass.port}/calendar/v3"
    )

    on_exit(fn ->
      Application.put_env(:maraithon, :google_calendar, original_google_calendar)
    end)

    user_id = "people-review-calendar-error-#{System.unique_integer([:positive])}@example.com"
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

    {:ok, _token} =
      OAuth.store_tokens(user_id, "google", %{
        access_token: "calendar-token",
        scopes: ["calendar.readonly"]
      })

    Bypass.expect_once(bypass, "GET", "/calendar/v3/calendars/primary/events", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(
        500,
        Jason.encode!(%{"error" => "internal_stacktrace: db_timeout token=secret"})
      )
    end)

    assert {:ok, review} =
             Tools.execute("review_connected_context", %{
               "user_id" => user_id,
               "query" => "Charlie",
               "sources" => ["calendar"],
               "max_results" => 5,
               "timeout_ms" => 1_000
             })

    assert [%{source: "calendar", reason: "temporarily unavailable"}] = review.errors

    encoded = inspect(review.errors)
    refute encoded =~ "internal_stacktrace"
    refute encoded =~ "db_timeout"
    refute encoded =~ "token=secret"
    refute encoded =~ "500"
  end

  test "review_connected_context presents Slack matches without workspace internals" do
    original_slack = Application.get_env(:maraithon, :slack, [])
    bypass = Bypass.open()

    Application.put_env(:maraithon, :slack, api_base_url: "http://localhost:#{bypass.port}/api")

    on_exit(fn ->
      Application.put_env(:maraithon, :slack, original_slack)
    end)

    user_id = "people-review-slack-match-#{System.unique_integer([:positive])}@example.com"
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

    {:ok, _token} =
      OAuth.store_tokens(user_id, "slack:TSECRET:user:USECRET", %{
        access_token: "xoxp-user-token",
        scopes: ["search:read"],
        metadata: %{"team_id" => "TSECRET", "team_name" => "Agora"}
      })

    Bypass.expect_once(bypass, "GET", "/api/search.messages", fn conn ->
      assert ["Bearer xoxp-user-token"] == Plug.Conn.get_req_header(conn, "authorization")
      assert conn.query_string =~ "query=Charlie"
      assert conn.query_string =~ "count=5"

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(
        200,
        Jason.encode!(%{
          "ok" => true,
          "messages" => %{
            "total" => 1,
            "matches" => [
              %{
                "ts" => "171234.000100",
                "text" => "Charlie said the contract redline is ready.",
                "user" => "USECRET",
                "channel" => %{"id" => "CSECRET", "name" => "exec-ops"},
                "permalink" => "https://example.slack.com/archives/CSECRET/p171234000100"
              }
            ]
          }
        })
      )
    end)

    assert {:ok, review} =
             Tools.execute("review_connected_context", %{
               "user_id" => user_id,
               "query" => "Charlie",
               "sources" => ["slack"],
               "max_results" => 5,
               "timeout_ms" => 1_000
             })

    assert %{count: 1, errors: [], matches: [match]} = review.results["slack"]

    assert match == %{
             workspace: "Agora",
             channel_name: "exec-ops",
             text: "Charlie said the contract redline is ready."
           }

    assert [
             %{
               source: "slack",
               resource_type: "slack_message",
               title: "exec-ops",
               summary: "Charlie said the contract redline is ready.",
               metadata: %{workspace: "Agora", channel: "exec-ops"}
             }
           ] = review.source_observations

    encoded =
      inspect(%{result: review.results["slack"], observations: review.source_observations})

    refute encoded =~ "TSECRET"
    refute encoded =~ "CSECRET"
    refute encoded =~ "USECRET"
    refute encoded =~ "171234.000100"
    refute encoded =~ "p171234000100"
  end

  test "review_connected_context presents Slack source errors without team IDs or response bodies" do
    original_slack = Application.get_env(:maraithon, :slack, [])
    bypass = Bypass.open()

    Application.put_env(:maraithon, :slack, api_base_url: "http://localhost:#{bypass.port}/api")

    on_exit(fn ->
      Application.put_env(:maraithon, :slack, original_slack)
    end)

    user_id = "people-review-slack-error-#{System.unique_integer([:positive])}@example.com"
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

    {:ok, _token} =
      OAuth.store_tokens(user_id, "slack:TSECRET:user:USECRET", %{
        access_token: "xoxp-user-token",
        scopes: ["search:read"],
        metadata: %{"team_id" => "TSECRET", "team_name" => "Agora"}
      })

    Bypass.expect_once(bypass, "GET", "/api/search.messages", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(
        500,
        Jason.encode!(%{"error" => "internal_stacktrace token=slack-secret team=TSECRET"})
      )
    end)

    assert {:ok, review} =
             Tools.execute("review_connected_context", %{
               "user_id" => user_id,
               "query" => "Charlie",
               "sources" => ["slack"],
               "max_results" => 5,
               "timeout_ms" => 1_000
             })

    assert %{
             count: 0,
             matches: [],
             errors: [%{workspace: "Agora", reason: "temporarily unavailable"}]
           } =
             review.results["slack"]

    encoded = inspect(review.results["slack"])
    refute encoded =~ "TSECRET"
    refute encoded =~ "USECRET"
    refute encoded =~ "internal_stacktrace"
    refute encoded =~ "slack-secret"
    refute encoded =~ "500"
  end
end
