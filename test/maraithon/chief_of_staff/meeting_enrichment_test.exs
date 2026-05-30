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

    assert Enum.any?(meeting["web_context"], &(&1["query"] == "Dawn Nguyen cogniate.com"))
    assert Enum.any?(meeting["web_context"], &(&1["query"] == "Cogniate cogniate.com"))
    refute Enum.any?(meeting["web_context"], &String.contains?(&1["query"], "Charlie Feng"))

    assert Enum.any?(meeting["data_gaps"], &String.contains?(&1, "Dawn Nguyen"))
    assert_received {:web_search, "Dawn Nguyen cogniate.com", [limit: 10]}
    assert_received {:web_search, "Cogniate cogniate.com", [limit: 10]}
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
      MeetingEnrichment.enrich(user_id, reminder_blocks ++ [dawn_meeting],
        max_web_queries: 0,
        internal_email_domains: ["runner.now"]
      )

    summaries = Enum.map(result["meetings"], & &1["summary"])

    assert "Dawn Nguyen and Charlie Feng" in summaries
    assert get_in(result, ["counts", "meetings"]) == 11
    assert get_in(result, ["counts", "required_schedule_meetings"]) == 1

    assert Enum.any?(result["meetings"], fn meeting ->
             meeting["summary"] == "Dawn Nguyen and Charlie Feng" and
               meeting["schedule_required"] == true and
               Enum.any?(meeting["external_attendees"], &(&1["email"] == "dawn@kilnstudio.io"))
           end)
  end

  test "does not bake tenant-specific internal domains into meeting prep", %{user_id: user_id} do
    event = %{
      "event_id" => "evt-runner",
      "summary" => "Charlie Feng planning",
      "start" => "2026-05-11T19:00:00Z",
      "end" => "2026-05-11T19:30:00Z",
      "attendees" => [
        %{"display_name" => "Charlie Feng", "email" => "charlie@runner.now"}
      ]
    }

    default_result = MeetingEnrichment.enrich(user_id, [event], max_web_queries: 0)
    [default_meeting] = default_result["meetings"]

    assert default_meeting["schedule_required"] == true

    assert Enum.any?(
             default_meeting["external_attendees"],
             &(&1["email"] == "charlie@runner.now")
           )

    assert Enum.any?(
             default_meeting["candidate_people_and_orgs"],
             &(&1["query"] == "Runner")
           )

    configured_result =
      MeetingEnrichment.enrich(user_id, [event],
        max_web_queries: 0,
        internal_email_domains: ["runner.now"]
      )

    [configured_meeting] = configured_result["meetings"]

    assert configured_meeting["schedule_required"] == false
    assert Map.get(configured_meeting, "external_attendees", []) == []
  end

  test "spends scarce public prep budget on the earliest required external meeting while preserving calendar order",
       %{user_id: user_id} do
    parent = self()

    web_search = fn query, opts ->
      send(parent, {:web_search, query, opts})
      {:ok, %{"results" => []}}
    end

    page_fetch = fn url, opts ->
      send(parent, {:page_fetch, url, opts})
      {:error, :not_needed}
    end

    later_meeting = %{
      "event_id" => "evt-later",
      "summary" => "Nolan Park partnership review",
      "start" => "2026-05-11T21:00:00Z",
      "end" => "2026-05-11T21:30:00Z",
      "attendees" => [
        %{"display_name" => "Nolan Park", "email" => "nolan@laterco.com"}
      ]
    }

    earlier_meeting = %{
      "event_id" => "evt-earlier",
      "summary" => "Mira Shah investor prep",
      "start" => "2026-05-11T14:00:00Z",
      "end" => "2026-05-11T14:30:00Z",
      "attendees" => [
        %{"display_name" => "Mira Shah", "email" => "mira@priorityco.com"}
      ]
    }

    result =
      MeetingEnrichment.enrich(user_id, [later_meeting, earlier_meeting],
        web_search_fun: web_search,
        web_page_fetch_fun: page_fetch,
        max_web_queries: 1
      )

    assert Enum.map(result["meetings"], & &1["event_id"]) == ["evt-later", "evt-earlier"]
    assert get_in(result, ["counts", "required_schedule_meetings"]) == 2
    assert get_in(result, ["counts", "web_searches"]) == 1

    later = Enum.find(result["meetings"], &(&1["event_id"] == "evt-later"))
    earlier = Enum.find(result["meetings"], &(&1["event_id"] == "evt-earlier"))

    assert later["schedule_required"] == true
    assert earlier["schedule_required"] == true
    assert (later["web_context"] || []) == []
    assert Enum.any?(earlier["web_context"], &(&1["query"] == "Mira Shah priorityco.com"))

    assert_received {:web_search, "Mira Shah priorityco.com", [limit: 10]}
    assert_received {:page_fetch, "https://priorityco.com/", [text_limit: 20000]}
    refute_received {:web_search, "Nolan Park laterco.com", _opts}
  end

  test "web search failures stay executive-safe in meeting prep context", %{user_id: user_id} do
    raw_reason =
      {:transport, "clientError(status: 500, body: SECRET_STACKTRACE public web lookup blew up)"}

    web_search = fn _query, _opts ->
      {:error, raw_reason}
    end

    page_fetch = fn _url, _opts ->
      {:error, "SECRET_PAGE_STACKTRACE"}
    end

    event = %{
      "event_id" => "evt-dawn",
      "summary" => "Dawn Nguyen intro",
      "start" => "2026-05-11T19:00:00Z",
      "end" => "2026-05-11T19:30:00Z",
      "attendees" => [
        %{"display_name" => "Dawn Nguyen", "email" => "dawn@kilnstudio.io"}
      ]
    }

    result =
      MeetingEnrichment.enrich(user_id, [event],
        web_search_fun: web_search,
        web_page_fetch_fun: page_fetch,
        max_web_queries: 1
      )

    [meeting] = result["meetings"]
    [web_context] = meeting["web_context"]

    assert web_context["status"] == "error"
    assert web_context["error"] == "Public sources were unavailable."

    serialized_meeting = inspect(meeting)
    refute serialized_meeting =~ "SECRET_STACKTRACE"
    refute serialized_meeting =~ "clientError"
    refute serialized_meeting =~ "lookup blew up"

    data_gaps = meeting["data_gaps"]
    refute Enum.any?(data_gaps, &(String.downcase(&1) =~ "fallback"))
    assert Enum.any?(data_gaps, &(&1 =~ "Public sources were unavailable"))
    assert Enum.any?(data_gaps, &(&1 =~ "avoid inventing background"))
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

    page_fetch = fn url, opts ->
      send(parent, {:page_fetch, url, opts})

      {:ok,
       %{
         "url" => url,
         "title" => "Kiln Studio",
         "description" => "AI adoption, made practical",
         "text" =>
           "Solo AI Ops & Automation consultancy. Workshops and training on AI tools, agents, and automation. Scoped agent builds start at $5K. Dawn Nguyen's background includes IBM Watson, LogicGate, and Hyde Park Venture Partners."
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
        web_page_fetch_fun: page_fetch,
        max_web_queries: 8,
        internal_email_domains: ["runner.now"]
      )

    assert get_in(result, ["counts", "required_schedule_meetings"]) == 1
    assert get_in(result, ["counts", "web_searches"]) == 2
    assert get_in(result, ["counts", "web_pages"]) == 4

    school = Enum.find(result["meetings"], &(&1["event_id"] == "evt-school"))
    soccer = Enum.find(result["meetings"], &(&1["event_id"] == "evt-soccer"))
    dawn = Enum.find(result["meetings"], &(&1["event_id"] == "evt-dawn"))

    assert school["schedule_required"] == false
    assert soccer["schedule_required"] == false
    assert dawn["schedule_required"] == true

    assert Enum.any?(dawn["web_context"], &(&1["query"] == "Dawn Nguyen kilnstudio.io"))
    assert Enum.any?(dawn["web_context"], &(&1["query"] == "Kiln Studio kilnstudio.io"))

    assert Enum.any?(dawn["web_context"], fn context ->
             Enum.any?(context["page_contexts"] || [], fn page ->
               page["title"] == "Kiln Studio" and
                 page["text"] =~ "Scoped agent builds start at $5K"
             end)
           end)

    assert_received {:web_search, "Dawn Nguyen kilnstudio.io", [limit: 10]}
    assert_received {:web_search, "Kiln Studio kilnstudio.io", [limit: 10]}
    assert_received {:page_fetch, "https://kilnstudio.io/", [text_limit: 20000]}
    refute_received {:web_search, "Coach School", _opts}
    refute_received {:web_search, "School company", _opts}
    refute_received {:web_search, "Coach Club Soccer", _opts}
    refute_received {:web_search, "Club Soccer company", _opts}
  end
end
