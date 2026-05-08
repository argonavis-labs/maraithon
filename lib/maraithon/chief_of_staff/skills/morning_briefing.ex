defmodule Maraithon.ChiefOfStaff.Skills.MorningBriefing do
  @moduledoc """
  Source-backed daily Chief of Staff morning brief.
  """

  @behaviour Maraithon.ChiefOfStaff.Skill

  alias Maraithon.Briefs
  alias Maraithon.ChiefOfStaff.SourceBundle
  alias Maraithon.Commitments
  alias Maraithon.Insights
  alias Maraithon.Todos

  @default_timezone_offset_hours -5
  @default_morning_hour 8
  @default_email_scan_limit 30
  @default_slack_channel_scan_limit 16
  @default_slack_message_scan_limit 8
  @default_news_limit 6
  @default_lookback_hours 18

  @impl true
  def id, do: "morning_briefing"

  @impl true
  def default_config do
    %{
      "assistant_behavior" => "ai_chief_of_staff",
      "timezone_offset_hours" => @default_timezone_offset_hours,
      "morning_brief_hour_local" => @default_morning_hour,
      "email_scan_limit" => @default_email_scan_limit,
      "slack_channel_scan_limit" => @default_slack_channel_scan_limit,
      "slack_message_scan_limit" => @default_slack_message_scan_limit,
      "news_enabled" => true,
      "news_limit" => @default_news_limit,
      "news_feeds" => [
        %{
          "name" => "Techmeme",
          "url" => "https://www.techmeme.com/feed.xml"
        },
        %{
          "name" => "Hacker News",
          "url" => "https://hnrss.org/frontpage"
        }
      ],
      "lookback_hours" => @default_lookback_hours,
      "slack_key_channels" => [
        "runner-general",
        "runner-leads",
        "runner-gtm",
        "runner-user-feedback",
        "gtm-leads",
        "general",
        "eng-general",
        "exec-agora-gov-mgmt-w-dash",
        "jeff",
        "charlie",
        "yitong"
      ]
    }
  end

  @impl true
  def requirements do
    [
      %{
        kind: :provider,
        provider: "telegram",
        label: "Telegram",
        description: "Required to deliver morning briefs.",
        required?: true
      },
      %{
        kind: :service,
        provider: "google",
        service: "calendar",
        label: "Google Calendar",
        description: "Needed for schedule, conflicts, prep notes, and tomorrow's first event.",
        required?: false
      },
      %{
        kind: :service,
        provider: "google",
        service: "gmail",
        label: "Gmail",
        description: "Needed for inbox triage and reply-debt signals.",
        required?: false
      },
      %{
        kind: :provider,
        provider: "slack",
        label: "Slack",
        description: "Needed for mentions, key channels, and thread follow-through.",
        required?: false
      }
    ]
  end

  @impl true
  def subscriptions(_config, _user_id), do: []

  @impl true
  def interested_in?(_config, context) do
    case get_in(context, [:trigger, :type]) do
      :message -> false
      :pubsub_event -> false
      _ -> true
    end
  end

  @impl true
  def init(config) do
    %{
      user_id: normalize_string(config["user_id"]),
      assistant_behavior: normalize_string(config["assistant_behavior"]) || "ai_chief_of_staff",
      timezone_offset_hours:
        integer_in_range(config["timezone_offset_hours"], @default_timezone_offset_hours, -12, 14),
      morning_hour:
        integer_in_range(config["morning_brief_hour_local"], @default_morning_hour, 0, 23),
      email_scan_limit:
        integer_in_range(config["email_scan_limit"], @default_email_scan_limit, 1, 100),
      slack_message_scan_limit:
        integer_in_range(
          config["slack_message_scan_limit"],
          @default_slack_message_scan_limit,
          1,
          100
        ),
      lookback_hours: integer_in_range(config["lookback_hours"], @default_lookback_hours, 1, 168),
      pending_brief_input: nil,
      pending_dedupe_key: nil,
      last_generated_keys: %{}
    }
  end

  @impl true
  def handle_wakeup(state, context) do
    user_id = state.user_id || normalize_string(context[:user_id])
    now = context[:timestamp] || DateTime.utc_now()
    period_key = local_period_key(now, state.timezone_offset_hours)
    dedupe_key = "morning_briefing:#{period_key}"

    cond do
      is_nil(user_id) ->
        {:idle, state}

      Map.get(state.last_generated_keys, "morning") == period_key ->
        {:idle, %{state | user_id: user_id}}

      not due_now?(now, state) ->
        {:idle, %{state | user_id: user_id}}

      true ->
        brief_input = build_brief_input(user_id, now, state, context)

        {:effect, {:llm_call, llm_params(brief_input)},
         %{
           state
           | user_id: user_id,
             pending_brief_input: brief_input,
             pending_dedupe_key: dedupe_key
         }}
    end
  end

  @impl true
  def handle_effect_result({:llm_call, response}, state, context) do
    brief_input = state.pending_brief_input || %{}
    brief = parse_llm_brief(response) || fallback_brief(brief_input)

    attrs = %{
      "cadence" => "morning",
      "scheduled_for" =>
        read_string(brief_input, "generated_at", DateTime.utc_now() |> DateTime.to_iso8601()),
      "dedupe_key" =>
        state.pending_dedupe_key ||
          "morning_briefing:#{read_string(brief_input, "date", "unknown")}",
      "title" => read_string(brief, "title", "Morning briefing"),
      "summary" =>
        read_string(brief, "summary", "Review today's schedule, inbox, Slack, and commitments."),
      "body" => read_string(brief, "body", "No briefing body was generated."),
      "metadata" => %{
        "agent_behavior" => state.assistant_behavior,
        "assistant_behavior" => state.assistant_behavior,
        "assistant_cycle_id" => context[:assistant_cycle_id],
        "origin_skill_id" => id(),
        "source_backed" => true,
        "brief_input" => compact_brief_input_for_metadata(brief_input),
        "source_health" => read_map(brief_input, "source_health")
      }
    }

    case Briefs.record(context[:user_id] || state.user_id, context[:agent_id], attrs) do
      {:ok, _brief} ->
        period_key = read_string(brief_input, "date", nil)

        {:emit,
         {:briefs_recorded,
          %{
            count: 1,
            user_id: context[:user_id] || state.user_id,
            cadences: ["morning"],
            source_backed: true
          }},
         %{
           state
           | pending_brief_input: nil,
             pending_dedupe_key: nil,
             last_generated_keys: Map.put(state.last_generated_keys, "morning", period_key)
         }}

      {:error, _reason} ->
        {:idle, %{state | pending_brief_input: nil, pending_dedupe_key: nil}}
    end
  end

  def handle_effect_result(_effect_result, state, _context), do: {:idle, state}

  @impl true
  def next_wakeup(state) do
    now = DateTime.utc_now()
    {:absolute, next_morning_occurrence(now, state)}
  end

  def build_brief_input(user_id, now, state, context) do
    source_bundle = context[:source_bundle] || %{}
    offset_hours = state.timezone_offset_hours
    local_date = local_date(now, offset_hours)
    tomorrow = Date.add(local_date, 1)
    lookback_start = DateTime.add(now, -state.lookback_hours, :hour)
    email_prompt_limit = min(state.email_scan_limit, 30)
    slack_prompt_limit = min(max(state.slack_message_scan_limit, 20), 60)

    calendar_events = SourceBundle.calendar_events(source_bundle)
    gmail_messages = SourceBundle.gmail_inbox_messages(source_bundle)
    slack_messages = SourceBundle.slack_messages(source_bundle)
    news_items = SourceBundle.news_items(source_bundle)

    recent_slack_messages =
      Enum.filter(slack_messages, &recent_slack_message?(&1, lookback_start))

    %{
      "date" => Date.to_iso8601(local_date),
      "generated_at" => DateTime.to_iso8601(now),
      "timezone_offset_hours" => offset_hours,
      "calendar" => %{
        "today_events" =>
          calendar_events
          |> Enum.filter(&event_on_date?(&1, local_date, offset_hours))
          |> Enum.map(&calendar_event_for_prompt/1)
          |> Enum.take(18),
        "tomorrow_first_event" =>
          calendar_events
          |> Enum.filter(&event_on_date?(&1, tomorrow, offset_hours))
          |> Enum.sort_by(&event_sort_key/1)
          |> List.first()
          |> calendar_event_for_prompt()
      },
      "gmail" => %{
        "recent_unread" =>
          gmail_messages
          |> Enum.filter(&recent_unread_message?(&1, lookback_start))
          |> Enum.map(&gmail_message_for_prompt/1)
          |> Enum.take(email_prompt_limit),
        "counts" => %{
          "inbox" => length(gmail_messages),
          "recent_unread" =>
            Enum.count(gmail_messages, &recent_unread_message?(&1, lookback_start))
        }
      },
      "slack" => %{
        "key_threads" =>
          slack_messages
          |> Enum.filter(&recent_slack_message?(&1, lookback_start))
          |> Enum.reject(&blank?(read_string(&1, "text", nil)))
          |> Enum.map(&slack_message_for_prompt/1)
          |> Enum.take(slack_prompt_limit),
        "mentions" => SourceBundle.slack_mentions(source_bundle) |> Enum.take(20),
        "counts" => %{
          "messages" => length(slack_messages),
          "recent_messages" => length(recent_slack_messages),
          "mentions" => length(SourceBundle.slack_mentions(source_bundle))
        }
      },
      "news" => %{
        "items" =>
          news_items
          |> Enum.map(&news_item_for_prompt/1)
          |> Enum.take(@default_news_limit),
        "counts" => %{
          "items" => length(news_items),
          "feeds" => length(SourceBundle.news_feeds(source_bundle))
        }
      },
      "commitments" =>
        Commitments.bucket_for_brief(user_id,
          now: now,
          timezone_offset_hours: offset_hours,
          limit: 50
        ),
      "open_work" => %{
        "insights" =>
          user_id
          |> Insights.list_open_act_now_for_user(limit: 12)
          |> Enum.map(&insight_for_prompt/1),
        "todos" =>
          user_id
          |> Todos.list_open_for_user(limit: 12)
          |> Enum.map(&todo_for_prompt/1)
      },
      "source_health" => SourceBundle.freshness(source_bundle)
    }
  end

  defp llm_params(brief_input) do
    %{
      "messages" => [
        %{
          "role" => "user",
          "content" => morning_prompt(brief_input)
        }
      ],
      "max_tokens" => 1800,
      "temperature" => 0.2,
      "reasoning_effort" => "medium"
    }
  end

  defp morning_prompt(brief_input) do
    """
    You are Kent's Chief of Staff. Write a source-backed morning briefing.

    Return ONLY valid JSON:
    {"title":"...","summary":"...","body":"..."}

    Briefing contract:
    - Write like a sharp Chief of Staff, not a generic digest bot.
    - Make the title specific: "<Weekday>, <Month> <day> — <plain-English read on the day>".
    - Open the body with a one-sentence temperature read that says what today's real move is.
    - Use these sections when supported by the source data: "## Needs Your Attention", "## Today's Schedule", "## Inbox", "## Slack", "## Open Commitments", "## Look Ahead".
    - Include a short "## News" section when news items are available. Keep it relevant and action-light unless it affects a real decision today.
    - Keep it action-first. For anything that needs action, say what it is and the next move in the same bullet.
    - For reply loops, include a concrete suggested reply or ETA language when source data supports it.
    - Surface counts only when useful, like "25 in last 18h", "4 need response", "8 overdue"; never include internal scores, thresholds, confidence decimals, or model/debug metadata.
    - Use simple status markers such as 🔴, 🟡, ⚠️, ✅ only when they help scanning.
    - Cross-reference meetings, emails, Slack, commitments, and todos when they point to the same obligation.
    - Do not claim a source was checked if source_health marks it unavailable.
    - Separate "needs action" from FYI/closed items. Do not bury required action under preamble.
    - End with a short "Today's move:" sentence that names the block of time or first sitting to clear the highest-leverage work.
    - 500-900 words max.

    Shape to emulate:
    # Thursday, May 7 — Light meeting day, but you owe people. Today's the day to clear the Runner ambassador backlog.

    ## Needs Your Attention
    - **Charlie's waiting on you in #runner-gtm**: "Ready to GA heartbeat, did you want to record a video?" → Yes/no this morning so the team can ship.

    ## Today's Schedule
    - **1:00** — Runner standup. Push for the heartbeat video decision live.

    ## Inbox
    **25 in last 18h** · 4 need response · rest are FYI/closed
    - 🟡 **Ivan Tolkunov** — He said yes, he can help. Send Jeff's actual question.

    ## Open Commitments
    🔴 **Overdue — mostly Runner ambassador/customer threads going cold**
    - Notify Justin Dean — Gmail connector send-bug fix shipped. Send the email today.

    Brief input JSON:
    #{Jason.encode!(brief_input)}
    """
  end

  defp parse_llm_brief(response) do
    content =
      case response do
        %{content: content} -> content
        %{"content" => content} -> content
        content when is_binary(content) -> content
        _ -> nil
      end

    with content when is_binary(content) <- content,
         {:ok, %{} = data} <- decode_json(content),
         title when is_binary(title) <- read_string(data, "title", nil),
         summary when is_binary(summary) <- read_string(data, "summary", nil),
         body when is_binary(body) <- read_string(data, "body", nil) do
      %{"title" => title, "summary" => summary, "body" => body}
    else
      _ -> nil
    end
  end

  defp fallback_brief(brief_input) do
    date = read_string(brief_input, "date", "Today")
    gmail = read_map(brief_input, "gmail")
    slack = read_map(brief_input, "slack")
    news = read_map(brief_input, "news")
    calendar = read_map(brief_input, "calendar")
    commitments = read_map(brief_input, "commitments")
    open_work = read_map(brief_input, "open_work")

    attention_items =
      []
      |> maybe_add_fallback_item(
        "🔴 #{length(commitments["overdue"] || [])} overdue #{commitment_word(length(commitments["overdue"] || []))}",
        (commitments["overdue"] || []) != []
      )
      |> maybe_add_fallback_item(
        "🟡 #{length(commitments["due_today"] || [])} #{commitment_word(length(commitments["due_today"] || []))} due today",
        (commitments["due_today"] || []) != []
      )
      |> maybe_add_fallback_item(
        "⚠️ #{length(read_list(open_work, "insights"))} open act-now insights",
        read_list(open_work, "insights") != []
      )
      |> case do
        [] -> ["Nothing high-confidence needs immediate action right now."]
        items -> items
      end

    body = """
    #{fallback_temperature_read(date, commitments, open_work)}

    ## Needs Your Attention
    #{Enum.map_join(attention_items, "\n", &"- #{&1}")}

    ## Today's Schedule
    #{fallback_event_lines(read_list(calendar, "today_events"))}

    ## Inbox
    #{fallback_email_lines(read_list(gmail, "recent_unread"))}

    ## Slack
    #{fallback_slack_lines(read_list(slack, "key_threads"))}

    ## News
    #{fallback_news_lines(read_list(news, "items"))}

    ## Open Commitments
    #{fallback_commitment_lines(commitments)}

    ## Look Ahead
    #{fallback_tomorrow_line(read_map(calendar, "tomorrow_first_event"))}

    Today's move: #{fallback_today_move(commitments, open_work)}
    """

    %{
      "title" => "#{fallback_title_date(date)} — #{fallback_title_read(commitments, open_work)}",
      "summary" =>
        "#{length(read_list(gmail, "recent_unread"))} recent unread emails, #{length(read_list(slack, "key_threads"))} Slack items, #{length(read_list(news, "items"))} news items, #{read_integer(commitments, "active_count", 0)} active commitments.",
      "body" => String.trim(body)
    }
  end

  defp fallback_event_lines([]), do: "- No calendar events found for today."

  defp fallback_event_lines(events) do
    events
    |> Enum.map_join("\n", fn event ->
      "- **#{read_string(event, "start", "Time TBD")}** — #{read_string(event, "summary", "Untitled event")}"
    end)
  end

  defp fallback_email_lines([]), do: "- No recent unread inbox messages surfaced."

  defp fallback_email_lines(messages) do
    messages
    |> Enum.take(7)
    |> Enum.map_join("\n", fn message ->
      "- **#{read_string(message, "from", "Unknown")}** — \"#{read_string(message, "subject", "No subject")}\" — #{read_string(message, "classification", "review")}"
    end)
  end

  defp fallback_slack_lines([]), do: "- No key Slack messages surfaced."

  defp fallback_slack_lines(messages) do
    messages
    |> Enum.take(7)
    |> Enum.map_join("\n", fn message ->
      "- **##{read_string(message, "channel_name", "slack")}** — #{truncate(read_string(message, "text", ""), 140)}"
    end)
  end

  defp fallback_news_lines([]), do: "- No configured news feeds surfaced items."

  defp fallback_news_lines(items) do
    items
    |> Enum.take(5)
    |> Enum.map_join("\n", fn item ->
      source = read_string(item, "source", "News")
      title = read_string(item, "title", "Untitled")
      summary = read_string(item, "summary", nil)

      [
        "- **#{source}** — #{title}",
        if(summary, do: ": #{truncate(summary, 140)}")
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join("")
    end)
  end

  defp fallback_commitment_lines(commitments) do
    overdue = read_list(commitments, "overdue")
    due_today = read_list(commitments, "due_today")
    coming_up = read_list(commitments, "coming_up")
    active_count = read_integer(commitments, "active_count", length(overdue) + length(due_today))

    cond do
      overdue != [] ->
        """
        **#{active_count} active** · 🔴 **#{length(overdue)} overdue**
        #{overdue |> Enum.take(8) |> Enum.map_join("\n", &fallback_commitment_line(&1, "🔴"))}
        """
        |> String.trim()

      due_today != [] ->
        """
        **#{active_count} active** · 🟡 **#{length(due_today)} due today**
        #{due_today |> Enum.take(8) |> Enum.map_join("\n", &fallback_commitment_line(&1, "🟡"))}
        """
        |> String.trim()

      coming_up != [] ->
        """
        **#{active_count} active** · 📋 **#{length(coming_up)} coming up**
        #{coming_up |> Enum.take(8) |> Enum.map_join("\n", &fallback_commitment_line(&1, "📋"))}
        """
        |> String.trim()

      true ->
        "- No open commitments surfaced."
    end
  end

  defp fallback_commitment_line(commitment, marker) do
    title = read_string(commitment, "title", "Open commitment")
    project = read_string(commitment, "project", nil)
    owed_to = read_string(commitment, "owed_to", nil)
    metadata = read_map(commitment, "metadata")

    action =
      read_string(commitment, "next_action", nil) ||
        read_string(metadata, "next_action", nil) ||
        read_string(read_map(metadata, "record"), "next_action", nil)

    context =
      [project, owed_to && "owed to #{owed_to}"]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(" · ")

    [
      "- #{marker} #{title}",
      if(context != "", do: " · #{context}"),
      if(action, do: " → #{action}")
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("")
  end

  defp fallback_temperature_read(date, commitments, open_work) do
    overdue_count = length(read_list(commitments, "overdue"))
    due_today_count = length(read_list(commitments, "due_today"))

    open_work_count =
      length(read_list(open_work, "insights")) + length(read_list(open_work, "todos"))

    cond do
      overdue_count > 0 ->
        "#{fallback_title_date(date)} has #{overdue_count} overdue commitment#{plural_suffix(overdue_count)}. Start there before the inbox gets louder."

      due_today_count > 0 ->
        "#{fallback_title_date(date)} has #{due_today_count} commitment#{plural_suffix(due_today_count)} due today. Clear or reset those first."

      open_work_count > 0 ->
        "#{fallback_title_date(date)} has #{open_work_count} open action item#{plural_suffix(open_work_count)}. Pick the one with a real person waiting."

      true ->
        "#{fallback_title_date(date)} looks clear. Use the first focused block to prevent new open loops."
    end
  end

  defp fallback_today_move(commitments, open_work) do
    cond do
      read_list(commitments, "overdue") != [] ->
        "clear the oldest overdue commitment, then send short ETA resets for anything that cannot be finished today."

      read_list(commitments, "due_today") != [] ->
        "handle the commitments due today before opening new work."

      read_list(open_work, "insights") != [] ->
        "resolve the highest-priority act-now insight, then refresh the list."

      read_list(open_work, "todos") != [] ->
        "close the highest-priority todo with a human counterparty."

      true ->
        "protect the first focused block and keep the day from accumulating reply debt."
    end
  end

  defp fallback_title_read(commitments, open_work) do
    cond do
      read_list(commitments, "overdue") != [] ->
        "Clear the oldest overdue commitments first."

      read_list(commitments, "due_today") != [] ->
        "Due-today commitments set the pace."

      read_list(open_work, "insights") != [] or read_list(open_work, "todos") != [] ->
        "Action list is manageable if you start with the human loops."

      true ->
        "Clean slate, but protect the focus block."
    end
  end

  defp fallback_title_date(date) when is_binary(date) do
    case Date.from_iso8601(date) do
      {:ok, parsed} -> Calendar.strftime(parsed, "%A, %B %-d")
      _ -> date
    end
  end

  defp plural_suffix(1), do: ""
  defp plural_suffix(_count), do: "s"

  defp commitment_word(1), do: "commitment"
  defp commitment_word(_count), do: "commitments"

  defp fallback_tomorrow_line(%{} = event) when event != %{} do
    "- Tomorrow starts with #{read_string(event, "summary", "an event")} at #{read_string(event, "start", "time TBD")}."
  end

  defp fallback_tomorrow_line(_event), do: "- No first event for tomorrow was found."

  defp calendar_event_for_prompt(nil), do: nil

  defp calendar_event_for_prompt(event) when is_map(event) do
    %{
      "event_id" => read_string(event, "event_id", nil),
      "summary" => read_string(event, "summary", "Untitled event"),
      "start" => prompt_time(read_any(event, "start")),
      "end" => prompt_time(read_any(event, "end")),
      "location" => read_string(event, "location", nil),
      "attendees" => read_list(event, "attendees") |> Enum.take(12),
      "organizer" => read_string(event, "organizer", nil),
      "html_link" => read_string(event, "html_link", nil)
    }
  end

  defp gmail_message_for_prompt(message) when is_map(message) do
    %{
      "message_id" => read_string(message, "message_id", nil),
      "thread_id" => read_string(message, "thread_id", nil),
      "account" =>
        read_string(message, "account", read_string(message, "google_account_email", nil)),
      "from" => read_string(message, "from", nil),
      "to" => read_string(message, "to", nil),
      "subject" => read_string(message, "subject", "(no subject)"),
      "date" =>
        prompt_time(read_any(message, "internal_date")) || read_string(message, "date", nil),
      "labels" => read_list(message, "labels"),
      "snippet" => truncate(read_string(message, "snippet", ""), 240),
      "classification" => classify_email(message)
    }
  end

  defp slack_message_for_prompt(message) when is_map(message) do
    %{
      "team_name" => read_string(message, "team_name", nil),
      "channel_id" => read_string(message, "channel_id", nil),
      "channel_name" => read_string(message, "channel_name", nil),
      "conversation_kind" => read_string(message, "conversation_kind", nil),
      "user" => read_string(message, "user", nil),
      "ts" => read_string(message, "ts", nil),
      "thread_ts" => read_string(message, "thread_ts", nil),
      "text" => truncate(read_string(message, "text", ""), 260),
      "reply_count" => read_integer(message, "reply_count", 0)
    }
  end

  defp news_item_for_prompt(item) when is_map(item) do
    %{
      "source" => read_string(item, "source", nil),
      "title" => read_string(item, "title", nil),
      "summary" => truncate(read_string(item, "summary", ""), 220),
      "url" => read_string(item, "url", nil),
      "published_at" => read_string(item, "published_at", nil)
    }
  end

  defp insight_for_prompt(insight) do
    %{
      "id" => insight.id,
      "source" => insight.source,
      "category" => insight.category,
      "title" => insight.title,
      "summary" => insight.summary,
      "recommended_action" => insight.recommended_action,
      "priority" => insight.priority,
      "due_at" => prompt_time(insight.due_at)
    }
  end

  defp todo_for_prompt(todo) do
    %{
      "id" => todo.id,
      "source" => todo.source,
      "kind" => todo.kind,
      "title" => todo.title,
      "summary" => todo.summary,
      "next_action" => todo.next_action,
      "priority" => todo.priority,
      "source_occurred_at" => prompt_time(todo.source_occurred_at)
    }
  end

  defp recent_unread_message?(message, lookback_start) when is_map(message) do
    labels = read_list(message, "labels") |> Enum.map(&to_string/1)
    internal_date = read_datetime(message, "internal_date")

    "UNREAD" in labels and
      (is_nil(internal_date) or DateTime.compare(internal_date, lookback_start) != :lt)
  end

  defp recent_slack_message?(message, lookback_start) when is_map(message) do
    case read_slack_datetime(message, "ts") do
      nil -> true
      timestamp -> DateTime.compare(timestamp, lookback_start) != :lt
    end
  end

  defp recent_slack_message?(_message, _lookback_start), do: false

  defp event_on_date?(event, date, offset_hours) when is_map(event) do
    event
    |> read_any("start")
    |> local_date_from_value(offset_hours)
    |> case do
      ^date -> true
      _ -> false
    end
  end

  defp event_on_date?(_event, _date, _offset_hours), do: false

  defp event_sort_key(event) when is_map(event) do
    case read_any(event, "start") do
      %DateTime{} = value -> DateTime.to_unix(value, :microsecond)
      %{"date" => value} when is_binary(value) -> value
      value when is_binary(value) -> value
      _ -> 0
    end
  end

  defp classify_email(message) do
    text =
      [
        read_string(message, "from", ""),
        read_string(message, "subject", ""),
        read_string(message, "snippet", "")
      ]
      |> Enum.join(" ")
      |> String.downcase()

    cond do
      String.contains?(text, ["login", "security", "verification", "password"]) -> "security"
      String.contains?(text, ["invoice", "billing", "price", "plan", "subscription"]) -> "billing"
      String.contains?(text, ["urgent", "today", "asap", "deadline"]) -> "time-sensitive"
      String.contains?(text, ["newsletter", "sale", "promo", "discount"]) -> "promotional"
      true -> "review"
    end
  end

  defp compact_brief_input_for_metadata(input) do
    %{
      "date" => read_string(input, "date", nil),
      "generated_at" => read_string(input, "generated_at", nil),
      "counts" => %{
        "gmail_recent_unread" => length(get_in(input, ["gmail", "recent_unread"]) || []),
        "slack_key_threads" => length(get_in(input, ["slack", "key_threads"]) || []),
        "news_items" => length(get_in(input, ["news", "items"]) || []),
        "commitments_active" => get_in(input, ["commitments", "active_count"]) || 0,
        "insights" => length(get_in(input, ["open_work", "insights"]) || []),
        "todos" => length(get_in(input, ["open_work", "todos"]) || [])
      }
    }
  end

  defp due_now?(now, state) do
    local_now = DateTime.add(now, state.timezone_offset_hours, :hour)
    local_now.hour >= state.morning_hour
  end

  defp next_morning_occurrence(now, state) do
    local_now = DateTime.add(now, state.timezone_offset_hours, :hour)
    local_date = DateTime.to_date(local_now)

    scheduled_today =
      local_date
      |> DateTime.new!(Time.new!(state.morning_hour, 0, 0), "Etc/UTC")

    target_local =
      if DateTime.compare(local_now, scheduled_today) == :lt do
        scheduled_today
      else
        Date.add(local_date, 1)
        |> DateTime.new!(Time.new!(state.morning_hour, 0, 0), "Etc/UTC")
      end

    DateTime.add(target_local, -state.timezone_offset_hours, :hour)
  end

  defp local_period_key(now, offset_hours) do
    now
    |> local_date(offset_hours)
    |> Date.to_iso8601()
  end

  defp local_date(%DateTime{} = now, offset_hours) do
    now
    |> DateTime.add(offset_hours, :hour)
    |> DateTime.to_date()
  end

  defp local_date_from_value(%DateTime{} = value, offset_hours),
    do: local_date(value, offset_hours)

  defp local_date_from_value(%{"date" => date}, _offset_hours) when is_binary(date) do
    case Date.from_iso8601(date) do
      {:ok, parsed} -> parsed
      _ -> nil
    end
  end

  defp local_date_from_value(value, offset_hours) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> local_date(datetime, offset_hours)
      _ -> nil
    end
  end

  defp local_date_from_value(_value, _offset_hours), do: nil

  defp decode_json(content) when is_binary(content) do
    content
    |> String.trim()
    |> String.trim_leading("```json")
    |> String.trim_leading("```")
    |> String.trim_trailing("```")
    |> String.trim()
    |> Jason.decode()
  end

  defp maybe_add_fallback_item(list, item, true), do: list ++ [item]
  defp maybe_add_fallback_item(list, _item, false), do: list

  defp prompt_time(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp prompt_time(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  defp prompt_time(%{"date" => date}) when is_binary(date), do: date
  defp prompt_time(value) when is_binary(value), do: value
  defp prompt_time(_value), do: nil

  defp read_any(map, key) when is_map(map),
    do: Map.get(map, key, Map.get(map, to_existing_atom(key)))

  defp read_any(_map, _key), do: nil

  defp read_map(map, key) when is_map(map) do
    case read_any(map, key) do
      value when is_map(value) -> value
      _ -> %{}
    end
  end

  defp read_map(_map, _key), do: %{}

  defp read_list(map, key) when is_map(map) do
    case read_any(map, key) do
      value when is_list(value) -> value
      _ -> []
    end
  end

  defp read_list(_map, _key), do: []

  defp read_string(map, key, default) when is_map(map) do
    case read_any(map, key) do
      value when is_binary(value) ->
        trimmed = String.trim(value)
        if trimmed == "", do: default, else: trimmed

      nil ->
        default

      value ->
        to_string(value)
    end
  end

  defp read_string(_map, _key, default), do: default

  defp read_integer(map, key, default) when is_map(map) do
    case read_any(map, key) do
      value when is_integer(value) ->
        value

      value when is_binary(value) ->
        case Integer.parse(value) do
          {parsed, _} -> parsed
          _ -> default
        end

      _ ->
        default
    end
  end

  defp read_integer(_map, _key, default), do: default

  defp read_datetime(map, key) when is_map(map) do
    case read_any(map, key) do
      %DateTime{} = value ->
        value

      %NaiveDateTime{} = value ->
        DateTime.from_naive!(value, "Etc/UTC")

      value when is_binary(value) ->
        case DateTime.from_iso8601(value) do
          {:ok, datetime, _offset} -> datetime
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp read_slack_datetime(map, key) when is_map(map) do
    case read_any(map, key) do
      value when is_binary(value) ->
        value
        |> Float.parse()
        |> case do
          {seconds, _rest} -> DateTime.from_unix(trunc(seconds), :second)
          :error -> {:error, :invalid_timestamp}
        end
        |> case do
          {:ok, datetime} -> datetime
          _ -> nil
        end

      value when is_integer(value) ->
        case DateTime.from_unix(value, :second) do
          {:ok, datetime} -> datetime
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp read_slack_datetime(_map, _key), do: nil

  defp blank?(nil), do: true
  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(_value), do: false

  defp truncate(nil, _limit), do: ""

  defp truncate(value, limit) when is_binary(value) do
    if String.length(value) > limit do
      String.slice(value, 0, limit) <> "..."
    else
      value
    end
  end

  defp normalize_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      normalized -> normalized
    end
  end

  defp normalize_string(_value), do: nil

  defp integer_in_range(value, default, min, max) do
    value
    |> parse_integer(default)
    |> max(min)
    |> min(max)
  end

  defp parse_integer(value, _default) when is_integer(value), do: value

  defp parse_integer(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, _} -> parsed
      _ -> default
    end
  end

  defp parse_integer(_value, default), do: default

  defp to_existing_atom(key) when is_binary(key) do
    try do
      String.to_existing_atom(key)
    rescue
      ArgumentError -> nil
    end
  end

  defp to_existing_atom(key), do: key
end
