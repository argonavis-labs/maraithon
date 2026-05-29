defmodule Maraithon.ChiefOfStaff.MeetingEnrichment do
  @moduledoc """
  CRM-first meeting prep enrichment for Chief of Staff briefings.
  """

  alias Maraithon.Crm
  alias Maraithon.Tools.PersonHelpers
  alias Maraithon.WebSearch

  @max_web_queries 100
  @max_web_queries_per_meeting 10
  @web_result_limit 10
  @web_page_text_limit 20_000
  @web_timeout_ms 15_000

  @internal_terms ~w(
    agora calendar chief crm gmail google kent maraithon meet reclaim runner slack telegram zoom
  )

  @title_stopwords ~w(
    account admin all and availability briefing call chat check commercial customer decision
    discussion enterprise external for follow google gtm intro meeting office plan prep
    pricing reclaim review risk schedule standup sync team the today upcoming with your
  )

  @free_email_domains ~w(
    aol.com gmail.com googlemail.com hey.com hotmail.com icloud.com live.com mac.com me.com
    msn.com outlook.com proton.me protonmail.com yahoo.com
  )

  @internal_email_domains ~w(runner.now voteagora.com agora.xyz)

  @personal_calendar_terms [
    "anniversary",
    "birthday",
    "camp",
    "childcare",
    "cross country",
    "daycare",
    "dentist",
    "doctor",
    "dropoff",
    "drop-off",
    "family",
    "frankie",
    "gym",
    "haircut",
    "holiday",
    "kids",
    "orthodontist",
    "personal",
    "pickup",
    "pick-up",
    "practice",
    "school",
    "soccer",
    "vacation",
    "workout"
  ]

  def enrich(user_id, events, opts \\ [])

  def enrich(user_id, events, opts) when is_binary(user_id) and is_list(events) do
    max_web_queries =
      opts
      |> Keyword.get(:max_web_queries, @max_web_queries)
      |> clamp_integer(0, @max_web_queries)

    {indexed_meetings, _remaining_queries} =
      events
      |> prioritize_meeting_events()
      |> Enum.reduce({[], max_web_queries}, fn {event, index}, {meeting_acc, remaining_queries} ->
        {meeting, next_remaining} = enrich_event(user_id, event, opts, remaining_queries)
        {[{index, meeting} | meeting_acc], next_remaining}
      end)

    meetings =
      indexed_meetings
      |> Enum.sort_by(fn {index, _meeting} -> index end)
      |> Enum.map(fn {_index, meeting} -> meeting end)

    %{
      "policy" =>
        "CRM-first meeting prep: use CRM/open-work context first; when CRM has no match for a participant or company, use bounded public web search as fallback and keep uncertainty visible.",
      "meetings" => meetings,
      "counts" => %{
        "meetings" => length(meetings),
        "required_schedule_meetings" => Enum.count(meetings, &schedule_required?/1),
        "crm_contexts" => Enum.sum(Enum.map(meetings, &length(read_list(&1, "crm_context")))),
        "web_searches" => Enum.sum(Enum.map(meetings, &length(read_list(&1, "web_context")))),
        "web_pages" => Enum.sum(Enum.map(meetings, &web_page_context_count/1)),
        "data_gaps" => Enum.sum(Enum.map(meetings, &length(read_list(&1, "data_gaps"))))
      }
    }
  end

  def enrich(_user_id, _events, _opts) do
    %{
      "policy" =>
        "CRM-first meeting prep: use CRM/open-work context first; when CRM has no match for a participant or company, use bounded public web search as fallback and keep uncertainty visible.",
      "meetings" => [],
      "counts" => %{
        "meetings" => 0,
        "required_schedule_meetings" => 0,
        "crm_contexts" => 0,
        "web_searches" => 0,
        "web_pages" => 0,
        "data_gaps" => 0
      }
    }
  end

  defp enrich_event(user_id, event, opts, remaining_queries) do
    core = event_core(event)
    personal_logistics? = personal_logistics_event?(event)

    candidates =
      if personal_logistics? do
        []
      else
        event |> candidates_for_event()
      end

    {crm_contexts, unmatched_candidates} =
      if personal_logistics? do
        {[], []}
      else
        resolve_crm_contexts(user_id, candidates)
      end

    core = maybe_promote_schedule_required(core, event, crm_contexts)
    web_budget = web_budget_for_event(core, remaining_queries)

    {web_contexts, used_queries} =
      unmatched_candidates
      |> fetch_web_context(opts, web_budget, organization_hint(candidates))

    meeting =
      core
      |> Map.put("candidate_people_and_orgs", Enum.map(candidates, &public_candidate/1))
      |> Map.put("crm_context", crm_contexts)
      |> Map.put("web_context", web_contexts)
      |> Map.put("data_gaps", data_gaps(unmatched_candidates, web_contexts, web_budget > 0))
      |> compact_map()

    {meeting, max(remaining_queries - used_queries, 0)}
  end

  defp resolve_crm_contexts(user_id, candidates) do
    {contexts_by_person, unmatched} =
      Enum.reduce(candidates, {%{}, []}, fn candidate, {contexts, unmatched_acc} ->
        case crm_context_for_candidate(user_id, candidate) do
          {:ok, context} ->
            normalized =
              context
              |> PersonHelpers.serialize_relationship_context()
              |> normalize_json_value()

            person_id = get_in(normalized, ["person", "id"]) || candidate_key(candidate)

            serialized =
              normalized
              |> compact_crm_context()
              |> Map.put("matched_candidate", public_candidate(candidate))

            contexts =
              Map.update(contexts, person_id, serialized, fn existing ->
                existing
                |> Map.update("matched_candidates", [public_candidate(candidate)], fn matches ->
                  [public_candidate(candidate) | matches]
                end)
              end)

            {contexts, unmatched_acc}

          {:error, _reason} ->
            {contexts, [candidate | unmatched_acc]}
        end
      end)

    contexts =
      contexts_by_person
      |> Map.values()
      |> Enum.map(fn context ->
        case Map.get(context, "matched_candidates") do
          matches when is_list(matches) ->
            Map.put(context, "matched_candidates", Enum.reverse(matches))

          _ ->
            context
        end
      end)

    {contexts, unmatched |> Enum.reverse() |> Enum.uniq_by(&candidate_key/1)}
  end

  defp crm_context_for_candidate(user_id, %{email: email}) when is_binary(email) do
    case Crm.relationship_context(user_id, %{
           "contact_kind" => "email",
           "contact_value" => email,
           "limit" => 6
         }) do
      {:ok, context} -> {:ok, context}
      {:error, _reason} -> crm_context_by_query(user_id, email)
    end
  end

  defp crm_context_for_candidate(user_id, candidate),
    do: crm_context_by_query(user_id, candidate.query)

  defp crm_context_by_query(user_id, query) when is_binary(query) do
    Crm.relationship_context(user_id, %{"query" => query, "limit" => 6})
  end

  defp crm_context_by_query(_user_id, _query), do: {:error, :person_not_found}

  defp fetch_web_context(_candidates, _opts, remaining_queries, _org_hint)
       when remaining_queries <= 0,
       do: {[], 0}

  defp fetch_web_context(candidates, opts, remaining_queries, org_hint) do
    search_fun = Keyword.get(opts, :web_search_fun, &WebSearch.search/2)
    web_opts = Keyword.get(opts, :web_search_opts, [])
    page_fetch_fun = Keyword.get(opts, :web_page_fetch_fun, &WebSearch.fetch_page/2)

    page_opts =
      opts
      |> Keyword.get(:web_page_opts, [])
      |> Keyword.put_new(:text_limit, @web_page_text_limit)

    search_candidates =
      candidates
      |> Enum.reject(&internal_candidate?/1)
      |> Enum.take(remaining_queries)

    contexts =
      search_candidates
      |> Task.async_stream(
        fn candidate ->
          query = web_query(candidate, org_hint)

          {status, results, error} =
            case search_fun.(query, Keyword.merge([limit: @web_result_limit], web_opts)) do
              {:ok, %{} = response} ->
                {"ok", response |> Map.get("results", []) |> compact_web_results(), nil}

              {:error, reason} ->
                {"error", [], public_context_error(reason)}
            end

          page_contexts =
            candidate
            |> fetch_page_contexts(results, page_fetch_fun, page_opts)

          %{
            "candidate" => public_candidate(candidate),
            "candidate_key" => candidate_key(candidate),
            "query" => query,
            "status" => status,
            "results" => results,
            "page_contexts" => page_contexts,
            "error" => error
          }
          |> compact_map()
        end,
        max_concurrency: 3,
        ordered: true,
        timeout: @web_timeout_ms
      )
      |> Enum.map(fn
        {:ok, context} ->
          context

        {:exit, reason} ->
          %{"status" => "error", "error" => public_context_error(reason)}
      end)

    {contexts, length(search_candidates)}
  end

  defp data_gaps(_unmatched_candidates, _web_contexts, false), do: []

  defp data_gaps(unmatched_candidates, web_contexts, true) do
    Enum.map(unmatched_candidates, fn candidate ->
      context =
        Enum.find(web_contexts, &(Map.get(&1, "candidate_key") == candidate_key(candidate)))

      label = candidate.query

      cond do
        is_nil(context) ->
          "No saved relationship context found for #{label}. Keep the meeting prep cautious and avoid inventing background."

        read_list(context, "page_contexts") != [] ->
          "No saved relationship context found for #{label}. Use the public source context cautiously."

        read_list(context, "results") != [] ->
          "No saved relationship context found for #{label}. Public search returned lightweight context; treat it as unverified."

        Map.get(context, "status") == "error" ->
          "No saved relationship context found for #{label}. Public sources were unavailable, so keep the meeting prep cautious."

        true ->
          "No saved relationship context found for #{label}. Keep the meeting prep cautious and avoid inventing background."
      end
    end)
  end

  defp candidates_for_event(event) when is_map(event) do
    event
    |> participant_candidates()
    |> Kernel.++(summary_candidates(read_string(event, "summary")))
    |> Enum.map(&normalize_candidate/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.reject(&internal_candidate?/1)
    |> Enum.uniq_by(&candidate_dedupe_key/1)
  end

  defp candidates_for_event(_event), do: []

  defp participant_candidates(event) do
    attendee_candidates =
      event
      |> read_list("attendees")
      |> Enum.flat_map(&attendee_candidates/1)

    organizer_candidates =
      event
      |> read_string("organizer")
      |> case do
        nil -> []
        organizer -> attendee_candidates(organizer)
      end

    attendee_candidates ++ organizer_candidates
  end

  defp attendee_candidates(attendee) when is_map(attendee) do
    email = read_string(attendee, "email")
    domain = email_domain(email)

    name =
      read_string(attendee, "display_name") ||
        read_string(attendee, "displayName") ||
        read_string(attendee, "name") ||
        name_from_email(email)

    [
      %{query: name, kind: "person", source: "attendee", email: email, domain: domain},
      company_candidate_from_email(email)
    ]
  end

  defp attendee_candidates(attendee) when is_binary(attendee) do
    email = extract_email(attendee)
    domain = email_domain(email)
    name = attendee |> String.replace(~r/<[^>]+>/, "") |> normalize_string()

    name =
      cond do
        is_nil(name) ->
          name_from_email(email)

        is_binary(email) and String.downcase(name) == String.downcase(email) ->
          name_from_email(email)

        true ->
          name
      end

    [
      %{query: name, kind: "person", source: "attendee", email: email, domain: domain},
      company_candidate_from_email(email)
    ]
  end

  defp attendee_candidates(_attendee), do: []

  defp summary_candidates(nil), do: []

  defp summary_candidates(summary) when is_binary(summary) do
    ~r/\b[A-Z][A-Za-z0-9'.-]*(?:\s+[A-Z][A-Za-z0-9'.-]*){0,3}\b/
    |> Regex.scan(summary)
    |> Enum.map(fn [phrase] -> String.trim(phrase) end)
    |> Enum.reject(&title_stopword?/1)
    |> Enum.map(fn phrase ->
      %{
        query: phrase,
        kind: if(String.contains?(phrase, " "), do: "person_or_org", else: "organization"),
        source: "event_summary"
      }
    end)
  end

  defp company_candidate_from_email(nil), do: nil

  defp company_candidate_from_email(email) when is_binary(email) do
    case email_domain(email) do
      domain when domain in @free_email_domains ->
        nil

      domain when is_binary(domain) ->
        domain
        |> String.split(".")
        |> List.first()
        |> humanize_domain_label()
        |> then(
          &%{query: &1, kind: "organization", source: "attendee_email_domain", domain: domain}
        )

      _ ->
        nil
    end
  end

  defp normalize_candidate(%{query: query} = candidate) do
    case normalize_string(query) do
      nil ->
        nil

      query ->
        query = strip_surrounding_noise(query)

        if invalid_candidate_query?(query) do
          nil
        else
          candidate
          |> Map.put(:query, query)
          |> Map.update(:kind, "unknown", &to_string/1)
          |> compact_map()
        end
    end
  end

  defp normalize_candidate(_candidate), do: nil

  defp invalid_candidate_query?(query) do
    downcased = String.downcase(query)
    words = String.split(downcased, ~r/\s+/, trim: true)

    downcased in @internal_terms or
      downcased in @title_stopwords or
      words == [] or
      Enum.all?(words, &(&1 in @title_stopwords)) or
      String.length(query) < 3
  end

  defp internal_candidate?(%{query: query}) when is_binary(query) do
    query
    |> String.downcase()
    |> then(&(&1 in @internal_terms))
  end

  defp internal_candidate?(_candidate), do: false

  defp title_stopword?(phrase) do
    downcased = String.downcase(phrase)
    words = String.split(downcased, ~r/\s+/, trim: true)

    downcased in @title_stopwords or
      downcased in @internal_terms or
      Enum.all?(words, &(&1 in @title_stopwords or &1 in @internal_terms))
  end

  defp web_query(%{kind: kind, query: query, domain: domain}, _org_hint)
       when kind in ["person", "person_or_org"] and is_binary(domain) do
    "#{query} #{domain}"
  end

  defp web_query(%{kind: kind, query: query, domain: domain}, _org_hint)
       when kind in ["organization", "attendee_email_domain"] and is_binary(domain) do
    "#{query} #{domain}"
  end

  defp web_query(%{kind: kind, query: query}, org_hint)
       when kind in ["person", "person_or_org"] and is_binary(org_hint) do
    "#{query} #{org_hint}"
  end

  defp web_query(%{kind: kind, query: query}, _org_hint)
       when kind in ["organization", "attendee_email_domain"] do
    "#{query} company"
  end

  defp web_query(%{query: query}, _org_hint), do: query

  defp organization_hint(candidates) do
    candidates
    |> Enum.find(fn candidate -> candidate.kind == "organization" end)
    |> case do
      %{query: query} -> query
      _ -> nil
    end
  end

  defp event_core(event) when is_map(event) do
    external_attendees = external_attendee_details(event)
    schedule_required? = executive_external_meeting?(event, external_attendees)

    %{
      "event_id" => read_string(event, "event_id"),
      "summary" => read_string(event, "summary"),
      "start" => read_any(event, "start"),
      "end" => read_any(event, "end"),
      "display_start" => read_string(event, "display_start"),
      "display_end" => read_string(event, "display_end"),
      "display_date" => read_string(event, "display_date"),
      "display_timezone" => read_string(event, "display_timezone"),
      "location" => read_string(event, "location"),
      "attendees" =>
        event
        |> read_list("attendees")
        |> Enum.map(&compact_attendee/1)
        |> Enum.reject(&is_nil/1),
      "external_attendees" => external_attendees,
      "schedule_required" => schedule_required?,
      "briefing_priority" =>
        if(schedule_required?, do: "required_external_meeting", else: "standard_meeting"),
      "briefing_reason" =>
        if(schedule_required?,
          do: "Executive external meeting; must be covered in Today's Schedule.",
          else: nil
        ),
      "organizer" => read_string(event, "organizer"),
      "html_link" => read_string(event, "html_link"),
      "calendar_name" => read_string(event, "calendar_name"),
      "source" => read_string(event, "source")
    }
  end

  defp schedule_required?(meeting) when is_map(meeting),
    do: Map.get(meeting, "schedule_required") == true

  defp schedule_required?(_meeting), do: false

  defp meeting_like?(event) when is_map(event) do
    read_string(event, "summary") != nil and
      (read_list(event, "attendees") != [] or read_string(event, "organizer") != nil or
         summary_candidates(read_string(event, "summary")) != [])
  end

  defp meeting_like?(_event), do: false

  defp prioritize_meeting_events(events) do
    events
    |> Enum.with_index()
    |> Enum.filter(fn {event, _index} -> meeting_like?(event) end)
    |> Enum.sort_by(fn {event, index} ->
      {meeting_priority(event), event_start_sort_key(event), index}
    end)
  end

  defp meeting_priority(event) do
    attendees = read_list(event, "attendees")
    external_attendees = external_attendee_details(event)

    cond do
      executive_external_meeting?(event, external_attendees) -> 0
      external_attendees?(attendees) -> 1
      attendees != [] -> 1
      read_string(event, "organizer") != nil -> 2
      true -> 3
    end
  end

  defp web_budget_for_event(%{"schedule_required" => true}, remaining_queries),
    do: min(remaining_queries, @max_web_queries_per_meeting)

  defp web_budget_for_event(_core, _remaining_queries), do: 0

  defp executive_external_meeting?(_event, []), do: false

  defp executive_external_meeting?(event, external_attendees) do
    cond do
      personal_logistics_event?(event) ->
        false

      Enum.any?(external_attendees, &business_attendee?/1) ->
        true

      true ->
        false
    end
  end

  defp maybe_promote_schedule_required(%{"schedule_required" => true} = core, _event, _contexts),
    do: core

  defp maybe_promote_schedule_required(core, event, crm_contexts) do
    if read_list(core, "external_attendees") != [] and not personal_logistics_event?(event) and
         Enum.any?(crm_contexts, &executive_crm_context?/1) do
      core
      |> Map.put("schedule_required", true)
      |> Map.put("briefing_priority", "required_external_meeting")
      |> Map.put(
        "briefing_reason",
        "CRM-linked executive external meeting; must be covered in Today's Schedule."
      )
    else
      core
    end
  end

  defp executive_crm_context?(context) when is_map(context) do
    person = read_any(context, "person") || %{}

    text =
      [
        read_string(person, "relationship"),
        read_string(person, "notes")
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(" ")
      |> String.downcase()

    text != "" and
      String.contains?(text, [
        "agora",
        "advisor",
        "client",
        "commercial",
        "customer",
        "enterprise",
        "founder",
        "gtm",
        "investor",
        "partner",
        "pricing",
        "runner",
        "sales",
        "teammate",
        "vendor",
        "work"
      ])
  end

  defp executive_crm_context?(_context), do: false

  defp personal_logistics_event?(event) do
    text =
      [
        read_string(event, "summary"),
        read_string(event, "calendar_name")
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(" ")
      |> String.downcase()

    text != "" and Enum.any?(@personal_calendar_terms, &String.contains?(text, &1))
  end

  defp business_attendee?(%{"domain" => domain}) when is_binary(domain),
    do: business_domain?(domain)

  defp business_attendee?(_attendee), do: false

  defp business_domain?(domain) when is_binary(domain),
    do: domain not in @free_email_domains and domain not in @internal_email_domains

  defp business_domain?(_domain), do: false

  defp external_attendees?(attendees) do
    Enum.any?(attendees, fn attendee ->
      attendee
      |> attendee_email()
      |> external_email?()
    end)
  end

  defp external_attendee_details(event) do
    event
    |> read_list("attendees")
    |> Enum.flat_map(&external_attendee_detail/1)
  end

  defp external_attendee_detail(%{} = attendee) do
    email = attendee_email(attendee)

    if external_email?(email) do
      [
        %{
          "display_name" =>
            read_string(attendee, "display_name") ||
              read_string(attendee, "displayName") ||
              read_string(attendee, "name") ||
              name_from_email(email),
          "email" => email,
          "domain" => email_domain(email)
        }
        |> compact_map()
      ]
    else
      []
    end
  end

  defp external_attendee_detail(attendee) when is_binary(attendee) do
    email = attendee_email(attendee)

    if external_email?(email) do
      name =
        attendee
        |> String.replace(~r/<[^>]+>/, "")
        |> normalize_string()

      [
        %{
          "display_name" => name || name_from_email(email),
          "email" => email,
          "domain" => email_domain(email)
        }
        |> compact_map()
      ]
    else
      []
    end
  end

  defp external_attendee_detail(_attendee), do: []

  defp compact_attendee(%{} = attendee) do
    email = attendee_email(attendee)

    %{
      "display_name" =>
        read_string(attendee, "display_name") ||
          read_string(attendee, "displayName") ||
          read_string(attendee, "name") ||
          name_from_email(email),
      "email" => email,
      "domain" => email_domain(email),
      "response_status" => read_string(attendee, "response_status")
    }
    |> compact_map()
  end

  defp compact_attendee(attendee) when is_binary(attendee), do: attendee
  defp compact_attendee(_attendee), do: nil

  defp attendee_email(%{} = attendee), do: read_string(attendee, "email")
  defp attendee_email(attendee) when is_binary(attendee), do: extract_email(attendee)
  defp attendee_email(_attendee), do: nil

  defp external_email?(email) when is_binary(email) do
    case email_domain(email) do
      nil -> false
      "runner.now" -> false
      "voteagora.com" -> false
      "agora.xyz" -> false
      _domain -> true
    end
  end

  defp external_email?(_email), do: false

  defp event_start_sort_key(event) when is_map(event) do
    event
    |> read_any("start")
    |> normalize_sort_value()
  end

  defp event_start_sort_key(_event), do: ""

  defp public_candidate(candidate) when is_map(candidate) do
    candidate
    |> Map.take([:query, :kind, :source, :email, :domain])
    |> normalize_json_value()
    |> compact_map()
  end

  defp compact_crm_context(context) when is_map(context) do
    %{
      "person" => compact_crm_person(read_any(context, "person")),
      "link_count" => read_any(context, "link_count"),
      "open_todo_count" => read_any(context, "open_todo_count"),
      "links" => context |> read_list("links") |> Enum.map(&compact_crm_link/1),
      "todos" => context |> read_list("todos") |> Enum.map(&compact_crm_todo/1)
    }
    |> compact_map()
  end

  defp compact_crm_context(_context), do: %{}

  defp compact_crm_person(person) when is_map(person) do
    %{
      "display_name" =>
        read_string(person, "display_name") ||
          [read_string(person, "first_name"), read_string(person, "last_name")]
          |> Enum.reject(&is_nil/1)
          |> Enum.join(" ")
          |> normalize_string(),
      "first_name" => read_string(person, "first_name"),
      "last_name" => read_string(person, "last_name"),
      "relationship" => read_string(person, "relationship"),
      "preferred_communication_method" => read_string(person, "preferred_communication_method"),
      "communication_frequency" => read_string(person, "communication_frequency"),
      "notes" => read_string(person, "notes"),
      "contact_details" => compact_contact_details(read_any(person, "contact_details"))
    }
    |> compact_map()
  end

  defp compact_crm_person(_person), do: nil

  defp compact_contact_details(details) when is_map(details) do
    details
    |> Map.take([
      "email",
      "emails",
      "phone",
      "phones",
      "website",
      "url",
      "linkedin",
      "twitter"
    ])
    |> normalize_json_value()
    |> compact_map()
  end

  defp compact_contact_details(_details), do: nil

  defp compact_crm_link(link) when is_map(link) do
    %{
      "resource_type" => read_string(link, "resource_type"),
      "resource_source" => read_string(link, "resource_source"),
      "title" => read_string(link, "title"),
      "summary" => read_string(link, "summary"),
      "relationship_note" => read_string(link, "relationship_note")
    }
    |> compact_map()
  end

  defp compact_crm_link(_link), do: %{}

  defp compact_crm_todo(todo) when is_map(todo) do
    %{
      "title" => read_string(todo, "title"),
      "summary" => read_string(todo, "summary"),
      "next_action" => read_string(todo, "next_action"),
      "due_at" => read_string(todo, "due_at"),
      "status" => read_string(todo, "status"),
      "source" => read_string(todo, "source")
    }
    |> compact_map()
  end

  defp compact_crm_todo(_todo), do: %{}

  defp compact_web_results(results) when is_list(results) do
    results
    |> Enum.map(&compact_web_result/1)
    |> Enum.reject(&(&1 == %{}))
  end

  defp compact_web_results(_results), do: []

  defp compact_web_result(result) when is_map(result) do
    %{
      "title" => read_string(result, "title"),
      "url" => read_string(result, "url"),
      "snippet" => read_string(result, "snippet")
    }
    |> compact_map()
  end

  defp compact_web_result(_result), do: %{}

  defp fetch_page_contexts(candidate, results, page_fetch_fun, page_opts) do
    candidate
    |> page_urls_for_candidate(results)
    |> Enum.map(fn url ->
      case page_fetch_fun.(url, page_opts) do
        {:ok, %{} = page} ->
          page
          |> Map.put_new("source_url", url)
          |> compact_page_context()

        {:error, _reason} ->
          %{}
      end
    end)
    |> Enum.reject(&(&1 == %{}))
  end

  defp page_urls_for_candidate(candidate, results) do
    homepage =
      candidate
      |> candidate_domain()
      |> case do
        nil -> []
        domain -> ["https://#{domain}/"]
      end

    result_urls =
      results
      |> Enum.map(&read_string(&1, "url"))
      |> Enum.reject(&is_nil/1)

    (homepage ++ result_urls)
    |> Enum.uniq_by(&normalize_url_key/1)
  end

  defp candidate_domain(%{domain: domain}) when is_binary(domain), do: String.downcase(domain)
  defp candidate_domain(%{email: email}) when is_binary(email), do: email_domain(email)
  defp candidate_domain(_candidate), do: nil

  defp normalize_url_key(url) when is_binary(url) do
    url
    |> String.trim()
    |> String.trim_trailing("/")
    |> String.downcase()
  end

  defp normalize_url_key(url), do: inspect(url)

  defp compact_page_context(page) when is_map(page) do
    %{
      "url" => read_string(page, "url") || read_string(page, "source_url"),
      "title" => read_string(page, "title"),
      "description" => read_string(page, "description"),
      "text" => read_string(page, "text")
    }
    |> compact_map()
  end

  defp compact_page_context(_page), do: %{}

  defp web_page_context_count(meeting) when is_map(meeting) do
    meeting
    |> read_list("web_context")
    |> Enum.map(&(read_list(&1, "page_contexts") |> length()))
    |> Enum.sum()
  end

  defp web_page_context_count(_meeting), do: 0

  defp candidate_key(%{email: email}) when is_binary(email),
    do: "email:" <> String.downcase(email)

  defp candidate_key(%{query: query}), do: "query:" <> String.downcase(query)
  defp candidate_key(candidate), do: inspect(candidate)

  defp candidate_dedupe_key(%{query: query}) when is_binary(query),
    do: "query:" <> String.downcase(query)

  defp candidate_dedupe_key(candidate), do: candidate_key(candidate)

  defp extract_email(value) when is_binary(value) do
    case Regex.run(~r/[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}/i, value) do
      [email] -> String.downcase(email)
      _ -> nil
    end
  end

  defp name_from_email(nil), do: nil

  defp name_from_email(email) when is_binary(email) do
    email
    |> String.split("@")
    |> List.first()
    |> String.split(~r/[._+\-]+/, trim: true)
    |> Enum.reject(&(&1 == "" or String.match?(&1, ~r/^\d+$/)))
    |> Enum.map(&titleize_token/1)
    |> Enum.join(" ")
    |> normalize_string()
  end

  defp email_domain(email) when is_binary(email) do
    case String.split(email, "@") do
      [_local, domain] -> String.downcase(domain)
      _ -> nil
    end
  end

  defp titleize_token(token) when is_binary(token) do
    token
    |> String.replace(~r/[^A-Za-z0-9'-]/, " ")
    |> String.split(~r/\s+/, trim: true)
    |> Enum.map(&String.capitalize/1)
    |> Enum.join(" ")
    |> normalize_string()
  end

  defp humanize_domain_label(label) when is_binary(label) do
    label
    |> String.replace(~r/[-_]+/, " ")
    |> split_known_domain_suffix()
    |> titleize_token()
  end

  defp humanize_domain_label(_label), do: nil

  defp split_known_domain_suffix(label) when is_binary(label) do
    normalized = String.downcase(label)

    suffix =
      Enum.find(~w(studio labs lab agency group ai ops automation design media), fn suffix ->
        String.ends_with?(normalized, suffix) and
          String.length(normalized) > String.length(suffix) + 2
      end)

    if suffix && not String.contains?(normalized, " ") do
      prefix = String.slice(normalized, 0, String.length(normalized) - String.length(suffix))
      prefix <> " " <> suffix
    else
      label
    end
  end

  defp split_known_domain_suffix(label), do: label

  defp strip_surrounding_noise(query) do
    query
    |> String.replace(~r/\s+/, " ")
    |> String.trim(" -–—:|,")
  end

  defp read_any(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, to_existing_atom_if_loaded(key))
  end

  defp read_any(_map, _key), do: nil

  defp read_string(map, key) when is_map(map) do
    case read_any(map, key) do
      value when is_binary(value) -> normalize_string(value)
      _ -> nil
    end
  end

  defp read_string(_map, _key), do: nil

  defp read_list(map, key) when is_map(map) do
    case read_any(map, key) do
      value when is_list(value) -> value
      _ -> []
    end
  end

  defp read_list(_map, _key), do: []

  defp normalize_json_value(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)
  defp normalize_json_value(%Date{} = date), do: Date.to_iso8601(date)

  defp normalize_json_value(value) when is_list(value),
    do: Enum.map(value, &normalize_json_value/1)

  defp normalize_json_value(value) when is_map(value) do
    Map.new(value, fn {key, nested} -> {to_string(key), normalize_json_value(nested)} end)
  end

  defp normalize_json_value(value), do: value

  defp normalize_sort_value(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)
  defp normalize_sort_value(%Date{} = date), do: Date.to_iso8601(date)
  defp normalize_sort_value(value) when is_binary(value), do: value
  defp normalize_sort_value(_value), do: ""

  defp compact_map(map) when is_map(map) do
    map
    |> Enum.reject(fn {_key, value} -> value in [nil, "", [], %{}] end)
    |> Map.new()
  end

  defp public_context_error(reason) do
    text =
      reason
      |> inspect()
      |> String.downcase()

    cond do
      text =~ "timeout" or text =~ "timed out" ->
        "Public sources timed out."

      text =~ "rate" and text =~ "limit" ->
        "Public sources were rate-limited."

      true ->
        "Public sources were unavailable."
    end
  end

  defp normalize_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_string(_value), do: nil

  defp clamp_integer(value, min_value, max_value) when is_integer(value) do
    value |> max(min_value) |> min(max_value)
  end

  defp clamp_integer(_value, _min_value, max_value), do: max_value

  defp to_existing_atom_if_loaded(key) when is_binary(key) do
    try do
      String.to_existing_atom(key)
    rescue
      ArgumentError -> key
    end
  end

  defp to_existing_atom_if_loaded(key), do: key
end
