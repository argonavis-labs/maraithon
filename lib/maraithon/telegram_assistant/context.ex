defmodule Maraithon.TelegramAssistant.Context do
  @moduledoc """
  Builds the compact Telegram assistant context snapshot for one run.
  """

  import Ecto.Query

  alias Maraithon.Agents
  alias Maraithon.BriefingSchedules
  alias Maraithon.ConnectedAccounts
  alias Maraithon.ContextCache
  alias Maraithon.Crm
  alias Maraithon.InsightNotifications.Delivery
  alias Maraithon.Insights
  alias Maraithon.Insights.Detail
  alias Maraithon.LocalCalendar
  alias Maraithon.Memory
  alias Maraithon.OAuth
  alias Maraithon.OpenLoops
  alias Maraithon.OperatorMemory
  alias Maraithon.PreferenceMemory
  alias Maraithon.Projects
  alias Maraithon.Repo
  alias Maraithon.SourceFreshness
  alias Maraithon.TelegramConversations
  alias Maraithon.TelegramConversations.Conversation
  alias Maraithon.Tools.GoogleCalendarHelpers
  alias Maraithon.Todos
  alias Maraithon.Todos.AttentionRanker
  alias Maraithon.Travel
  alias Maraithon.UserMemory

  @calendar_context_lookback_hours 2
  @calendar_context_forward_hours 72
  @calendar_context_limit 40
  @personal_calendar_terms ~w(
    appointment birthday camp child children dad dentist doctor daughter emma family home jack
    kid kids medical mom parent personal practice rsvp school soccer son spouse wife husband
  )

  def build(attrs) when is_map(attrs) do
    user_id = fetch_string!(attrs, :user_id)
    conversation = Map.get(attrs, :conversation)
    linked_delivery = Map.get(attrs, :linked_delivery)
    linked_insight = Map.get(attrs, :linked_insight)
    linked_travel = linked_travel_itinerary(conversation, user_id)
    linked_todo = linked_todo(attrs, user_id)
    linked_project = linked_project(attrs, user_id)

    today_digest = ContextCache.get_digest(user_id)
    _ = Maraithon.ContextCache.Builder.maybe_refresh_async(user_id)
    user_text = latest_user_text(conversation)

    fetched = parallel_fetch(user_id, user_text)

    %{
      user: %{id: user_id},
      chat: %{id: fetch_string!(attrs, :chat_id)},
      conversation: serialize_conversation(conversation),
      linked_item:
        serialize_linked_item(
          linked_delivery,
          linked_insight,
          linked_travel,
          linked_todo,
          linked_project
        ),
      recent_turns: serialize_recent_turns(conversation),
      preference_memory: fetched.preference_memory,
      operator_memory: fetched.operator_memory,
      user_memory: fetched.user_memory,
      deep_memory: fetched.deep_memory,
      open_loops: fetched.open_loops,
      relationships: fetched.relationships,
      open_insights: fetched.open_insights,
      todos: fetched.todos,
      briefing_schedule: fetched.briefing_schedule,
      connected_accounts: fetched.connected_accounts,
      source_freshness: fetched.source_freshness,
      projects: fetched.projects,
      active_agents: fetched.active_agents,
      defaults: fetched.defaults,
      today_digest: today_digest
    }
  end

  defp parallel_fetch(user_id, user_text) do
    fetchers = [
      {:preference_memory, fn -> PreferenceMemory.prompt_context(user_id) end},
      {:operator_memory, fn -> OperatorMemory.summaries_for_prompt(user_id) end},
      {:user_memory, fn -> UserMemory.prompt_context(user_id) end},
      # Skip the LLM-filter on the hot path (it added 2-6s per turn). The
      # model can call recall_memory when it needs query-filtered memories.
      {:deep_memory, fn -> Memory.prompt_context(user_id, limit: 8) end},
      {:open_loops,
       fn ->
         OpenLoops.snapshot(user_id, query: user_text, limit: 8, include_memory?: false)
       end},
      {:relationships, fn -> serialize_relationships(user_id) end},
      {:open_insights, fn -> serialize_open_insights(user_id) end},
      {:todos, fn -> serialize_todos(user_id) end},
      {:calendar, fn -> serialize_calendar(user_id) end},
      {:briefing_schedule, fn -> BriefingSchedules.summarize_for_prompt(user_id) end},
      {:connected_accounts, fn -> serialize_connected_accounts(user_id) end},
      {:source_freshness, fn -> SourceFreshness.compact_for_prompt(user_id) end},
      {:projects, fn -> serialize_projects(user_id) end},
      {:active_agents, fn -> serialize_agents(user_id) end},
      {:defaults, fn -> tool_defaults(user_id) end}
    ]

    fetchers
    |> Task.async_stream(
      fn {key, fun} -> {key, fun.()} end,
      ordered: false,
      timeout: :infinity,
      max_concurrency: length(fetchers)
    )
    |> Enum.reduce(%{}, fn
      {:ok, {key, value}}, acc -> Map.put(acc, key, value)
      {:exit, reason}, _acc -> raise "context fetch failed: #{inspect(reason)}"
    end)
  end

  def prompt_snapshot(context) when is_map(context), do: context

  defp serialize_conversation(%Conversation{} = conversation) do
    %{
      id: conversation.id,
      status: conversation.status,
      summary: conversation.summary,
      historical_summary: get_in(conversation.metadata || %{}, ["historical_summary"]),
      mode: get_in(conversation.metadata || %{}, ["mode"]),
      linked_delivery_id: conversation.linked_delivery_id,
      linked_insight_id: conversation.linked_insight_id,
      travel_itinerary_id: get_in(conversation.metadata || %{}, ["travel_itinerary_id"]),
      latest_prepared_action_id:
        get_in(conversation.metadata || %{}, ["latest_prepared_action_id"])
    }
  end

  defp serialize_conversation(_conversation), do: %{}

  defp serialize_recent_turns(%Conversation{} = conversation) do
    TelegramConversations.recent_turns(conversation, limit: 8)
    |> Enum.map(fn turn ->
      %{
        role: turn.role,
        turn_kind: turn.turn_kind,
        origin_type: turn.origin_type,
        text: turn.text,
        intent: turn.intent,
        inserted_at: turn.inserted_at
      }
    end)
  end

  defp serialize_recent_turns(_conversation), do: []

  defp latest_user_text(%Conversation{} = conversation) do
    conversation
    |> TelegramConversations.recent_turns(limit: 4)
    |> Enum.find_value(fn turn ->
      if turn.role == "user", do: turn.text
    end)
  end

  defp latest_user_text(_conversation), do: nil

  defp serialize_linked_item(
         %Delivery{} = delivery,
         linked_insight,
         linked_travel,
         linked_todo,
         linked_project
       ) do
    insight = linked_insight || Repo.preload(delivery, :insight).insight
    deliveries = insight_deliveries(insight, delivery.user_id)
    detail = insight && Detail.build(insight, deliveries)

    %{
      delivery: serialize_delivery(delivery),
      insight: serialize_insight(insight),
      detail: detail && serialize_detail(detail),
      travel: linked_travel && Travel.serialize_for_prompt(linked_travel),
      todo: serialize_todo(linked_todo),
      project: serialize_project(linked_project)
    }
  end

  defp serialize_linked_item(_delivery, nil, nil, nil, nil), do: %{}

  defp serialize_linked_item(_delivery, nil, linked_travel, linked_todo, linked_project) do
    %{
      delivery: nil,
      insight: nil,
      detail: nil,
      travel: linked_travel && Travel.serialize_for_prompt(linked_travel),
      todo: serialize_todo(linked_todo),
      project: serialize_project(linked_project)
    }
  end

  defp serialize_linked_item(_delivery, insight, linked_travel, linked_todo, linked_project) do
    deliveries = insight_deliveries(insight, insight.user_id)
    detail = Detail.build(insight, deliveries)

    %{
      delivery: nil,
      insight: serialize_insight(insight),
      detail: serialize_detail(detail),
      travel: linked_travel && Travel.serialize_for_prompt(linked_travel),
      todo: serialize_todo(linked_todo),
      project: serialize_project(linked_project)
    }
  end

  defp serialize_open_insights(user_id) do
    Insights.list_open_with_details_for_user(user_id, limit: 6)
    |> Enum.map(fn %{insight: insight, detail: detail} ->
      %{
        id: insight.id,
        source: insight.source,
        category: insight.category,
        attention_mode: insight.attention_mode,
        tracking_key: insight.tracking_key,
        title: insight.title,
        summary: insight.summary,
        recommended_action: insight.recommended_action,
        priority: insight.priority,
        confidence: insight.confidence,
        detail: serialize_detail(detail)
      }
    end)
  end

  defp serialize_connected_accounts(user_id) do
    ConnectedAccounts.list_for_user(user_id)
    |> Enum.map(fn account ->
      %{
        provider: account.provider,
        status: account.status,
        scopes: account.scopes,
        metadata: redact_account_metadata(account.metadata || %{})
      }
    end)
  end

  defp serialize_todos(user_id) do
    user_id
    |> Todos.list_open_for_user(limit: 40)
    |> AttentionRanker.sort()
    |> Enum.take(20)
    |> Enum.map(&Todos.serialize_for_prompt/1)
  end

  defp serialize_calendar(user_id) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    since = DateTime.add(now, -@calendar_context_lookback_hours, :hour)
    until = DateTime.add(now, @calendar_context_forward_hours, :hour)

    {local_events, local_status} = fetch_local_calendar_events(user_id, since, until)
    {google_events, google_status} = fetch_google_calendar_events(user_id, since, until)

    events =
      (local_events ++ google_events)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq_by(&calendar_event_dedupe_key/1)
      |> Enum.sort_by(&calendar_event_sort_value/1)
      |> Enum.take(@calendar_context_limit)

    personal_events =
      events
      |> Enum.filter(&personal_calendar_event?(&1, user_id))
      |> Enum.take(12)

    %{
      window: %{
        since: DateTime.to_iso8601(since),
        until: DateTime.to_iso8601(until)
      },
      policy:
        "Upcoming personal/family calendar events are first-class attention signals and outrank routine work.",
      preferred_source: calendar_preferred_source(local_events, google_events),
      upcoming_events: events,
      personal_events: personal_events,
      counts: %{
        upcoming: length(events),
        personal: length(personal_events),
        local: length(local_events),
        google: length(google_events)
      },
      source_status: %{
        local: local_status,
        google: google_status
      }
    }
  end

  defp serialize_relationships(user_id) do
    Crm.summarize_for_prompt(user_id, 20)
  end

  defp fetch_local_calendar_events(user_id, since, until) do
    events =
      user_id
      |> LocalCalendar.events_around(
        since: since,
        until: until,
        limit: @calendar_context_limit
      )
      |> Enum.map(&local_calendar_event_for_prompt/1)

    status = if events == [], do: "empty", else: "ready"
    {events, status}
  rescue
    exception ->
      {[], "error: #{Exception.message(exception)}"}
  end

  defp fetch_google_calendar_events(user_id, since, until) do
    case GoogleCalendarHelpers.list_events(user_id,
           time_min: DateTime.to_iso8601(since),
           time_max: DateTime.to_iso8601(until),
           max_results: @calendar_context_limit
         ) do
      {:ok, events} ->
        events = Enum.map(events, &google_calendar_event_for_prompt/1)
        status = if events == [], do: "empty", else: "ready"
        {events, status}

      {:error, reason} ->
        {[], "error: #{inspect(reason)}"}
    end
  rescue
    exception ->
      {[], "error: #{Exception.message(exception)}"}
  end

  defp local_calendar_event_for_prompt(event) do
    %{
      id: event.guid,
      source: "local_calendar",
      summary: event.title || "Untitled event",
      start: event.start_at,
      end: event.end_at,
      location: event.location,
      calendar_name: event.calendar_name,
      is_all_day: event.is_all_day,
      is_recurring: event.is_recurring,
      organizer: event.organizer_email,
      attendees: event.attendee_emails || [],
      account: event.calendar_name,
      attention_profile: calendar_attention_profile(event.title, event.calendar_name, nil)
    }
  end

  defp google_calendar_event_for_prompt(event) when is_map(event) do
    summary = read_field(event, "summary")
    account = read_field(event, "google_account_email")

    %{
      id: read_field(event, "event_id"),
      source: "google_calendar",
      summary: summary || "Untitled event",
      start: read_field(event, "start"),
      end: read_field(event, "end"),
      location: read_field(event, "location"),
      calendar_id: read_field(event, "calendar_id"),
      google_account_email: account,
      account: account,
      organizer: read_field(event, "organizer"),
      attendees: read_field(event, "attendees") || [],
      html_link: read_field(event, "html_link"),
      attention_profile:
        calendar_attention_profile(summary, read_field(event, "calendar_id"), account)
    }
  end

  defp google_calendar_event_for_prompt(_event), do: nil

  defp calendar_attention_profile(summary, calendar_name, account) do
    text =
      [summary, calendar_name, account]
      |> Enum.reject(&blank?/1)
      |> Enum.join(" ")
      |> String.downcase()

    personal? = contains_any?(text, @personal_calendar_terms) or personal_account?(account)

    %{
      bucket: if(personal?, do: "personal_family", else: "calendar"),
      bucket_rank: if(personal?, do: 0, else: 4),
      personal_family: personal?,
      source_kind: "calendar_event",
      context: %{
        account: account,
        calendar_name: calendar_name
      }
    }
  end

  defp personal_calendar_event?(event, user_id) do
    profile = read_field(event, "attention_profile") || %{}
    account = read_field(event, "account") || read_field(event, "google_account_email")

    read_field(profile, "personal_family") == true or
      personal_account?(account) or
      normalize_text(account) == normalize_text(user_id)
  end

  defp personal_account?(account) when is_binary(account) do
    normalized = String.downcase(account)
    String.ends_with?(normalized, "@gmail.com") or String.contains?(normalized, "personal")
  end

  defp personal_account?(_account), do: false

  defp calendar_preferred_source(local_events, google_events) do
    cond do
      local_events != [] and google_events != [] -> "local+google"
      local_events != [] -> "local"
      google_events != [] -> "google"
      true -> "none"
    end
  end

  defp calendar_event_dedupe_key(event) when is_map(event) do
    [
      read_field(event, "summary"),
      read_field(event, "start") |> stable_time_value(),
      read_field(event, "account") || read_field(event, "calendar_name")
    ]
    |> Enum.map(&to_string(&1 || ""))
    |> Enum.join("|")
    |> String.downcase()
  end

  defp calendar_event_dedupe_key(event), do: inspect(event)

  defp calendar_event_sort_value(event) when is_map(event) do
    event
    |> read_field("start")
    |> calendar_time_sort_value()
  end

  defp calendar_event_sort_value(_event), do: 9_999_999_999

  defp calendar_time_sort_value(%DateTime{} = datetime), do: DateTime.to_unix(datetime)

  defp calendar_time_sort_value(%{date: date}) when is_binary(date) do
    case Date.from_iso8601(date) do
      {:ok, parsed} -> Date.to_gregorian_days(parsed) * 86_400
      _ -> 9_999_999_999
    end
  end

  defp calendar_time_sort_value(%{"date" => date}) when is_binary(date) do
    calendar_time_sort_value(%{date: date})
  end

  defp calendar_time_sort_value(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> DateTime.to_unix(datetime)
      _ -> 9_999_999_999
    end
  end

  defp calendar_time_sort_value(_value), do: 9_999_999_999

  defp stable_time_value(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)
  defp stable_time_value(%NaiveDateTime{} = datetime), do: NaiveDateTime.to_iso8601(datetime)
  defp stable_time_value(value), do: value

  defp serialize_agents(user_id) do
    Agents.list_agents(user_id: user_id, preload: [:project])
    |> Enum.map(fn agent ->
      %{
        id: agent.id,
        behavior: agent.behavior,
        status: agent.status,
        name: get_in(agent.config || %{}, ["name"]),
        project_id: agent.project_id,
        project_name: agent.project && agent.project.name,
        subscriptions: get_in(agent.config || %{}, ["subscribe"]) || [],
        tools: get_in(agent.config || %{}, ["tools"]) || [],
        updated_at: agent.updated_at
      }
    end)
  end

  defp serialize_projects(user_id) do
    Projects.list_projects(user_id: user_id)
    |> Enum.map(fn project ->
      %{
        id: project.id,
        name: project.name,
        slug: project.slug,
        status: project.status,
        priority: project.priority,
        summary: project.summary,
        description: project.description,
        metadata:
          (project.metadata || %{})
          |> Map.take([
            "life_domain",
            "life_domain_confidence",
            "life_domain_reasoning",
            "life_domain_needs_confirmation"
          ])
      }
    end)
  end

  defp tool_defaults(user_id) do
    oauth_providers = OAuth.list_user_tokens(user_id) |> Enum.map(& &1.provider)
    slack_team_ids = extract_slack_team_ids(oauth_providers)
    default_project = Projects.default_project_for_user(user_id)

    %{
      default_slack_team_id: List.first(slack_team_ids),
      slack_team_ids: slack_team_ids,
      default_project_id: default_project && default_project.id,
      default_project_slug: default_project && default_project.slug,
      linear_connected: Enum.member?(oauth_providers, "linear"),
      provider_ids: oauth_providers
    }
  end

  defp serialize_delivery(%Delivery{} = delivery) do
    %{
      id: delivery.id,
      channel: delivery.channel,
      score: delivery.score,
      threshold: delivery.threshold,
      status: delivery.status,
      sent_at: delivery.sent_at,
      feedback: delivery.feedback,
      metadata: Map.take(delivery.metadata || %{}, ["telegram_message_id", "telegram_action"])
    }
  end

  defp serialize_delivery(_delivery), do: nil

  defp serialize_insight(nil), do: nil

  defp serialize_insight(insight) do
    %{
      id: insight.id,
      source: insight.source,
      category: insight.category,
      attention_mode: insight.attention_mode,
      tracking_key: insight.tracking_key,
      title: insight.title,
      summary: insight.summary,
      recommended_action: insight.recommended_action,
      priority: insight.priority,
      confidence: insight.confidence,
      status: insight.status,
      metadata: redact_insight_metadata(insight.metadata || %{})
    }
  end

  defp serialize_detail(detail) when is_map(detail) do
    %{
      promise_text: detail[:promise_text],
      requested_by: detail[:requested_by],
      evidence_checked: detail[:evidence_checked],
      delivery_evidence: detail[:delivery_evidence],
      open_loop_reason: detail[:open_loop_reason],
      data_gaps: detail[:data_gaps]
    }
  end

  defp serialize_todo(nil), do: nil
  defp serialize_todo(todo), do: Todos.serialize_for_prompt(todo)

  defp serialize_project(nil), do: nil

  defp serialize_project(project) do
    %{
      id: project.id,
      name: project.name,
      slug: project.slug,
      status: project.status,
      priority: project.priority,
      summary: project.summary,
      description: project.description,
      metadata:
        (project.metadata || %{})
        |> Map.take([
          "life_domain",
          "life_domain_confidence",
          "life_domain_reasoning",
          "life_domain_needs_confirmation"
        ])
    }
  end

  defp insight_deliveries(nil, _user_id), do: []

  defp insight_deliveries(insight, user_id)
       when is_binary(insight.id) and is_binary(user_id) do
    Delivery
    |> where([delivery], delivery.insight_id == ^insight.id and delivery.user_id == ^user_id)
    |> order_by([delivery], desc_nulls_last: delivery.sent_at, desc: delivery.inserted_at)
    |> Repo.all()
  end

  defp linked_todo(attrs, user_id) do
    chat_id = Map.get(attrs, :chat_id)
    reply_to_message_id = Map.get(attrs, :reply_to_message_id)

    with chat_id when is_binary(chat_id) <- normalize_id(chat_id),
         reply_to when is_binary(reply_to) <- normalize_id(reply_to_message_id),
         turn when not is_nil(turn) <-
           TelegramConversations.find_turn_by_message(chat_id, reply_to),
         %{} = todo_data <-
           Map.get(turn.structured_data || %{}, "linked_todo") ||
             Map.get(turn.structured_data || %{}, :linked_todo),
         todo_id when is_binary(todo_id) <- Map.get(todo_data, "id") || Map.get(todo_data, :id),
         todo when not is_nil(todo) <- Todos.get_for_user(user_id, todo_id) do
      todo
    else
      _ -> nil
    end
  end

  defp linked_project(attrs, user_id) do
    chat_id = Map.get(attrs, :chat_id)
    reply_to_message_id = Map.get(attrs, :reply_to_message_id)

    with chat_id when is_binary(chat_id) <- normalize_id(chat_id),
         reply_to when is_binary(reply_to) <- normalize_id(reply_to_message_id),
         turn when not is_nil(turn) <-
           TelegramConversations.find_turn_by_message(chat_id, reply_to),
         %{} = project_data <-
           Map.get(turn.structured_data || %{}, "linked_project") ||
             Map.get(turn.structured_data || %{}, :linked_project),
         project_id when is_binary(project_id) <-
           Map.get(project_data, "id") || Map.get(project_data, :id),
         project when not is_nil(project) <- Projects.get_project_for_user(project_id, user_id) do
      project
    else
      _ -> nil
    end
  end

  defp normalize_id(value) when is_binary(value), do: value
  defp normalize_id(value) when is_integer(value), do: Integer.to_string(value)
  defp normalize_id(_value), do: nil

  defp redact_account_metadata(metadata) when is_map(metadata) do
    metadata
    |> Map.drop(["access_token", "refresh_token", "token", "bot_token"])
    |> Map.take([
      "chat_id",
      "username",
      "email",
      "account_email",
      "workspace_id",
      "workspace_name",
      "team_id",
      "default_team_id",
      "login",
      "name",
      "connected_via"
    ])
  end

  defp redact_account_metadata(_metadata), do: %{}

  defp redact_insight_metadata(metadata) when is_map(metadata) do
    Map.take(metadata, [
      "account",
      "thread_id",
      "subject",
      "to",
      "from",
      "detail",
      "record",
      "context_brief",
      "source_ref"
    ])
  end

  defp redact_insight_metadata(_metadata), do: %{}

  defp extract_slack_team_ids(providers) when is_list(providers) do
    providers
    |> Enum.flat_map(fn
      "slack:" <> rest ->
        case String.split(rest, ":") do
          [team_id | _] when team_id != "" -> [team_id]
          _ -> []
        end

      _ ->
        []
    end)
    |> Enum.uniq()
  end

  defp linked_travel_itinerary(%Conversation{} = conversation, user_id) do
    case get_in(conversation.metadata || %{}, ["travel_itinerary_id"]) do
      itinerary_id when is_binary(itinerary_id) ->
        Travel.get_itinerary_for_user(user_id, itinerary_id)

      _ ->
        nil
    end
  end

  defp linked_travel_itinerary(_conversation, _user_id), do: nil

  defp fetch_string!(attrs, key) do
    value = Map.get(attrs, key) || Map.get(attrs, Atom.to_string(key))

    cond do
      is_binary(value) and value != "" -> value
      is_integer(value) -> Integer.to_string(value)
      true -> raise ArgumentError, "missing required context key #{inspect(key)}"
    end
  end

  defp read_field(nil, _key), do: nil
  defp read_field(%_{} = struct, key), do: read_field(Map.from_struct(struct), key)

  defp read_field(map, key) when is_map(map) and is_binary(key) do
    Map.get(map, key) ||
      Enum.find_value(map, fn
        {map_key, value} when is_atom(map_key) ->
          if Atom.to_string(map_key) == key, do: value

        _other ->
          nil
      end)
  end

  defp read_field(_map, _key), do: nil

  defp contains_any?(text, terms) when is_binary(text) and is_list(terms) do
    normalized = String.downcase(text)
    Enum.any?(terms, &String.contains?(normalized, &1))
  end

  defp contains_any?(_text, _terms), do: false

  defp normalize_text(value) when is_binary(value) do
    value
    |> String.downcase()
    |> String.trim()
  end

  defp normalize_text(_value), do: ""

  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(nil), do: true
  defp blank?(_value), do: false
end
