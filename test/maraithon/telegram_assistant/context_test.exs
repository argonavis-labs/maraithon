defmodule Maraithon.TelegramAssistant.ContextTest do
  use Maraithon.DataCase, async: false

  alias Maraithon.Accounts
  alias Maraithon.ConnectedAccounts
  alias Maraithon.LocalCalendar
  alias Maraithon.OAuth
  alias Maraithon.TelegramAssistant.Context

  describe "connected account prompt context" do
    test "uses account labels without raw provider identifiers or scopes" do
      user_id = "context-connected-#{System.unique_integer([:positive])}@example.com"
      {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

      {:ok, _telegram} =
        ConnectedAccounts.upsert_manual(user_id, "telegram", %{
          external_account_id: "6114124042",
          metadata: %{"chat_id" => "6114124042", "username" => "kentfenwick"}
        })

      {:ok, _google} =
        ConnectedAccounts.upsert_manual(user_id, "google", %{
          external_account_id: "google-account-raw",
          scopes: ["gmail.readonly"],
          metadata: %{"account_email" => "founder@example.com"}
        })

      {:ok, _slack} =
        ConnectedAccounts.upsert_manual(user_id, "slack:TSECRET123", %{
          external_account_id: "TSECRET123",
          scopes: ["search:read"],
          metadata: %{"team_id" => "TSECRET123", "team_name" => "Executive Ops"}
        })

      {:ok, _slack_token} =
        OAuth.store_tokens(user_id, "slack:TSECRET123:user:USECRET", %{
          access_token: "slack-token",
          scopes: ["channels:history"],
          metadata: %{"team_id" => "TSECRET123", "team_name" => "Executive Ops"}
        })

      context =
        Context.build(%{user_id: user_id, chat_id: "12345", request_focus: :connector_status})

      providers = Enum.map(context.connected_accounts, & &1.provider)
      assert "google" in providers
      assert "slack" in providers
      assert "telegram" in providers

      assert %{account_label: "Telegram"} =
               Enum.find(context.connected_accounts, &(&1.provider == "telegram"))

      assert %{account_label: "founder@example.com"} =
               Enum.find(context.connected_accounts, &(&1.provider == "google"))

      assert %{account_label: "Executive Ops"} =
               Enum.find(context.connected_accounts, &(&1.provider == "slack"))

      connected_account_text = inspect(context.connected_accounts)
      refute connected_account_text =~ "external_account_id"
      refute connected_account_text =~ "metadata"
      refute connected_account_text =~ "scopes"
      refute connected_account_text =~ "chat_id"
      refute connected_account_text =~ "team_id"
      refute connected_account_text =~ "6114124042"
      refute connected_account_text =~ "TSECRET123"
      refute connected_account_text =~ "USECRET"
      refute connected_account_text =~ "google-account-raw"
      refute connected_account_text =~ "gmail.readonly"
      refute connected_account_text =~ "search:read"
      refute connected_account_text =~ "channels:history"

      assert "slack" in context.defaults.providers

      defaults_text = inspect(context.defaults)
      refute Map.has_key?(context.defaults, :default_slack_team_id)
      refute Map.has_key?(context.defaults, :slack_team_ids)
      refute Map.has_key?(context.defaults, :provider_ids)
      refute defaults_text =~ "TSECRET123"
      refute defaults_text =~ "USECRET"
      refute defaults_text =~ "channels:history"
    end
  end

  describe "calendar source status" do
    test "does not classify business campaign calendar events as family camp logistics" do
      user_id = "context-calendar-personal-#{System.unique_integer([:positive])}@example.com"
      device_id = Ecto.UUID.generate()
      {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

      start_at =
        DateTime.utc_now()
        |> DateTime.add(2, :hour)
        |> DateTime.truncate(:second)

      end_at = DateTime.add(start_at, 30, :minute)

      {:ok, _result} =
        LocalCalendar.ingest_batch(user_id, device_id, [
          calendar_event("campaign-review", start_at, end_at, %{
            "calendar_name" => "Work",
            "title" => "Starteryou UGC Campaign Review",
            "notes" => "Review campaign materials and asset ownership."
          }),
          calendar_event(
            "camp-pickup",
            DateTime.add(start_at, 1, :hour),
            DateTime.add(end_at, 1, :hour),
            %{
              "calendar_name" => "Work",
              "title" => "Emma camp pickup",
              "notes" => "Confirm pickup window with the camp coordinator."
            }
          )
        ])

      context = Context.build(%{user_id: user_id, chat_id: "12345", request_focus: :today_mode})

      upcoming_summaries = Enum.map(context.calendar.upcoming_events, & &1.summary)
      personal_summaries = Enum.map(context.calendar.personal_events, & &1.summary)

      assert "Starteryou UGC Campaign Review" in upcoming_summaries
      assert "Emma camp pickup" in upcoming_summaries
      refute "Starteryou UGC Campaign Review" in personal_summaries
      assert "Emma camp pickup" in personal_summaries
      assert context.calendar.counts.personal == 1
    end

    test "uses user-safe copy when Google Calendar is not connected" do
      user_id = "context-calendar-status-#{System.unique_integer([:positive])}@example.com"
      {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

      context = Context.build(%{user_id: user_id, chat_id: "12345", request_focus: :today_mode})

      assert context.calendar.source_status.local == "empty"
      assert context.calendar.source_status.google == "not connected"
      refute calendar_status_text(context) =~ ":no_token"
      refute calendar_status_text(context) =~ "error:"
    end

    test "does not expose Google API response bodies in prompt-facing status" do
      original_google_calendar = Application.get_env(:maraithon, :google_calendar, [])
      bypass = Bypass.open()

      Application.put_env(:maraithon, :google_calendar,
        api_base_url: "http://localhost:#{bypass.port}/calendar/v3"
      )

      on_exit(fn ->
        Application.put_env(:maraithon, :google_calendar, original_google_calendar)
      end)

      user_id = "context-calendar-http-#{System.unique_integer([:positive])}@example.com"
      {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

      {:ok, _token} =
        OAuth.store_tokens(user_id, "google", %{
          access_token: "calendar-token",
          scopes: ["calendar.readonly"]
        })

      Bypass.expect_once(bypass, "GET", "/calendar/v3/calendars/primary/events", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(500, Jason.encode!(%{"error" => "internal_stacktrace: db_timeout"}))
      end)

      context = Context.build(%{user_id: user_id, chat_id: "12345", request_focus: :today_mode})

      assert context.calendar.source_status.google == "temporarily unavailable"
      refute calendar_status_text(context) =~ "internal_stacktrace"
      refute calendar_status_text(context) =~ "db_timeout"
      refute calendar_status_text(context) =~ "500"
    end
  end

  describe "context fetch diagnostics" do
    test "summarizes crashed source fetches without leaking provider internals" do
      context =
        Context.safe_parallel_fetch(
          [
            gmail: fn ->
              raise RuntimeError,
                    "gmail 500 internal_stacktrace token=sk-live-secret db_timeout"
            end,
            notes: fn ->
              throw({:provider_error, "raw Apple Notes path /Users/kent/Library/secret"})
            end,
            messages: fn ->
              exit({:shutdown, "private iMessage database handle"})
            end
          ],
          defaults: %{gmail: [], notes: [], messages: []},
          timeout_ms: 1_000,
          max_concurrency: 3
        )

      assert context.context_fetch.status == "degraded"

      assert Enum.map(context.context_fetch.failures, & &1.reason) == [
               "temporarily unavailable",
               "temporarily unavailable",
               "interrupted"
             ]

      diagnostics = inspect(context.context_fetch.failures)
      refute diagnostics =~ "internal_stacktrace"
      refute diagnostics =~ "sk-live-secret"
      refute diagnostics =~ "/Users/kent"
      refute diagnostics =~ "iMessage database"
    end
  end

  defp calendar_status_text(context) do
    context.calendar.source_status
    |> inspect()
  end

  defp calendar_event(guid, start_at, end_at, overrides) do
    Map.merge(
      %{
        "local_id" => "evt:#{guid}",
        "guid" => guid,
        "calendar_name" => "Work",
        "title" => "Planning review",
        "notes" => nil,
        "location" => nil,
        "start_at" => DateTime.to_iso8601(start_at),
        "end_at" => DateTime.to_iso8601(end_at),
        "is_all_day" => false,
        "is_recurring" => false,
        "organizer_email" => "kent@example.com",
        "attendees_count" => 1,
        "attendee_emails" => ["kent@example.com"],
        "created_at" => DateTime.to_iso8601(DateTime.add(start_at, -1, :day)),
        "modified_at" => DateTime.to_iso8601(DateTime.add(start_at, -1, :hour))
      },
      overrides
    )
  end
end
