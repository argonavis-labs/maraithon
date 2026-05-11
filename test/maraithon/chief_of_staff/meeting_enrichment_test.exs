defmodule Maraithon.ChiefOfStaff.MeetingEnrichmentTest do
  use Maraithon.DataCase, async: true

  alias Maraithon.Accounts
  alias Maraithon.ChiefOfStaff.MeetingEnrichment
  alias Maraithon.Crm

  setup do
    user_id = "meeting-enrichment-#{System.unique_integer([:positive])}@example.com"
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)
    %{user_id: user_id}
  end

  test "uses CRM context first and searches the web for missing meeting details", %{
    user_id: user_id
  } do
    {:ok, _charlie} =
      Crm.upsert_person(user_id, %{
        "first_name" => "Charlie",
        "last_name" => "Feng",
        "email" => "charlie@runner.example",
        "relationship" => "Runner commercial teammate",
        "notes" => "Looped into enterprise pricing and availability guidance."
      })

    parent = self()

    web_search = fn query, opts ->
      send(parent, {:web_search, query, opts})

      {:ok,
       %{
         "results" => [
           %{
             "title" => "#{query} public profile",
             "url" => "https://example.com/search/#{URI.encode(query)}",
             "snippet" => "Public context for #{query}."
           }
         ]
       }}
    end

    event = %{
      "event_id" => "evt-reclaim",
      "summary" => "Reclaim: Dawn Nguyen and Charlie Feng - Cogniate plan",
      "start" => "2026-05-11T19:00:00Z",
      "end" => "2026-05-11T19:30:00Z",
      "attendees" => [
        %{"display_name" => "Dawn Nguyen", "email" => "dawn@cogniate.com"},
        %{"display_name" => "Charlie Feng", "email" => "charlie@runner.example"}
      ]
    }

    result =
      MeetingEnrichment.enrich(user_id, [event],
        web_search_fun: web_search,
        max_web_queries: 4
      )

    assert get_in(result, ["counts", "meetings"]) == 1
    assert get_in(result, ["counts", "required_schedule_meetings"]) == 1
    assert get_in(result, ["counts", "crm_contexts"]) == 1
    assert get_in(result, ["counts", "web_searches"]) == 2

    [meeting] = result["meetings"]
    assert meeting["schedule_required"] == true
    assert meeting["briefing_priority"] == "required_external_meeting"
    assert meeting["briefing_reason"] =~ "must be covered"

    assert Enum.any?(meeting["external_attendees"], fn attendee ->
             attendee["display_name"] == "Dawn Nguyen" and
               attendee["email"] == "dawn@cogniate.com" and
               attendee["domain"] == "cogniate.com"
           end)

    [crm_context] = meeting["crm_context"]

    assert get_in(crm_context, ["person", "display_name"]) == "Charlie Feng"
    assert get_in(crm_context, ["person", "relationship"]) == "Runner commercial teammate"
    refute Map.has_key?(crm_context["person"], "id")
    refute Map.has_key?(crm_context["person"], "metadata")
    refute Map.has_key?(crm_context["person"], "inserted_at")

    assert Enum.any?(meeting["web_context"], &(&1["query"] == "Dawn Nguyen Cogniate"))
    assert Enum.any?(meeting["web_context"], &(&1["query"] == "Cogniate company"))
    refute Enum.any?(meeting["web_context"], &String.contains?(&1["query"], "Charlie Feng"))

    assert Enum.any?(meeting["data_gaps"], &String.contains?(&1, "Dawn Nguyen"))
    assert_received {:web_search, "Dawn Nguyen Cogniate", [limit: 3]}
    assert_received {:web_search, "Cogniate company", [limit: 3]}
  end

  test "keeps external attendee meetings when reminder-like calendar blocks fill the day", %{
    user_id: user_id
  } do
    reminder_blocks =
      for index <- 1..10 do
        %{
          "event_id" => "reminder-#{index}",
          "summary" => "Represent Studio follow-up #{index}",
          "start" => "2026-05-11T13:#{String.pad_leading(to_string(index), 2, "0")}:00Z",
          "end" => "2026-05-11T13:#{String.pad_leading(to_string(index + 1), 2, "0")}:00Z",
          "attendees" => []
        }
      end

    dawn_meeting = %{
      "event_id" => "evt-dawn",
      "summary" => "Dawn Nguyen and Charlie Feng",
      "start" => "2026-05-11T19:00:00Z",
      "end" => "2026-05-11T19:30:00Z",
      "attendees" => [
        %{"display_name" => "Dawn Nguyen", "email" => "dawn@kilnstudio.io"},
        %{"display_name" => "Charlie Feng", "email" => "charlie@runner.now"}
      ]
    }

    result =
      MeetingEnrichment.enrich(user_id, reminder_blocks ++ [dawn_meeting], max_web_queries: 0)

    summaries = Enum.map(result["meetings"], & &1["summary"])

    assert "Dawn Nguyen and Charlie Feng" in summaries
    assert get_in(result, ["counts", "meetings"]) == 10
    assert get_in(result, ["counts", "required_schedule_meetings"]) == 1

    assert Enum.any?(result["meetings"], fn meeting ->
             meeting["summary"] == "Dawn Nguyen and Charlie Feng" and
               meeting["schedule_required"] == true and
               Enum.any?(meeting["external_attendees"], &(&1["email"] == "dawn@kilnstudio.io"))
           end)
  end

  test "does not let personal logistics consume required-meeting web enrichment", %{
    user_id: user_id
  } do
    {:ok, _charlie} =
      Crm.upsert_person(user_id, %{
        "first_name" => "Charlie",
        "last_name" => "Feng",
        "email" => "charlie@runner.now",
        "relationship" => "Runner commercial teammate"
      })

    parent = self()

    web_search = fn query, opts ->
      send(parent, {:web_search, query, opts})

      {:ok,
       %{
         "results" => [
           %{
             "title" => "#{query} result",
             "url" => "https://example.com/#{URI.encode(query)}",
             "snippet" => "Public context for #{query}."
           }
         ]
       }}
    end

    school_meet = %{
      "event_id" => "evt-school",
      "summary" => "Emma/Frankie - school cross country meet",
      "start" => "2026-05-11T15:30:00Z",
      "end" => "2026-05-11T16:50:00Z",
      "calendar_name" => "Family",
      "attendees" => [
        %{"display_name" => "Coach", "email" => "coach@school.edu"},
        %{"display_name" => "Family", "email" => "family@gmail.com"}
      ]
    }

    soccer_practice = %{
      "event_id" => "evt-soccer",
      "summary" => "Emma Soccer Practice",
      "start" => "2026-05-11T22:00:00Z",
      "end" => "2026-05-11T23:00:00Z",
      "attendees" => [
        %{"display_name" => "Coach", "email" => "coach@club-soccer.org"}
      ]
    }

    dawn_meeting = %{
      "event_id" => "evt-dawn",
      "summary" => "Dawn Nguyen and Charlie Feng",
      "start" => "2026-05-11T19:00:00Z",
      "end" => "2026-05-11T19:30:00Z",
      "attendees" => [
        %{"display_name" => "Dawn Nguyen", "email" => "dawn@kilnstudio.io"},
        %{"display_name" => "Charlie Feng", "email" => "charlie@runner.now"}
      ]
    }

    result =
      MeetingEnrichment.enrich(user_id, [school_meet, dawn_meeting, soccer_practice],
        web_search_fun: web_search,
        max_web_queries: 8
      )

    assert get_in(result, ["counts", "required_schedule_meetings"]) == 1
    assert get_in(result, ["counts", "web_searches"]) == 2

    school = Enum.find(result["meetings"], &(&1["event_id"] == "evt-school"))
    soccer = Enum.find(result["meetings"], &(&1["event_id"] == "evt-soccer"))
    dawn = Enum.find(result["meetings"], &(&1["event_id"] == "evt-dawn"))

    assert school["schedule_required"] == false
    assert soccer["schedule_required"] == false
    assert dawn["schedule_required"] == true

    assert Enum.any?(dawn["web_context"], &(&1["query"] == "Dawn Nguyen Kilnstudio"))
    assert Enum.any?(dawn["web_context"], &(&1["query"] == "Kilnstudio company"))

    assert_received {:web_search, "Dawn Nguyen Kilnstudio", [limit: 3]}
    assert_received {:web_search, "Kilnstudio company", [limit: 3]}
    refute_received {:web_search, "Coach School", _opts}
    refute_received {:web_search, "School company", _opts}
    refute_received {:web_search, "Coach Club Soccer", _opts}
    refute_received {:web_search, "Club Soccer company", _opts}
  end
end
