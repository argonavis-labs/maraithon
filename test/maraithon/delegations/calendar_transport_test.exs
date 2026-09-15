defmodule Maraithon.Delegations.CalendarTransportTest do
  use Maraithon.DataCase, async: false
  alias Maraithon.{Accounts, ConnectedAccounts, OAuth}
  alias Maraithon.Connectors.GoogleCalendar

  setup do
    bypass = Bypass.open()
    original = Application.get_env(:maraithon, :google_calendar, [])

    Application.put_env(:maraithon, :google_calendar,
      api_base_url: "http://localhost:#{bypass.port}"
    )

    on_exit(fn -> Application.put_env(:maraithon, :google_calendar, original) end)
    user_id = "delegation-calendar-#{System.unique_integer([:positive])}@example.invalid"
    {:ok, _} = Accounts.get_or_create_user_by_email(user_id)

    for {provider, token} <- [{"google", "wrong-account"}, {"google:eval", "bound-account"}] do
      {:ok, _} =
        OAuth.store_tokens(user_id, provider, %{
          access_token: token,
          refresh_token: "fixture",
          expires_in: 3600,
          scopes: ["https://www.googleapis.com/auth/calendar"]
        })
    end

    %{bypass: bypass, user_id: user_id, account: ConnectedAccounts.get(user_id, "google:eval")}
  end

  test "a busy event on page two is included from the bound account", context do
    Bypass.expect(context.bypass, "GET", "/calendars/primary/events", fn conn ->
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer bound-account"]
      conn = Plug.Conn.fetch_query_params(conn)

      body =
        if conn.query_params["pageToken"] == "second",
          do: %{
            "items" => [
              %{
                "id" => "busy",
                "start" => %{"dateTime" => "2026-09-16T14:00:00Z"},
                "end" => %{"dateTime" => "2026-09-16T15:00:00Z"}
              }
            ]
          },
          else: %{"items" => [], "nextPageToken" => "second"}

      json(conn, body)
    end)

    assert {:ok, [%{event_id: "busy"}]} =
             GoogleCalendar.events_in_window(
               context.user_id,
               context.account.id,
               ~U[2026-09-16 12:00:00Z],
               ~U[2026-09-16 22:00:00Z]
             )
  end

  test "repeated pagination tokens produce a source gap, not free time", context do
    Bypass.expect(context.bypass, "GET", "/calendars/primary/events", fn conn ->
      json(conn, %{"items" => [], "nextPageToken" => "loop"})
    end)

    assert {:error, :calendar_pagination_loop} =
             GoogleCalendar.events_in_window(
               context.user_id,
               context.account.id,
               ~U[2026-09-16 12:00:00Z],
               ~U[2026-09-16 22:00:00Z]
             )
  end

  test "an endless unique cursor is bounded and cannot claim coverage", context do
    Bypass.expect(context.bypass, "GET", "/calendars/primary/events", fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)
      page = String.to_integer(conn.query_params["pageToken"] || "0")
      assert page < 10
      json(conn, %{"items" => [], "nextPageToken" => to_string(page + 1)})
    end)

    assert {:error, :calendar_source_gap} =
             GoogleCalendar.events_in_window(
               context.user_id,
               context.account.id,
               ~U[2026-09-16 12:00:00Z],
               ~U[2026-09-16 22:00:00Z]
             )
  end

  test "a missing or foreign account never falls back to the default token", context do
    assert {:error, :invalid_google_account} =
             GoogleCalendar.events_in_window(
               context.user_id,
               -1,
               ~U[2026-09-16 12:00:00Z],
               ~U[2026-09-16 22:00:00Z]
             )
  end

  test "a fresh conflict after an offer prevents booking", c do
    Bypass.expect_once(c.bypass, "GET", "/calendars/primary/events", fn conn ->
      json(conn, %{
        "items" => [
          %{
            "id" => "new-busy",
            "start" => %{"dateTime" => "2026-09-16T14:00:00Z"},
            "end" => %{"dateTime" => "2026-09-16T14:30:00Z"}
          }
        ]
      })
    end)

    assert {:error, "slot_no_longer_free"} =
             Maraithon.Delegations.Scheduling.ensure_free(
               c.user_id,
               [c.account.id],
               ~U[2026-09-16 14:00:00Z],
               ~U[2026-09-16 14:30:00Z],
               "our-event",
               Maraithon.Delegations.Preferences.defaults()
             )
  end

  test "a later read error cannot be treated as an empty calendar", c do
    Bypass.expect_once(c.bypass, "GET", "/calendars/primary/events", fn conn ->
      Plug.Conn.resp(conn, 403, "not authorized")
    end)

    assert {:error, _} =
             Maraithon.Delegations.Scheduling.ensure_free(
               c.user_id,
               [c.account.id],
               ~U[2026-09-16 14:00:00Z],
               ~U[2026-09-16 14:30:00Z],
               "our-event",
               Maraithon.Delegations.Preferences.defaults()
             )
  end

  test "an existing event with changed attendees is not a successful retry", c do
    Bypass.expect_once(c.bypass, "POST", "/calendars/primary/events", fn conn ->
      Plug.Conn.resp(conn, 409, "exists")
    end)

    Bypass.expect_once(c.bypass, "GET", "/calendars/primary/events/eval123", fn conn ->
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer bound-account"]

      json(conn, %{
        "id" => "eval123",
        "summary" => "Eval",
        "status" => "confirmed",
        "attendees" => [],
        "start" => %{"dateTime" => "2026-09-16T14:00:00Z"},
        "end" => %{"dateTime" => "2026-09-16T14:30:00Z"},
        "extendedProperties" => %{"private" => %{"maraithon_client_key" => "eval123"}}
      })
    end)

    assert {:error, :calendar_event_id_conflict} =
             GoogleCalendar.create_event(c.user_id, %{
               account_id: c.account.id,
               client_event_id: "eval123",
               summary: "Eval",
               start: ~U[2026-09-16 14:00:00Z],
               end: ~U[2026-09-16 14:30:00Z],
               timezone: "America/Toronto",
               attendees: ["kent.fenwick@gmail.com"]
             })
  end

  test "creation invites the exact Kent address and returns a durable event receipt", context do
    Bypass.expect_once(context.bypass, "POST", "/calendars/primary/events", fn conn ->
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer bound-account"]
      conn = Plug.Conn.fetch_query_params(conn)
      assert conn.query_params["sendUpdates"] == "all"
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      body = Jason.decode!(raw)
      assert body["attendees"] == [%{"email" => "kent.fenwick@gmail.com"}]
      json(conn, Map.merge(body, %{"status" => "confirmed"}))
    end)

    assert {:ok,
            %{event_id: "eval123", event: %{attendees: [%{email: "kent.fenwick@gmail.com"}]}}} =
             Maraithon.Tools.CalendarCreateEvent.execute(%{
               "user_id" => context.user_id,
               "account_id" => context.account.id,
               "title" => "Maraithon eval",
               "client_event_id" => "eval123",
               "start_at" => "2026-09-16T14:00:00Z",
               "end_at" => "2026-09-16T14:30:00Z",
               "timezone" => "America/Toronto",
               "attendees" => ["kent.fenwick@gmail.com"]
             })
  end

  defp json(conn, body),
    do:
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(body))
end
