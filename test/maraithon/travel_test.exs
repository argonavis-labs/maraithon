defmodule Maraithon.TravelTest do
  use Maraithon.DataCase, async: false

  import Ecto.Query

  alias Maraithon.Accounts
  alias Maraithon.Agents
  alias Maraithon.Briefs
  alias Maraithon.Briefs.Brief
  alias Maraithon.ConnectedAccounts
  alias Maraithon.OAuth
  alias Maraithon.Repo
  alias Maraithon.TelegramAssistant.Context
  alias Maraithon.TelegramConversations.{Conversation, Turn}
  alias Maraithon.TestSupport.{CapturingTelegram, TravelCalendarStub, TravelGmailStub}
  alias Maraithon.Travel

  setup do
    original_insights = Application.get_env(:maraithon, :insights, [])
    original_briefs = Application.get_env(:maraithon, :briefs, [])
    original_assistant = Application.get_env(:maraithon, :telegram_assistant, [])
    original_travel = Application.get_env(:maraithon, :travel, [])
    original_gmail_stub = Application.get_env(:maraithon, TravelGmailStub, [])
    original_calendar_stub = Application.get_env(:maraithon, TravelCalendarStub, [])

    Application.put_env(
      :maraithon,
      :insights,
      Keyword.merge(original_insights, telegram_module: CapturingTelegram)
    )

    Application.put_env(
      :maraithon,
      :briefs,
      Keyword.merge(original_briefs, telegram_module: CapturingTelegram)
    )

    Application.put_env(
      :maraithon,
      :telegram_assistant,
      Keyword.merge(original_assistant,
        telegram_full_chat_enabled: true,
        telegram_unified_push_enabled: true,
        proactive_delivery_planner_enabled: false
      )
    )

    Application.put_env(
      :maraithon,
      :travel,
      Keyword.merge(original_travel,
        gmail_module: TravelGmailStub,
        calendar_module: TravelCalendarStub
      )
    )

    on_exit(fn ->
      Application.put_env(:maraithon, :insights, original_insights)
      Application.put_env(:maraithon, :briefs, original_briefs)
      Application.put_env(:maraithon, :telegram_assistant, original_assistant)
      Application.put_env(:maraithon, :travel, original_travel)
      Application.put_env(:maraithon, TravelGmailStub, original_gmail_stub)
      Application.put_env(:maraithon, TravelCalendarStub, original_calendar_stub)
    end)

    start_supervised!(%{
      id: :capturing_telegram_recorder,
      start: {Agent, :start_link, [fn -> [] end, [name: :capturing_telegram_recorder]]}
    })

    start_supervised!(%{
      id: :capturing_apns_recorder,
      start: {Agent, :start_link, [fn -> [] end, [name: :capturing_apns_recorder]]}
    })

    user_id = "travel-user@example.com"
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

    {:ok, agent} =
      Agents.create_agent(%{
        user_id: user_id,
        behavior: "personal_assistant_agent",
        config: %{"name" => "Travel concierge"}
      })

    {:ok, _google_token} =
      OAuth.store_tokens(user_id, "google", %{
        access_token: "travel-google-token",
        scopes: ["gmail", "calendar"]
      })

    {:ok, _telegram} =
      ConnectedAccounts.upsert_manual(user_id, "telegram", %{
        external_account_id: "777123",
        metadata: %{"chat_id" => "777123", "username" => "travel-user"}
      })

    now = ~U[2026-03-14 22:00:00Z]
    TravelGmailStub.configure(messages: gmail_messages(now), contents: gmail_contents(now))
    TravelCalendarStub.configure(events: calendar_events())

    %{agent: agent, now: now, user_id: user_id}
  end

  test "syncs travel evidence, records a day-before brief, and carries itinerary context into Telegram",
       %{
         agent: agent,
         now: now,
         user_id: user_id
       } do
    assert {:ok, %{scanned_messages: 2, queued_briefs: [queued_brief], itineraries: [_itinerary]}} =
             Travel.sync_recent_trip_data(user_id, agent.id, now: now, timezone_offset_hours: -5)

    [itinerary] = Travel.list_recent_for_user(user_id)

    assert itinerary.status == "ready"
    assert itinerary.destination_label == "Austin"
    assert itinerary.briefed_for_local_date == nil
    assert Enum.sort(Enum.map(itinerary.items, & &1.item_type)) == ["flight", "hotel"]

    recorded_brief = Repo.get!(Brief, queued_brief.id)
    assert recorded_brief.cadence == "travel_prep"
    assert recorded_brief.metadata["travel_itinerary_id"] == itinerary.id
    assert recorded_brief.metadata["brief_type"] == "travel_prep"
    assert recorded_brief.body =~ "Here are your travel details for tomorrow (Mar 15)"
    assert recorded_brief.body =~ "FLIGHT"
    assert recorded_brief.body =~ "HOTEL"
    assert recorded_brief.body =~ "Austin Marriott Downtown"

    assert {:ok, %{queued_briefs: []}} =
             Travel.sync_recent_trip_data(user_id, agent.id, now: now, timezone_offset_hours: -5)

    Maraithon.TestSupport.CapturingAPNS.enable(user_id)
    result = Briefs.dispatch_pending_batch(batch_size: 10, now: now)
    assert result.sent == 1

    itinerary = Travel.list_recent_for_user(user_id) |> List.first()
    assert itinerary.status == "brief_sent"
    assert itinerary.briefed_for_local_date == ~D[2026-03-15]

    # Delivery is a phone push now: the banner is the doorbell, the itinerary
    # details live on the brief the app renders.
    assert [%{payload: payload}] = Maraithon.TestSupport.CapturingAPNS.recorded()
    assert payload["aps"]["alert"]["title"] == Briefs.public_title(recorded_brief)
    assert payload["deeplink"] == "maraithon://today"
  end

  test "queues a travel update when Gmail evidence changes after the initial brief is sent", %{
    agent: agent,
    now: now,
    user_id: user_id
  } do
    assert {:ok, %{queued_briefs: [_brief]}} =
             Travel.sync_recent_trip_data(user_id, agent.id, now: now, timezone_offset_hours: -5)

    Maraithon.TestSupport.CapturingAPNS.enable(user_id)
    result = Briefs.dispatch_pending_batch(batch_size: 10, now: now)
    assert result.sent == 1

    updated_contents =
      gmail_contents(now, hotel_room: "Suite 1108", hotel_check_out: "Mar 18, 2026")

    TravelGmailStub.configure(messages: gmail_messages(now), contents: updated_contents)

    assert {:ok, %{queued_briefs: [update_brief]}} =
             Travel.sync_recent_trip_data(user_id, agent.id,
               now: DateTime.add(now, 5, :minute),
               timezone_offset_hours: -5
             )

    itinerary = Travel.list_recent_for_user(user_id) |> List.first()
    assert itinerary.status == "changed_after_send"

    recorded_update = Repo.get!(Brief, update_brief.id)
    assert recorded_update.cadence == "travel_update"
    assert recorded_update.metadata["brief_type"] == "travel_update"
    assert recorded_update.metadata["travel_itinerary_id"] == itinerary.id
    assert recorded_update.body =~ "Travel details changed. Current itinerary:"
    assert recorded_update.body =~ "Check-out: Mar 18, 2026"
    assert recorded_update.body =~ "Room: Suite 1108"
    refute recorded_update.body =~ "I detected"
    refute recorded_update.body =~ "I found"

    result = Briefs.dispatch_pending_batch(batch_size: 10, now: now)
    assert result.sent == 1

    assert [_first, %{payload: update_payload}] =
             Maraithon.TestSupport.CapturingAPNS.recorded()

    assert update_payload["aps"]["alert"]["title"] == Briefs.public_title(recorded_update)

    itinerary = Travel.list_recent_for_user(user_id) |> List.first()
    assert itinerary.status == "brief_sent"
  end

  test "sends immediately with today wording if the itinerary is first discovered on travel day before departure",
       %{
         agent: agent,
         user_id: user_id
       } do
    now = ~U[2026-03-15 13:00:00Z]
    TravelGmailStub.configure(messages: gmail_messages(now), contents: gmail_contents(now))

    assert {:ok, %{queued_briefs: [queued_brief]}} =
             Travel.sync_recent_trip_data(user_id, agent.id, now: now, timezone_offset_hours: -5)

    recorded_brief = Repo.get!(Brief, queued_brief.id)
    assert recorded_brief.title == "Travel today: Austin"
    assert recorded_brief.body =~ "Here are your travel details for today (Mar 15)"

    Maraithon.TestSupport.CapturingAPNS.enable(user_id)
    result = Briefs.dispatch_pending_batch(batch_size: 10, now: now)
    assert result.sent == 1

    assert [%{payload: payload}] = Maraithon.TestSupport.CapturingAPNS.recorded()
    assert payload["aps"]["alert"]["title"] == "Travel today: Austin"
  end

  test "consumes a shared chief-of-staff source bundle and stamps assistant metadata", %{
    agent: agent,
    now: now,
    user_id: user_id
  } do
    TravelGmailStub.configure(messages: [], contents: gmail_contents(now))
    TravelCalendarStub.configure(events: [])

    source_bundle = %{
      "gmail" => %{"messages" => gmail_messages(now)},
      "calendar" => %{"events" => calendar_events()}
    }

    assistant_context = %{
      assistant_cycle_id: "cycle-123",
      assistant_origin_skill_id: "travel_logistics",
      assistant_origin_skill_rank: 2,
      assistant_fetch_telemetry: %{"sources" => %{"gmail" => %{"status" => "ready"}}}
    }

    assert {:ok, %{queued_briefs: [queued_brief]}} =
             Travel.sync_recent_trip_data(user_id, agent.id,
               now: now,
               timezone_offset_hours: -5,
               source_bundle: source_bundle,
               assistant_context: assistant_context
             )

    recorded_brief = Repo.get!(Brief, queued_brief.id)
    assert recorded_brief.metadata["assistant_cycle_id"] == "cycle-123"
    assert recorded_brief.metadata["origin_skill_id"] == "travel_logistics"
    assert recorded_brief.metadata["arbitration_rank"] == 2
  end

  test "requires calendar access at runtime", %{agent: agent, now: now, user_id: user_id} do
    {:ok, _google_token} =
      OAuth.store_tokens(user_id, "google", %{
        access_token: "travel-google-token",
        scopes: ["gmail"]
      })

    assert {:error, :calendar_not_connected} =
             Travel.sync_recent_trip_data(user_id, agent.id, now: now, timezone_offset_hours: -5)
  end

  test "plans the send time based on the trip start hour" do
    assert Travel.planned_brief_at(~U[2026-03-15 12:00:00Z], -5) == ~U[2026-03-14 23:00:00Z]
    assert Travel.planned_brief_at(~U[2026-03-15 17:00:00Z], -5) == ~U[2026-03-14 21:00:00Z]
    assert Travel.planned_brief_at(~U[2026-03-16 01:00:00Z], -5) == ~U[2026-03-14 17:00:00Z]
  end

  defp telegram_events(type) do
    :capturing_telegram_recorder
    |> Agent.get(& &1)
    |> Enum.filter(&(&1.type == type))
  end

  defp gmail_messages(now) do
    [
      %{
        message_id: "flight-msg-1",
        thread_id: "travel-thread-1",
        subject: "Your flight to Austin is confirmed",
        snippet:
          "Air Canada flight AC 123 Toronto YYZ -> Austin AUS Mar 15, 2026 at 2:00 PM Booking Ref ABC123",
        from: "Air Canada <noreply@aircanada.com>",
        internal_date: DateTime.add(now, -3, :hour)
      },
      %{
        message_id: "hotel-msg-1",
        thread_id: "travel-thread-2",
        subject: "Austin Marriott Downtown reservation confirmed",
        snippet:
          "Hotel reservation with check-in Mar 15, 2026 and check-out Mar 17, 2026. Itinerary H98765.",
        from: "Austin Marriott Downtown <reservations@marriott.com>",
        internal_date: DateTime.add(now, -2, :hour)
      }
    ]
  end

  defp gmail_contents(now, opts \\ []) do
    hotel_room = Keyword.get(opts, :hotel_room, "King Room")
    hotel_check_out = Keyword.get(opts, :hotel_check_out, "Mar 17, 2026")

    %{
      "flight-msg-1" => %{
        "message_id" => "flight-msg-1",
        "thread_id" => "travel-thread-1",
        "subject" => "Your flight to Austin is confirmed",
        "snippet" =>
          "Air Canada flight AC 123 Toronto YYZ -> Austin AUS Mar 15, 2026 at 2:00 PM Booking Ref ABC123",
        "from" => "Air Canada <noreply@aircanada.com>",
        "internal_date" => DateTime.add(now, -3, :hour),
        "text_body" => """
        Air Canada
        AC 123
        Toronto YYZ -> Austin AUS
        Departure: Mar 15, 2026 at 2:00 PM
        Booking Ref: ABC123
        """
      },
      "hotel-msg-1" => %{
        "message_id" => "hotel-msg-1",
        "thread_id" => "travel-thread-2",
        "subject" => "Austin Marriott Downtown reservation confirmed",
        "snippet" =>
          "Hotel reservation with check-in Mar 15, 2026 and check-out #{hotel_check_out}. Itinerary H98765.",
        "from" => "Austin Marriott Downtown <reservations@marriott.com>",
        "internal_date" => DateTime.add(now, -2, :hour),
        "text_body" => """
        Austin Marriott Downtown
        304 East Cesar Chavez St, Austin, TX 78701
        Check-in: Mar 15, 2026
        Check-out: #{hotel_check_out}
        Room: #{hotel_room}
        Hotel Phone: 512-555-1212
        Itinerary #: H98765
        """
      }
    }
  end

  defp calendar_events do
    [
      %{
        event_id: "event-austin-1",
        summary: "Austin work trip",
        description: "Travel to Austin for meetings and hotel stay",
        location: "Austin",
        status: "confirmed",
        start: ~U[2026-03-15 19:00:00Z],
        end: ~U[2026-03-17 16:00:00Z]
      }
    ]
  end
end
