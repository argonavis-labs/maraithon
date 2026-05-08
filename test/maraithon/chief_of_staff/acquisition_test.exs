defmodule Maraithon.ChiefOfStaff.AcquisitionTest do
  use Maraithon.DataCase, async: false

  alias Maraithon.ChiefOfStaff.{Acquisition, SourceBundle}
  alias Maraithon.TestSupport.{NewsStub, TravelCalendarStub, TravelGmailStub}

  setup do
    original_config = Application.get_env(:maraithon, Acquisition, [])
    original_gmail_stub = Application.get_env(:maraithon, TravelGmailStub, [])
    original_calendar_stub = Application.get_env(:maraithon, TravelCalendarStub, [])

    Application.put_env(
      :maraithon,
      Acquisition,
      Keyword.merge(original_config,
        gmail_module: TravelGmailStub,
        calendar_module: TravelCalendarStub,
        news_module: NewsStub
      )
    )

    on_exit(fn ->
      Application.put_env(:maraithon, Acquisition, original_config)
      Application.put_env(:maraithon, TravelGmailStub, original_gmail_stub)
      Application.put_env(:maraithon, TravelCalendarStub, original_calendar_stub)
    end)

    :ok
  end

  test "builds one shared gmail and calendar bundle for overlapping skills" do
    now = ~U[2026-04-02 13:00:00Z]

    TravelGmailStub.configure(
      messages: [
        %{
          message_id: "msg-1",
          thread_id: "thread-1",
          subject: "Customer ask",
          labels: ["INBOX"],
          internal_date: now
        },
        %{
          message_id: "msg-2",
          thread_id: "thread-2",
          subject: "Sent update",
          labels: ["SENT"],
          internal_date: DateTime.add(now, -1, :hour)
        }
      ]
    )

    TravelCalendarStub.configure(
      events: [
        %{
          event_id: "evt-1",
          summary: "Project sync",
          start: DateTime.add(now, 4, :hour),
          end: DateTime.add(now, 5, :hour)
        }
      ]
    )

    source_scope = %{
      "google_accounts" => [
        %{
          "provider" => "google:shared@example.com",
          "account_email" => "shared@example.com",
          "services" => ["gmail", "calendar"]
        }
      ]
    }

    skill_configs = %{
      "followthrough" => %{
        "source_scope" => source_scope,
        "email_scan_limit" => 10,
        "event_scan_limit" => 12,
        "lookback_hours" => 48
      },
      "travel_logistics" => %{
        "source_scope" => source_scope,
        "email_scan_limit" => 25,
        "event_scan_limit" => 25,
        "lookback_hours" => 24 * 30
      }
    }

    context = %{
      agent_id: "chief-agent-1",
      user_id: "chief@example.com",
      timestamp: now,
      budget: %{llm_calls: 10, tool_calls: 10},
      recent_events: [],
      trigger: %{type: :wakeup, job_type: "wakeup"},
      event: nil
    }

    {bundle, telemetry} =
      Acquisition.build(
        "chief@example.com",
        ["followthrough", "travel_logistics"],
        skill_configs,
        context
      )

    assert length(SourceBundle.gmail_messages(bundle)) == 2
    assert length(SourceBundle.gmail_inbox_messages(bundle)) == 1
    assert length(SourceBundle.gmail_sent_messages(bundle)) == 1
    assert length(SourceBundle.calendar_events(bundle)) == 1
    assert get_in(telemetry, ["sources", "gmail", "status"]) == "ready"
    assert get_in(telemetry, ["sources", "calendar", "status"]) == "ready"
  end

  test "adds configured news to the morning briefing source bundle" do
    now = ~U[2026-05-08 12:00:00Z]

    skill_configs = %{
      "morning_briefing" => %{
        "news_enabled" => true,
        "news_feeds" => [
          %{"name" => "Test News", "url" => "https://example.com/rss.xml"}
        ]
      }
    }

    context = %{
      agent_id: "chief-agent-news",
      user_id: "chief@example.com",
      timestamp: now,
      budget: %{llm_calls: 10, tool_calls: 10},
      recent_events: [],
      trigger: %{type: :wakeup, job_type: "wakeup"},
      event: nil
    }

    {bundle, telemetry} =
      Acquisition.build("chief@example.com", ["morning_briefing"], skill_configs, context)

    [item] = SourceBundle.news_items(bundle)
    assert item["title"] =~ "Slack launches"
    assert get_in(telemetry, ["sources", "news", "status"]) == "ready"
    assert get_in(telemetry, ["sources", "news", "item_count"]) == 1
  end
end
