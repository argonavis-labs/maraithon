defmodule Maraithon.ChiefOfStaff.Skills.MorningBriefing do
  @moduledoc """
  Source-backed daily Chief of Staff morning brief.
  """

  @behaviour Maraithon.ChiefOfStaff.Skill

  alias Maraithon.AgentHarness.MarkdownSkill
  alias Maraithon.Briefs
  alias Maraithon.ChiefOfStaff.Acquisition
  alias Maraithon.ChiefOfStaff.SourceBundle
  alias Maraithon.ChiefOfStaff.MeetingEnrichment
  alias Maraithon.Commitments
  alias Maraithon.Companion
  alias Maraithon.ConnectedAccounts
  alias Maraithon.Crm
  alias Maraithon.Insights
  alias Maraithon.LocalBrowserHistory
  alias Maraithon.LocalCalendar
  alias Maraithon.LocalFiles
  alias Maraithon.LocalMessages
  alias Maraithon.LocalNotes
  alias Maraithon.LocalReminders
  alias Maraithon.LocalVoiceMemos
  alias Maraithon.Memory
  alias Maraithon.Spend
  alias Maraithon.OpenLoops
  alias Maraithon.Todos

  require Logger

  @default_timezone_offset_hours -5
  @default_morning_hour 8
  @default_morning_minute 0
  @default_email_scan_limit 100
  @default_slack_channel_scan_limit 16
  @default_slack_message_scan_limit 100
  @default_news_limit 25
  @default_lookback_hours 18
  @default_llm_max_tokens 64_000
  @default_llm_reasoning_effort "xhigh"
  @default_llm_timeout_ms 1_200_000
  @commercial_thread_lookback_hours 24 * 7
  @skill_path "priv/agents/skills/chief_of_staff/morning_briefing.md"
  @prompt_string_limit 1_000_000
  @prompt_default_list_limit 10_000
  @commercial_thread_terms [
    "availability",
    "connect",
    "customer",
    "discount",
    "enterprise",
    "glossier",
    "intro",
    "introduction",
    "pricing",
    "prospect",
    "team plan",
    "ultra plan"
  ]
  @commercial_counterparty_domain_markers ~w(cogniate glossier represent sandwich.co)
  @commercial_teammate_domains ~w(runner.now)
  @local_imessage_chat_limit 100
  @local_notes_limit 100
  @local_voice_memo_limit 100
  @local_calendar_limit 500
  @local_reminders_days_ahead 7
  @local_reminders_limit 100
  @local_files_limit 100
  @local_browser_visits_limit 500
  @local_browser_top_hosts 25
  @local_files_allowed_extensions ~w(pdf md txt rtf rtfd docx pages key keynote ppt pptx xls xlsx csv numbers doc)
  @device_stale_seconds 2 * 60 * 60
  @telegram_chunk_limit 3_300

  @impl true
  def id, do: "morning_briefing"

  @impl true
  def label, do: "Morning briefing"

  @impl true
  def description, do: "Builds the daily Chief of Staff briefing and sends it through Telegram."

  @impl true
  def default_config do
    %{
      "assistant_behavior" => "ai_chief_of_staff",
      "timezone_offset_hours" => @default_timezone_offset_hours,
      "morning_brief_hour_local" => @default_morning_hour,
      "morning_brief_minute_local" => @default_morning_minute,
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
      "llm_max_tokens" => @default_llm_max_tokens,
      "llm_reasoning_effort" => @default_llm_reasoning_effort,
      "llm_timeout_ms" => @default_llm_timeout_ms,
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
      timezone: normalize_timezone(config["timezone"] || config["timezone_name"]),
      timezone_offset_hours:
        integer_in_range(config["timezone_offset_hours"], @default_timezone_offset_hours, -12, 14),
      morning_hour:
        integer_in_range(config["morning_brief_hour_local"], @default_morning_hour, 0, 23),
      morning_minute:
        integer_in_range(config["morning_brief_minute_local"], @default_morning_minute, 0, 59),
      email_scan_limit:
        integer_in_range(config["email_scan_limit"], @default_email_scan_limit, 1, 500),
      slack_message_scan_limit:
        integer_in_range(
          config["slack_message_scan_limit"],
          @default_slack_message_scan_limit,
          1,
          500
        ),
      lookback_hours: integer_in_range(config["lookback_hours"], @default_lookback_hours, 1, 168),
      llm_model: normalize_string(config["llm_model"]),
      llm_max_tokens:
        integer_in_range(
          config["llm_max_tokens"],
          @default_llm_max_tokens,
          256,
          @default_llm_max_tokens
        ),
      llm_reasoning_effort:
        normalize_reasoning_effort(config["llm_reasoning_effort"], @default_llm_reasoning_effort),
      llm_timeout_ms:
        integer_in_range(config["llm_timeout_ms"], @default_llm_timeout_ms, 30_000, 1_200_000),
      pending_brief_input: nil,
      pending_dedupe_key: nil,
      last_generated_keys: %{}
    }
  end

  @impl true
  def handle_wakeup(state, context) do
    user_id = state.user_id || normalize_string(context[:user_id])
    now = context[:timestamp] || DateTime.utc_now()
    period_key = local_period_key(now, state)
    dedupe_key = "morning_briefing:#{period_key}"

    cond do
      is_nil(user_id) ->
        {:idle, state}

      ConnectedAccounts.telegram_destination(user_id) == nil ->
        {:idle, %{state | user_id: user_id}}

      Map.get(state.last_generated_keys, "morning") == period_key ->
        {:idle, %{state | user_id: user_id}}

      not due_now?(now, state) ->
        {:idle, %{state | user_id: user_id}}

      true ->
        brief_input = build_brief_input(user_id, now, state, context)

        pending_state = %{
          state
          | user_id: user_id,
            pending_brief_input: brief_input,
            pending_dedupe_key: dedupe_key
        }

        case llm_params(brief_input, state) do
          {:ok, params} ->
            {:effect, {:llm_call, params}, pending_state}

          {:error, reason} ->
            handle_effect_result(
              {:llm_call, %{content: "", error: inspect(reason), finish_reason: "error"}},
              pending_state,
              context
            )
        end
    end
  end

  @impl true
  def handle_effect_result({:llm_call, response}, state, context) do
    brief_input = state.pending_brief_input || %{}
    parsed_brief = parse_llm_brief(response)
    {brief, generation_mode, error_message} = brief_or_error_notice(parsed_brief, response)
    cost_summary = briefing_cost_summary(response, brief_input)

    attrs = %{
      "cadence" => "morning",
      "scheduled_for" =>
        read_string(brief_input, "generated_at", DateTime.utc_now() |> DateTime.to_iso8601()),
      "dedupe_key" =>
        state.pending_dedupe_key ||
          "morning_briefing:#{read_string(brief_input, "date", "unknown")}",
      "status" => "pending",
      "title" => read_string(brief, "title", "Morning briefing"),
      "summary" =>
        read_string(brief, "summary", "Review today's schedule, inbox, Slack, and commitments."),
      "body" => read_string(brief, "body", "No briefing body was generated."),
      "error_message" => error_message,
      "metadata" => %{
        "agent_behavior" => state.assistant_behavior,
        "assistant_behavior" => state.assistant_behavior,
        "assistant_cycle_id" => context[:assistant_cycle_id],
        "error_message" => error_message,
        "generation_mode" => generation_mode,
        "llm_finish_reason" => llm_finish_reason(response),
        "llm_usage" => json_metadata(response_usage(response)),
        "estimated_cost" => json_metadata(cost_summary),
        "origin_skill_id" => id(),
        "source_backed" => true,
        "brief_input" => compact_brief_input_for_metadata(brief_input),
        "source_health" => read_map(brief_input, "source_health")
      }
    }

    case Briefs.record(context[:user_id] || state.user_id, context[:agent_id], attrs) do
      {:ok, brief_record} ->
        period_key = read_string(brief_input, "date", nil)

        {todo_result, todo_elapsed_ms} =
          timed(fn ->
            persist_model_todos(context[:user_id] || state.user_id, brief, brief_input)
          end)

        event_type =
          if generation_mode == "llm", do: :briefs_recorded, else: :brief_generation_failed

        todo_payload =
          todo_result
          |> todo_event_payload()
          |> Map.put(:todo_persistence_elapsed_ms, todo_elapsed_ms)

        {:emit,
         {event_type,
          %{
            count: 1,
            error_message: error_message,
            generation_mode: generation_mode,
            user_id: context[:user_id] || state.user_id,
            cadences: ["morning"],
            source_backed: true,
            brief_id: brief_record.id
          }
          |> Map.merge(todo_payload)},
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
  def handle_effect_error(:llm_call, reason, state, context) do
    handle_effect_result(
      {:llm_call,
       %{
         content: "",
         error: inspect(reason),
         finish_reason: "error"
       }},
      state,
      context
    )
  end

  def handle_effect_error(_effect_type, _reason, state, _context), do: {:idle, state}

  @impl true
  def next_wakeup(state) do
    now = DateTime.utc_now()
    {:absolute, next_morning_occurrence(now, state)}
  end

  def build_brief_input(user_id, now, state, context) do
    source_bundle = context[:source_bundle] || %{}
    offset_hours = state.timezone_offset_hours
    local_date = local_date(now, state)
    local_day_start = local_day_start_utc(local_date, state)
    tomorrow = Date.add(local_date, 1)
    lookback_start = DateTime.add(now, -state.lookback_hours, :hour)
    commercial_lookback_start = DateTime.add(now, -@commercial_thread_lookback_hours, :hour)

    # Merge the local Calendar.app mirror with Google Calendar. The local
    # mirror can be stale or unavailable on remote runs, while Google may
    # omit non-Google accounts; neither source should suppress the other.
    google_calendar_events = SourceBundle.calendar_events(source_bundle)
    bundle_local_calendar = SourceBundle.calendar_local_events(source_bundle)

    {local_calendar_events, local_calendar_error} =
      fetch_local_source(user_id, :calendar_local, bundle_local_calendar, fn id ->
        LocalCalendar.events_around(id,
          since: local_day_start,
          until: DateTime.add(local_day_start, 72 * 3_600, :second),
          limit: @local_calendar_limit
        )
      end)

    local_calendar_events =
      local_calendar_events
      |> Enum.map(&local_event_to_prompt/1)
      |> Enum.reject(&is_nil/1)

    calendar_events =
      (local_calendar_events ++ google_calendar_events)
      |> dedupe_calendar_events()
      |> Enum.sort_by(&event_sort_key/1)

    calendar_source =
      cond do
        local_calendar_events != [] and google_calendar_events != [] -> "local+google"
        local_calendar_events != [] -> "local"
        google_calendar_events != [] -> "google"
        true -> "none"
      end

    gmail_messages = SourceBundle.gmail_messages(source_bundle)
    gmail_inbox_messages = SourceBundle.gmail_inbox_messages(source_bundle)
    slack_messages = SourceBundle.slack_messages(source_bundle)
    news_items = SourceBundle.news_items(source_bundle)

    recent_slack_messages =
      Enum.filter(slack_messages, &recent_slack_message?(&1, lookback_start))

    bundle_imessage_chats = SourceBundle.imessage_chats(source_bundle)

    {imessage_chats, imessage_error} =
      fetch_local_source(user_id, :imessage, bundle_imessage_chats, fn id ->
        LocalMessages.chats_recent(id, limit: @local_imessage_chat_limit, now: now)
      end)

    bundle_notes = SourceBundle.notes(source_bundle)

    {notes, notes_error} =
      fetch_local_source(user_id, :notes, bundle_notes, fn id ->
        LocalNotes.recent_for_user(id, limit: @local_notes_limit)
      end)

    bundle_memos = SourceBundle.voice_memos(source_bundle)

    {voice_memos, voice_memos_error} =
      fetch_local_source(user_id, :voice_memos, bundle_memos, fn id ->
        LocalVoiceMemos.recent_for_user(id, limit: @local_voice_memo_limit)
      end)

    bundle_reminders = SourceBundle.reminders(source_bundle)

    {reminders, reminders_error} =
      fetch_local_source(user_id, :reminders, bundle_reminders, fn id ->
        LocalReminders.due_soon(id,
          days_ahead: @local_reminders_days_ahead,
          limit: @local_reminders_limit
        )
      end)

    bundle_files = SourceBundle.files(source_bundle)

    {files, files_error} =
      fetch_local_source(user_id, :files, bundle_files, fn id ->
        id
        |> LocalFiles.recent_for_user(limit: @local_files_limit * 6)
        |> Enum.filter(&allowed_file_extension?/1)
      end)

    bundle_visits = SourceBundle.browser_visits(source_bundle)

    {visits, browser_history_error} =
      fetch_local_source(user_id, :browser_history, bundle_visits, fn id ->
        LocalBrowserHistory.recent_visits(id, limit: @local_browser_visits_limit)
      end)

    top_hosts = top_browser_hosts(visits, now, @local_browser_top_hosts)

    commercial_thread_messages =
      gmail_messages
      |> Enum.filter(&recent_gmail_message?(&1, commercial_lookback_start))
      |> Enum.filter(&commercial_thread_candidate?/1)
      |> Enum.uniq_by(&commercial_thread_key/1)
      |> Enum.sort_by(&commercial_thread_sort_key/1, :desc)

    commercial_threads =
      commercial_thread_messages
      |> Enum.map(&gmail_message_for_prompt/1)

    local_source_errors =
      [
        calendar_local: local_calendar_error,
        imessage: imessage_error,
        notes: notes_error,
        voice_memos: voice_memos_error,
        reminders: reminders_error,
        files: files_error,
        browser_history: browser_history_error
      ]
      |> Enum.reject(fn {_source, error} -> is_nil(error) end)
      |> Map.new()

    today_events =
      calendar_events
      |> Enum.filter(&event_on_date?(&1, local_date, state))
      |> Enum.map(&calendar_event_for_prompt(&1, state))
      |> Enum.reject(&is_nil/1)

    tomorrow_first_event =
      calendar_events
      |> Enum.filter(&event_on_date?(&1, tomorrow, state))
      |> Enum.sort_by(&event_sort_key/1)
      |> List.first()
      |> calendar_event_for_prompt(state)

    meeting_prep =
      MeetingEnrichment.enrich(user_id, today_events,
        now: now,
        max_web_queries: 100
      )

    schedule_coverage = schedule_coverage_contract(meeting_prep)

    %{
      "date" => Date.to_iso8601(local_date),
      "generated_at" => DateTime.to_iso8601(now),
      "timezone_offset_hours" => offset_hours,
      "timezone" => timezone_label(state, now),
      "calendar" => %{
        "preferred_source" => calendar_source,
        "today_events" => today_events,
        "tomorrow_first_event" => tomorrow_first_event,
        "upcoming_local" =>
          local_calendar_events
          |> Enum.map(&calendar_event_for_prompt(&1, state))
      },
      "meeting_prep" => meeting_prep,
      "schedule_coverage" => schedule_coverage,
      "commercial_coverage" => commercial_coverage_contract(commercial_threads),
      "imessage" => %{
        "chats" =>
          imessage_chats
          |> Enum.map(&imessage_chat_for_prompt/1),
        "counts" => %{"chats" => length(imessage_chats)}
      },
      "notes" => %{
        "items" =>
          notes
          |> Enum.map(&note_for_prompt/1),
        "counts" => %{"count" => length(notes)}
      },
      "voice_memos" => %{
        "items" =>
          voice_memos
          |> Enum.map(&voice_memo_for_prompt/1),
        "counts" => %{"count" => length(voice_memos)}
      },
      "reminders" => %{
        "due_soon" =>
          reminders
          |> Enum.map(&reminder_for_prompt/1),
        "counts" => %{
          "open" => length(reminders),
          "due_today" => Enum.count(reminders, &reminder_due_today?(&1, now))
        }
      },
      "files" => %{
        "items" =>
          files
          |> Enum.map(&file_for_prompt/1),
        "counts" => %{"recent_count" => length(files)}
      },
      "browser_history" => %{
        "top_hosts" => top_hosts,
        "counts" => %{
          "visits_last_24h" =>
            Enum.count(visits, fn visit ->
              within_last_24h?(visit_last_visited_at(visit), now)
            end)
        }
      },
      "gmail" => %{
        "commercial_threads" => commercial_threads,
        "recent_inbox" =>
          gmail_inbox_messages
          |> Enum.filter(&recent_gmail_message?(&1, lookback_start))
          |> Enum.map(&gmail_message_for_prompt/1),
        "recent_unread" =>
          gmail_inbox_messages
          |> Enum.filter(&recent_unread_message?(&1, lookback_start))
          |> Enum.map(&gmail_message_for_prompt/1),
        "counts" => %{
          "messages" => length(gmail_messages),
          "inbox" => length(gmail_inbox_messages),
          "commercial_threads" => length(commercial_thread_messages),
          "recent_inbox" =>
            Enum.count(gmail_inbox_messages, &recent_gmail_message?(&1, lookback_start)),
          "recent_unread" =>
            Enum.count(gmail_inbox_messages, &recent_unread_message?(&1, lookback_start))
        }
      },
      "slack" => %{
        "key_threads" =>
          slack_messages
          |> Enum.filter(&recent_slack_message?(&1, lookback_start))
          |> Enum.reject(&blank?(read_string(&1, "text", nil)))
          |> Enum.map(&slack_message_for_prompt/1),
        "mentions" => SourceBundle.slack_mentions(source_bundle),
        "counts" => %{
          "messages" => length(slack_messages),
          "recent_messages" => length(recent_slack_messages),
          "mentions" => length(SourceBundle.slack_mentions(source_bundle))
        }
      },
      "news" => %{
        "items" =>
          news_items
          |> Enum.map(&news_item_for_prompt/1),
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
          |> Insights.list_open_act_now_for_user(limit: 100)
          |> Enum.map(&insight_for_prompt/1),
        "todos" =>
          user_id
          |> Todos.list_open_for_user(limit: 100)
          |> Enum.map(&todo_for_prompt/1)
      },
      "relationships" =>
        user_id
        |> Crm.summarize_for_prompt(100),
      "deep_memory" =>
        user_id
        |> Memory.prompt_context(query: "morning briefing chief of staff relevance", limit: 100),
      "source_health" =>
        source_bundle
        |> SourceBundle.freshness()
        |> merge_local_source_health(
          user_id,
          now,
          [
            imessage: imessage_chats,
            notes: notes,
            voice_memos: voice_memos,
            calendar_local: local_calendar_events,
            reminders: reminders,
            files: files,
            browser_history: visits
          ],
          local_source_errors
        )
    }
  end

  @doc """
  Smoke-test the morning briefing pipeline end-to-end without an agent
  process. Loads the named agent's morning_briefing config, builds the
  prompt against current connector state, calls the LLM, validates the
  response, and returns `{:ok, brief}` or `{:error, reason, diagnostics}`.

  When `send: true` is passed in opts, the validated brief is delivered
  to the user's Telegram destination so we can confirm end-to-end.
  """
  def smoke_test(agent_id, opts \\ []) when is_binary(agent_id) and is_list(opts) do
    agent = Maraithon.Repo.get!(Maraithon.Agents.Agent, agent_id)
    user_id = smoke_test_user_id(agent)

    if is_nil(user_id) do
      {:error, :no_user_id, %{}}
    else
      skill_config = smoke_test_skill_config(agent, user_id)
      state = init(skill_config)
      now = Keyword.get(opts, :now, DateTime.utc_now())
      total_started_ms = System.monotonic_time(:millisecond)

      {context, source_context_elapsed_ms} =
        timed(fn -> smoke_test_context(agent, user_id, skill_config, now, opts) end)

      {brief_input, input_build_elapsed_ms} =
        timed(fn -> build_brief_input(user_id, now, state, context) end)

      case llm_params(brief_input, state) do
        {:ok, params} ->
          started_ms = System.monotonic_time(:millisecond)

          case Maraithon.LLM.complete(params) do
            {:ok, response} ->
              elapsed_ms = System.monotonic_time(:millisecond) - started_ms
              parsed = parse_llm_brief(response)

              diagnostics = %{
                model: response.model,
                tokens_in: response.tokens_in,
                tokens_out: response.tokens_out,
                finish_reason: response.finish_reason,
                elapsed_ms: elapsed_ms,
                briefing_llm_elapsed_ms: elapsed_ms,
                source_context_elapsed_ms: source_context_elapsed_ms,
                input_build_elapsed_ms: input_build_elapsed_ms,
                max_tokens_used: effective_llm_max_tokens(state),
                reasoning_effort_used: state.llm_reasoning_effort,
                llm_usage: response_usage(response),
                estimated_cost: briefing_cost_summary(response, brief_input),
                calendar_today_events:
                  length(get_in(brief_input, ["calendar", "today_events"]) || []),
                commercial_coverage_required_threads:
                  get_in(brief_input, ["commercial_coverage", "counts", "required_threads"]) || 0,
                meeting_prep_counts: get_in(brief_input, ["meeting_prep", "counts"]),
                source_acquisition:
                  if(Map.has_key?(context, :assistant_fetch_telemetry),
                    do: "acquired",
                    else: "provided"
                  )
              }

              case parsed do
                {:ok, brief} ->
                  {todo_result, todo_elapsed_ms} =
                    if Keyword.get(opts, :persist_todos, Keyword.get(opts, :send, false)) do
                      timed(fn -> persist_model_todos(user_id, brief, brief_input) end)
                    else
                      {{:ok, :no_todos}, 0}
                    end

                  diagnostics =
                    diagnostics
                    |> Map.put(:todo_persistence, todo_event_payload(todo_result))
                    |> Map.put(:todo_persistence_elapsed_ms, todo_elapsed_ms)

                  {delivery_result, delivery_elapsed_ms} =
                    if Keyword.get(opts, :send, false) do
                      timed(fn -> deliver_smoke_brief(user_id, brief, diagnostics) end)
                    else
                      {{:ok, :not_sent}, 0}
                    end

                  diagnostics =
                    diagnostics
                    |> Map.put(:telegram_delivery, delivery_event_payload(delivery_result))
                    |> Map.put(:telegram_delivery_elapsed_ms, delivery_elapsed_ms)
                    |> Map.put(:total_elapsed_ms, elapsed_since_ms(total_started_ms))

                  result = {:ok, brief, diagnostics}

                  result

                {:error, reason} ->
                  diagnostics =
                    Map.put(diagnostics, :total_elapsed_ms, elapsed_since_ms(total_started_ms))

                  {:error, {:invalid_brief, reason}, diagnostics}
              end

            {:error, reason} ->
              elapsed_ms = System.monotonic_time(:millisecond) - started_ms

              {:error, {:llm_call_failed, reason},
               %{
                 elapsed_ms: elapsed_ms,
                 total_elapsed_ms: elapsed_since_ms(total_started_ms),
                 source_context_elapsed_ms: source_context_elapsed_ms,
                 input_build_elapsed_ms: input_build_elapsed_ms,
                 max_tokens_used: effective_llm_max_tokens(state),
                 reasoning_effort_used: state.llm_reasoning_effort
               }}
          end

        {:error, reason} ->
          {:error, {:llm_params_failed, reason}, %{}}
      end
    end
  end

  defp smoke_test_user_id(agent) do
    agent_config = agent.config || %{}
    skill_config = get_in(agent_config, ["skill_configs", "morning_briefing"]) || %{}

    normalize_string(Map.get(skill_config, "user_id")) ||
      normalize_string(agent.user_id) ||
      normalize_string(Map.get(agent_config, "user_id"))
  end

  defp smoke_test_skill_config(agent, user_id) do
    agent_config = agent.config || %{}
    skill_config = get_in(agent_config, ["skill_configs", "morning_briefing"]) || %{}

    default_config()
    |> Map.merge(
      Map.take(agent_config, [
        "source_policy",
        "source_scope",
        "timezone_offset_hours",
        "morning_brief_hour_local",
        "morning_brief_minute_local",
        "email_scan_limit",
        "slack_channel_scan_limit",
        "slack_message_scan_limit",
        "news_enabled",
        "news_limit",
        "news_feeds",
        "lookback_hours",
        "timezone",
        "timezone_name",
        "llm_model",
        "llm_max_tokens",
        "llm_reasoning_effort",
        "slack_key_channels"
      ])
    )
    |> Map.merge(skill_config)
    |> Map.put("user_id", user_id)
  end

  defp smoke_test_context(agent, user_id, skill_config, now, opts) do
    context = %{
      agent_id: agent.id,
      user_id: user_id,
      timestamp: now,
      budget: %{},
      recent_events: [],
      trigger: %{type: :manual, source: "morning_briefing_smoke_test"},
      event: nil
    }

    case Keyword.get(opts, :source_bundle, :acquire) do
      %{} = source_bundle ->
        Map.put(context, :source_bundle, source_bundle)

      false ->
        context

      _ ->
        {source_bundle, telemetry} =
          Acquisition.build(
            user_id,
            [id()],
            %{id() => skill_config},
            context
          )

        context
        |> Map.put(:source_bundle, source_bundle)
        |> Map.put(:assistant_fetch_telemetry, telemetry)
    end
  end

  defp deliver_smoke_brief(user_id, brief, _diagnostics) do
    case ConnectedAccounts.telegram_destination(user_id) do
      nil ->
        {:error, :no_telegram_destination}

      destination ->
        chat_id =
          case destination do
            %{chat_id: id} -> id
            %{"chat_id" => id} -> id
            id when is_binary(id) -> id
            other -> to_string(other)
          end

        brief
        |> smoke_brief_telegram_chunks()
        |> send_telegram_html_chunks(chat_id)
    end
  end

  defp smoke_brief_telegram_chunks(brief) do
    title = read_string(brief, "title", "Morning briefing")
    summary = read_string(brief, "summary", "")
    body = read_string(brief, "body", "")

    [title, summary, body]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n\n")
    |> markdown_chunks(@telegram_chunk_limit)
    |> maybe_prefix_parts()
    |> Enum.map(&Maraithon.TelegramMarkdown.to_html/1)
  end

  defp send_telegram_html_chunks(chunks, chat_id) do
    chunks
    |> Enum.reduce_while({:ok, []}, fn chunk, {:ok, message_ids} ->
      case Maraithon.TelegramResponder.send(chat_id, chunk, parse_mode: "HTML") do
        {:ok, result} ->
          {:cont, {:ok, [read_message_id(result) | message_ids]}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, message_ids} ->
        {:ok, %{"message_ids" => Enum.reverse(message_ids), "chunks" => length(message_ids)}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp markdown_chunks(text, limit) when is_binary(text) do
    text
    |> markdown_chunk_units(limit)
    |> Enum.reduce([], fn unit, chunks ->
      append_markdown_chunk(chunks, unit, limit)
    end)
    |> Enum.reverse()
  end

  defp markdown_chunk_units(text, limit) do
    text
    |> String.split(~r/\n{2,}/, trim: true)
    |> Enum.flat_map(fn block ->
      cond do
        String.length(block) <= limit ->
          [block]

        String.contains?(block, "\n") ->
          block
          |> String.split("\n", trim: true)
          |> Enum.flat_map(&hard_split_markdown_unit(&1, limit))

        true ->
          hard_split_markdown_unit(block, limit)
      end
    end)
  end

  defp hard_split_markdown_unit(text, limit) do
    if String.length(text) <= limit do
      [text]
    else
      {chunk, rest} = String.split_at(text, limit)
      [chunk | hard_split_markdown_unit(rest, limit)]
    end
  end

  defp append_markdown_chunk([], unit, _limit), do: [unit]

  defp append_markdown_chunk([current | rest], unit, limit) do
    candidate = current <> "\n\n" <> unit

    if String.length(candidate) <= limit do
      [candidate | rest]
    else
      [unit, current | rest]
    end
  end

  defp maybe_prefix_parts([_single] = chunks), do: chunks

  defp maybe_prefix_parts(chunks) do
    total = length(chunks)

    chunks
    |> Enum.with_index(1)
    |> Enum.map(fn {chunk, index} -> "Part #{index}/#{total}\n\n#{chunk}" end)
  end

  defp read_message_id(%{"message_id" => message_id}), do: message_id
  defp read_message_id(%{message_id: message_id}), do: message_id
  defp read_message_id(_result), do: nil

  defp llm_params(brief_input, state) do
    with {:ok, prompt} <- morning_prompt(brief_input) do
      params =
        %{
          "messages" => [
            %{
              "role" => "user",
              "content" => prompt
            }
          ],
          "max_tokens" => effective_llm_max_tokens(state),
          "temperature" => 0.2,
          "reasoning_effort" => state.llm_reasoning_effort,
          "timeout_ms" => state.llm_timeout_ms
        }
        |> maybe_put("model", state.llm_model || Maraithon.LLM.model())

      {:ok, params}
    end
  end

  defp morning_prompt(brief_input) do
    with {:ok, skill} <- MarkdownSkill.load_file(@skill_path),
         {:ok, input_json} <- Jason.encode(compact_brief_input_for_prompt(brief_input)) do
      {:ok,
       """
       Execute the loaded Markdown skill against the supplied connector context.

       Skill: #{skill.name}
       Skill path: #{@skill_path}

       Skill instructions:
       #{skill.instructions}

       Email review rule:
       Every Gmail item includes body_available, body_status, and body. Use the full body for
       relevance and obligation judgments. Do not classify an email from sender, subject, or
       snippet alone. If body_available is false, treat that email as unreviewable source
       degradation and do not surface it as finance, school, marketing, urgent, or actionable
       unless another full-body source supports that conclusion.

       Local source rule:
       When the connector context includes iMessage chats, calendar events, reminders, notes, voice memos, files, or browser history, cite the most relevant items by short name. Prefer first-party local sources over scraped equivalents.

       Source completeness rule:
       The morning briefing payload is intentionally not pre-truncated for brevity. Review all
       included Gmail, Slack, calendar, CRM, todo, memory, and local-source rows before deciding
       what belongs in the executive brief. The output should be synthesized and judgmental,
       but the input scan should not stop after an arbitrary first page of items.

       Meeting enrichment rule:
       The brief input includes meeting_prep, which is prepared CRM-first. Use CRM context
       before public web context. Use web snippets only as fallback evidence for attendees
       or companies missing from CRM, and keep uncertainty visible when the evidence is thin.
       When meeting_prep.web_context includes page_contexts, treat those source pages as the
       meeting dossier. For each required external meeting, synthesize the executive read:
       who the person is, what the company or practice does, why the meeting likely matters
       to Runner or Agora, what fit or risk Kent should test, and the concrete pre/post-call
       next step. Do not collapse a source-backed external meeting into a generic "creative
       vendor" or "intro chat" label when the page context supports a richer prep note.
       When a source page gives concrete facts such as services, pricing, operating model,
       work history, background, customer profile, or partnership angle, include the most
       decision-useful specifics in the meeting note. If an internal teammate owns or hosts
       the meeting, state what Kent should ask that teammate before or after the call.
       A busy executive should be able to read the schedule item and know the dossier,
       fit hypothesis, and next move without asking for a second briefing.

       Commercial thread rule:
       Fresh external commercial threads from close teammates are not inbox noise. Use model
       judgment to scan gmail.commercial_threads, gmail.recent_inbox, commitments, todos, and
       CRM context for teammate-led customer, prospect, intro, plan, pricing, discount,
       availability, or launch-video threads.
       Treat gmail.commercial_threads as a coverage list: include every live non-duplicative
       external commercial thread from that list that a busy executive would want to know about,
       especially Charlie-led prospect/customer threads such as Enterprise/Team plan, discount,
       intro, or availability discussions. If Charlie or another close teammate has looped Kent
       into an external commercial thread, include a concise readiness note even when no immediate
       decision is forced. Say who or which organization is involved, the live ask, and what
       guidance Kent should have ready.

       Commercial coverage contract:
       commercial_coverage.required_threads is a hard coverage contract, not a ranking hint.
       If required_threads is non-empty, Decisions / Follow-ups or Today's Schedule must include
       every item in that list unless it is clearly duplicated by another named item. Use model
       judgment for the executive read, but do not drop a teammate-led customer, prospect, intro,
       Enterprise/Team plan, pricing, discount, or availability thread just because there are
       other risk items. Before returning JSON, verify that each required commercial thread appears
       by organization or counterparty name with the live ask and the guidance Kent should have ready.

       Schedule coverage contract:
       Required external meetings are a hard coverage contract, not a ranking hint. If
       schedule_coverage.required_meetings is non-empty, Today's Schedule must include
       every item in that list. Use model judgment for what the meeting means and how Kent
       should prepare; do not write a heuristic digest. Do not say the calendar is open
       when calendar.today_events or schedule_coverage.required_meetings is non-empty.
       Use display_start and display_end exactly when present for schedule times; do not
       recompute local clock times from UTC fields. If a display time is absent, cite UTC
       rather than guessing a local time.
       Before returning JSON, perform a final model review that the body includes every
       required external meeting with time, attendee or organization, why it matters, and
       the prep point, decision, or risk Kent should carry into it.
       Keep the JSON executive-grade and complete. Do not enforce an artificial short brief:
       if there are ten material items, include ten material items. Avoid filler and source
       inventory, but include every meeting, risk, decision, commercial thread, and follow-up
       a busy executive would want before starting the day. Todos may be longer than six
       when the source-backed action list is genuinely longer; keep each todo concise.

       Brief input JSON:
       #{input_json}
       """}
    end
  end

  defp parse_llm_brief(response) do
    error =
      case response do
        %{error: error} -> error
        %{"error" => error} -> error
        _ -> nil
      end

    content =
      case response do
        %{content: content} -> content
        %{"content" => content} -> content
        content when is_binary(content) -> content
        _ -> nil
      end

    if error do
      {:error, to_string(error)}
    else
      with content when is_binary(content) and content != "" <- content,
           {:ok, %{} = data} <- decode_json(content),
           title when is_binary(title) <- read_string(data, "title", nil),
           summary when is_binary(summary) <- read_string(data, "summary", nil),
           body when is_binary(body) <- read_string(data, "body", nil) do
        todos = read_list(data, "todos") |> Enum.filter(&is_map/1)

        {:ok, %{"title" => title, "summary" => summary, "body" => body, "todos" => todos}}
      else
        _ -> {:error, "model_response_invalid_or_missing_required_brief_json"}
      end
    end
  end

  defp brief_or_error_notice({:ok, brief}, _response), do: {brief, "llm", nil}

  defp brief_or_error_notice({:error, reason}, response) do
    error_message =
      [
        "Morning briefing model synthesis failed",
        reason,
        llm_finish_reason(response) && "finish_reason=#{llm_finish_reason(response)}"
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(": ")

    {%{
       "title" => "Morning briefing generation failed",
       "summary" =>
         "Maraithon could not generate the morning briefing with the configured model.",
       "body" =>
         "Morning briefing generation failed because the configured model did not return a valid synthesized brief. No heuristic or keyword-based fallback was used.\n\nError: #{error_message}"
     }, "error", error_message}
  end

  defp persist_model_todos(_user_id, %{"todos" => []}, _brief_input), do: {:ok, :no_todos}
  defp persist_model_todos(nil, _brief, _brief_input), do: {:ok, :no_todos}

  defp persist_model_todos(user_id, %{"todos" => todos}, brief_input)
       when is_binary(user_id) and is_list(todos) do
    candidates =
      todos
      |> Enum.filter(&is_map/1)
      |> Enum.map(&morning_todo_candidate(&1, brief_input))

    case candidates do
      [] ->
        {:ok, :no_todos}

      candidates ->
        OpenLoops.ingest_todos(user_id, candidates,
          source: "chief_of_staff_morning_briefing",
          max_tokens: 64_000,
          timeout_ms: 1_200_000,
          reasoning_effort: "xhigh"
        )
    end
  end

  defp persist_model_todos(_user_id, _brief, _brief_input), do: {:ok, :no_todos}

  defp morning_todo_candidate(todo, brief_input) when is_map(todo) do
    metadata =
      todo
      |> read_map("metadata")
      |> Map.merge(%{
        "origin_skill_id" => id(),
        "origin_cadence" => "morning",
        "brief_date" => read_string(brief_input, "date", nil),
        "brief_generated_at" => read_string(brief_input, "generated_at", nil)
      })
      |> compact_map()

    todo
    |> stringify_top_level_keys()
    |> Map.put("metadata", metadata)
    |> Map.put_new("source_occurred_at", read_string(brief_input, "generated_at", nil))
  end

  defp todo_event_payload({:ok, :no_todos}) do
    %{todo_count: 0, todo_skipped_count: 0}
  end

  defp todo_event_payload({:ok, result}) when is_map(result) do
    %{
      todo_count: length(result.todos),
      todo_skipped_count: result.skipped_count,
      todo_usage: Map.get(result, :usage, %{})
    }
  end

  defp todo_event_payload({:error, reason}) do
    %{
      todo_count: 0,
      todo_skipped_count: 0,
      todo_error: inspect(reason)
    }
  end

  defp delivery_event_payload({:ok, result}) when is_map(result) do
    %{
      status: "sent",
      chunks: Map.get(result, "chunks", 0),
      message_ids: Map.get(result, "message_ids", [])
    }
  end

  defp delivery_event_payload({:ok, :not_sent}), do: %{status: "not_sent"}

  defp delivery_event_payload({:error, reason}) do
    %{status: "error", error: inspect(reason)}
  end

  defp briefing_cost_summary(response, brief_input) do
    llm_usage = response_usage(response)
    web_searches = get_in(brief_input, ["meeting_prep", "counts", "web_searches"]) || 0
    web_search_cost = Spend.web_search_cost(web_searches)
    llm_cost = read_number(llm_usage, "total_cost", 0.0)
    total_cost = llm_cost + web_search_cost.total_cost

    %{
      pricing_source: "openai_api_pricing_2026_05_12",
      llm: llm_usage,
      web_search: web_search_cost,
      estimated_total_cost: Float.round(total_cost, 6)
    }
  end

  defp response_usage(response) do
    case read_map(response, "usage") do
      usage when map_size(usage) > 0 ->
        usage

      _empty ->
        model = read_string(response, "model", "unknown")
        tokens_in = read_integer(response, "tokens_in", 0)
        tokens_out = read_integer(response, "tokens_out", 0)
        Spend.calculate_cost(model, tokens_in, tokens_out)
    end
  end

  defp json_metadata(value), do: Maraithon.Normalization.normalize_json_value(value)

  defp timed(fun) when is_function(fun, 0) do
    started_ms = System.monotonic_time(:millisecond)
    {fun.(), elapsed_since_ms(started_ms)}
  end

  defp elapsed_since_ms(started_ms) do
    System.monotonic_time(:millisecond) - started_ms
  end

  defp calendar_event_for_prompt(nil, _state), do: nil

  defp calendar_event_for_prompt(event, state) when is_map(event) do
    start_value = read_any(event, "start")
    end_value = read_any(event, "end")

    %{
      "event_id" => read_string(event, "event_id", nil),
      "summary" => read_string(event, "summary", "Untitled event"),
      "start" => prompt_time(start_value),
      "end" => prompt_time(end_value),
      "display_start" => display_time(start_value, state),
      "display_end" => display_time(end_value, state),
      "display_date" => display_date(start_value, state),
      "display_timezone" => timezone_label(state, datetime_from_value(start_value)),
      "location" => read_string(event, "location", nil),
      "attendees" => read_list(event, "attendees"),
      "organizer" => read_string(event, "organizer", nil),
      "html_link" => read_string(event, "html_link", nil),
      "calendar_name" => read_string(event, "calendar_name", nil),
      "is_all_day" => read_any(event, "is_all_day"),
      "source" => read_string(event, "source", nil)
    }
  end

  defp gmail_message_for_prompt(message) when is_map(message) do
    body = gmail_body_for_prompt(message)
    body_available = body != ""

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
      "snippet" => read_string(message, "snippet", ""),
      "body_available" => body_available,
      "body_status" =>
        read_string(message, "body_status", if(body_available, do: "available", else: "missing")),
      "body" => body
    }
  end

  defp gmail_body_for_prompt(message) when is_map(message) do
    [
      read_string(message, "body_text", nil),
      read_string(message, "text_body", nil),
      read_string(message, "html_body", nil)
    ]
    |> Enum.find(fn value -> is_binary(value) and String.trim(value) != "" end)
    |> case do
      value when is_binary(value) -> String.trim(value)
      _ -> ""
    end
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
      "text" => read_string(message, "text", ""),
      "reply_count" => read_integer(message, "reply_count", 0)
    }
  end

  defp local_event_to_prompt(%Maraithon.LocalCalendar.LocalEvent{} = event) do
    %{
      "event_id" => event.guid,
      "summary" => event.title || "Untitled event",
      "start" => event.start_at,
      "end" => event.end_at,
      "location" => event.location,
      "attendees" => event.attendee_emails || [],
      "organizer" => event.organizer_email,
      "calendar_name" => event.calendar_name,
      "is_all_day" => event.is_all_day,
      "source" => "local_calendar"
    }
  end

  defp local_event_to_prompt(event) when is_map(event), do: event
  defp local_event_to_prompt(_), do: nil

  defp imessage_chat_for_prompt(%{chat_key: chat_key} = chat) do
    latest = Map.get(chat, :latest_message)

    %{
      "chat_key" => chat_key,
      "chat_display_name" => Map.get(chat, :chat_display_name),
      "message_count_last_7d" => Map.get(chat, :message_count_last_7d, 0),
      "latest_snippet" => latest && (latest.text || ""),
      "latest_sender" => latest && latest.sender_handle,
      "latest_is_from_me" => latest && latest.is_from_me,
      "latest_sent_at" => latest && prompt_time(latest.sent_at)
    }
  end

  defp imessage_chat_for_prompt(chat) when is_map(chat) do
    %{
      "chat_key" => Map.get(chat, "chat_key"),
      "chat_display_name" => Map.get(chat, "chat_display_name"),
      "message_count_last_7d" => Map.get(chat, "message_count_last_7d", 0),
      "latest_snippet" => Map.get(chat, "latest_snippet"),
      "latest_sender" => Map.get(chat, "latest_sender"),
      "latest_is_from_me" => Map.get(chat, "latest_is_from_me"),
      "latest_sent_at" => Map.get(chat, "latest_sent_at")
    }
  end

  defp note_for_prompt(%Maraithon.LocalNotes.LocalNote{} = note) do
    %{
      "note_id" => note.guid,
      "title" => note.title || "(untitled note)",
      "snippet" => note.snippet || "",
      "folder" => note.folder,
      "is_pinned" => note.is_pinned,
      "modified_at" => prompt_time(note.modified_at)
    }
  end

  defp note_for_prompt(note) when is_map(note), do: note

  defp voice_memo_for_prompt(%Maraithon.LocalVoiceMemos.LocalVoiceMemo{} = memo) do
    %{
      "memo_id" => memo.guid,
      "title" => memo.title || "(untitled memo)",
      "snippet" => memo.snippet || "",
      "duration_seconds" => memo.duration_seconds,
      "created_at" => prompt_time(memo.created_at),
      "has_transcript" => is_binary(memo.transcript) and memo.transcript != ""
    }
  end

  defp voice_memo_for_prompt(memo) when is_map(memo), do: memo

  defp reminder_for_prompt(%Maraithon.LocalReminders.LocalReminder{} = reminder) do
    %{
      "reminder_id" => reminder.guid,
      "title" => reminder.title || "(untitled reminder)",
      "list_name" => reminder.list_name,
      "due_at" => prompt_time(reminder.due_at),
      "priority" => reminder.priority,
      "is_completed" => reminder.is_completed,
      "has_alarm" => reminder.has_alarm,
      "url_attachment" => reminder.url_attachment
    }
  end

  defp reminder_for_prompt(reminder) when is_map(reminder), do: reminder

  defp file_for_prompt(%Maraithon.LocalFiles.LocalFile{} = file) do
    %{
      "file_id" => file.guid,
      "filename" => file.filename,
      "extension" => file.extension,
      "path" => file.path,
      "byte_size" => file.byte_size,
      "modified_at" => prompt_time(file.modified_at)
    }
  end

  defp file_for_prompt(file) when is_map(file), do: file

  defp allowed_file_extension?(%Maraithon.LocalFiles.LocalFile{extension: ext})
       when is_binary(ext) do
    String.downcase(ext) in @local_files_allowed_extensions
  end

  defp allowed_file_extension?(_file), do: false

  defp top_browser_hosts(visits, now, limit) do
    cutoff = DateTime.add(now, -24 * 3_600, :second)

    visits
    |> Enum.filter(fn visit ->
      host = visit_host(visit)
      last = visit_last_visited_at(visit)
      is_binary(host) and host != "" and (is_nil(last) or DateTime.compare(last, cutoff) != :lt)
    end)
    |> Enum.group_by(&visit_host/1)
    |> Enum.map(fn {host, host_visits} ->
      %{
        "host" => host,
        "visits" => length(host_visits),
        "last_visited_at" =>
          host_visits
          |> Enum.map(&visit_last_visited_at/1)
          |> Enum.filter(& &1)
          |> Enum.max(DateTime, fn -> nil end)
          |> prompt_time()
      }
    end)
    |> Enum.sort_by(& &1["visits"], :desc)
    |> Enum.take(limit)
  end

  defp visit_host(%Maraithon.LocalBrowserHistory.LocalVisit{host: host}), do: host
  defp visit_host(visit) when is_map(visit), do: Map.get(visit, "host") || Map.get(visit, :host)
  defp visit_host(_), do: nil

  defp visit_last_visited_at(%Maraithon.LocalBrowserHistory.LocalVisit{
         last_visited_at: last_visited_at
       }),
       do: last_visited_at

  defp visit_last_visited_at(%{last_visited_at: last_visited_at}), do: last_visited_at

  defp visit_last_visited_at(%{"last_visited_at" => last_visited_at})
       when is_binary(last_visited_at) do
    case DateTime.from_iso8601(last_visited_at) do
      {:ok, dt, _} -> dt
      _ -> nil
    end
  end

  defp visit_last_visited_at(%{"last_visited_at" => %DateTime{} = dt}), do: dt
  defp visit_last_visited_at(_visit), do: nil

  defp within_last_24h?(nil, _now), do: false

  defp within_last_24h?(%DateTime{} = dt, %DateTime{} = now) do
    DateTime.diff(now, dt, :second) <= 24 * 3_600
  end

  defp within_last_24h?(_dt, _now), do: false

  defp reminder_due_today?(
         %Maraithon.LocalReminders.LocalReminder{due_at: %DateTime{} = due},
         now
       ) do
    DateTime.compare(due, now) != :gt or
      DateTime.diff(due, now, :second) <= 24 * 3_600
  end

  defp reminder_due_today?(reminder, now) when is_map(reminder) do
    due = Map.get(reminder, "due_at") || Map.get(reminder, :due_at)

    case due do
      %DateTime{} = dt ->
        reminder_due_today?(%Maraithon.LocalReminders.LocalReminder{due_at: dt}, now)

      _ ->
        false
    end
  end

  defp reminder_due_today?(_reminder, _now), do: false

  defp fetch_local_source(user_id, source, bundle_items, fetch_fun)
       when is_binary(user_id) and is_list(bundle_items) and is_function(fetch_fun, 1) do
    try do
      items =
        case bundle_items do
          [] -> fetch_fun.(user_id)
          items -> items
        end

      {items, nil}
    rescue
      exception ->
        error = Exception.message(exception)

        Logger.warning("morning_briefing local source fetch failed",
          source: to_string(source),
          error: error,
          exception: inspect(exception.__struct__)
        )

        {[], error}
    catch
      kind, reason ->
        error = "#{kind}: #{inspect(reason)}"

        Logger.warning("morning_briefing local source fetch failed",
          source: to_string(source),
          error: error
        )

        {[], error}
    end
  end

  defp fetch_local_source(_user_id, _source, _bundle_items, _fetch_fun), do: {[], "invalid_user"}

  defp merge_local_source_health(freshness, user_id, now, sources, errors)
       when is_map(freshness) do
    devices_last_seen = latest_device_seen_at(user_id)

    Enum.reduce(sources, freshness, fn {source, items}, acc ->
      error = Map.get(errors, source)

      status =
        if is_nil(error), do: local_source_status(items, devices_last_seen, now), else: "error"

      health =
        Map.get(acc, to_string(source), %{})
        |> Map.merge(%{
          "source" => to_string(source),
          "status" => status,
          "device_last_seen_at" => prompt_time(devices_last_seen),
          "item_count" => length(items)
        })
        |> maybe_put("fetch_error", error)

      Map.put(acc, to_string(source), health)
    end)
  end

  defp merge_local_source_health(freshness, _user_id, _now, _sources, _errors), do: freshness

  defp local_source_status(items, %DateTime{} = devices_last_seen, %DateTime{} = now)
       when is_list(items) do
    cond do
      items != [] -> "connected"
      DateTime.diff(now, devices_last_seen, :second) > @device_stale_seconds -> "stale"
      true -> "connected"
    end
  end

  defp local_source_status([], nil, _now), do: "error"
  defp local_source_status([_ | _], nil, _now), do: "connected"
  defp local_source_status(_items, _last_seen, _now), do: "error"

  defp latest_device_seen_at(user_id) when is_binary(user_id) do
    try do
      user_id
      |> Companion.Devices.list_for_user()
      |> Enum.map(& &1.last_seen_at)
      |> Enum.filter(& &1)
      |> case do
        [] -> nil
        timestamps -> Enum.max(timestamps, DateTime)
      end
    rescue
      _ -> nil
    end
  end

  defp latest_device_seen_at(_user_id), do: nil

  defp news_item_for_prompt(item) when is_map(item) do
    %{
      "source" => read_string(item, "source", nil),
      "title" => read_string(item, "title", nil),
      "summary" => read_string(item, "summary", ""),
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
      "due_at" => prompt_time(todo.due_at),
      "notes" => todo.notes,
      "action_plan" => todo.action_plan,
      "owner_user_id" => todo.owner_user_id,
      "owner_label" => todo.owner_label,
      "priority" => todo.priority,
      "source_account_id" => todo.source_account_id,
      "source_account_label" => todo.source_account_label,
      "source_item_id" => todo.source_item_id,
      "source_occurred_at" => prompt_time(todo.source_occurred_at)
    }
  end

  defp recent_unread_message?(message, lookback_start) when is_map(message) do
    labels = read_list(message, "labels") |> Enum.map(&to_string/1)
    internal_date = read_datetime(message, "internal_date")

    "UNREAD" in labels and
      (is_nil(internal_date) or DateTime.compare(internal_date, lookback_start) != :lt)
  end

  defp recent_gmail_message?(message, lookback_start) when is_map(message) do
    case read_datetime(message, "internal_date") do
      nil -> true
      internal_date -> DateTime.compare(internal_date, lookback_start) != :lt
    end
  end

  defp recent_gmail_message?(_message, _lookback_start), do: false

  defp commercial_thread_candidate?(message) when is_map(message) do
    from = read_string(message, "from", "") |> String.downcase()
    recipients = commercial_thread_recipients(message)

    text =
      [
        from,
        recipients,
        read_string(message, "subject", ""),
        read_string(message, "snippet", ""),
        gmail_body_for_prompt(message)
      ]
      |> Enum.join("\n")
      |> String.downcase()

    commercial_thread_counterparty?(from, recipients) and
      Enum.any?(@commercial_thread_terms, &String.contains?(text, &1))
  end

  defp commercial_thread_candidate?(_message), do: false

  defp commercial_thread_counterparty?(from, recipients)
       when is_binary(from) and is_binary(recipients) do
    from_domains = email_domains(from)
    recipient_domains = email_domains(recipients)
    from_teammate? = Enum.any?(from_domains, &commercial_teammate_domain?/1)
    from_counterparty? = Enum.any?(from_domains, &commercial_counterparty_domain?/1)
    external_recipient? = Enum.any?(recipient_domains, &(not commercial_teammate_domain?(&1)))

    from_counterparty? or (from_teammate? and external_recipient?)
  end

  defp commercial_thread_counterparty?(_from, _recipients), do: false

  defp email_domains(text) when is_binary(text) do
    ~r/@([a-z0-9][a-z0-9.-]*\.[a-z]{2,})/i
    |> Regex.scan(text)
    |> Enum.map(fn [_match, domain] -> String.downcase(domain) end)
    |> Enum.uniq()
  end

  defp email_domains(_text), do: []

  defp commercial_teammate_domain?(domain) when is_binary(domain) do
    Enum.any?(@commercial_teammate_domains, fn teammate_domain ->
      domain == teammate_domain or String.ends_with?(domain, "." <> teammate_domain)
    end)
  end

  defp commercial_teammate_domain?(_domain), do: false

  defp commercial_counterparty_domain?(domain) when is_binary(domain) do
    Enum.any?(@commercial_counterparty_domain_markers, &String.contains?(domain, &1))
  end

  defp commercial_counterparty_domain?(_domain), do: false

  defp commercial_thread_recipients(message) when is_map(message) do
    [
      read_string(message, "to", ""),
      read_string(message, "cc", ""),
      read_string(message, "bcc", "")
    ]
    |> Enum.join("\n")
    |> String.downcase()
  end

  defp commercial_thread_recipients(_message), do: ""

  defp commercial_thread_key(message) when is_map(message) do
    subject_key =
      [
        normalize_commercial_text(read_string(message, "subject", "")),
        normalize_commercial_text(read_string(message, "from", "")),
        normalize_commercial_text(read_string(message, "snippet", ""))
      ]
      |> Enum.reject(&blank?/1)
      |> Enum.join("|")

    if subject_key == "" do
      read_string(message, "thread_id", nil) || inspect(message)
    else
      subject_key
    end
  end

  defp commercial_thread_key(message), do: inspect(message)

  defp commercial_thread_sort_key(message) when is_map(message) do
    case read_datetime(message, "internal_date") do
      nil -> 0
      datetime -> DateTime.to_unix(datetime, :second)
    end
  end

  defp commercial_thread_sort_key(_message), do: 0

  defp normalize_commercial_text(value) when is_binary(value) do
    value
    |> String.downcase()
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  defp normalize_commercial_text(_value), do: ""

  defp recent_slack_message?(message, lookback_start) when is_map(message) do
    case read_slack_datetime(message, "ts") do
      nil -> true
      timestamp -> DateTime.compare(timestamp, lookback_start) != :lt
    end
  end

  defp recent_slack_message?(_message, _lookback_start), do: false

  defp event_on_date?(event, date, state) when is_map(event) do
    event
    |> read_any("start")
    |> local_date_from_value(state)
    |> case do
      ^date -> true
      _ -> false
    end
  end

  defp event_on_date?(_event, _date, _state), do: false

  defp schedule_coverage_contract(meeting_prep) when is_map(meeting_prep) do
    required_meetings =
      meeting_prep
      |> read_list("meetings")
      |> Enum.filter(&truthy?(read_any(&1, "schedule_required")))
      |> Enum.map(&required_schedule_meeting_for_prompt/1)

    %{
      "policy" =>
        "Every required_meetings item must appear in Today's Schedule. The model still decides the executive read, prep, risk, and wording.",
      "required_meetings" => required_meetings,
      "counts" => %{"required_meetings" => length(required_meetings)}
    }
  end

  defp schedule_coverage_contract(_meeting_prep) do
    %{
      "policy" =>
        "Every required_meetings item must appear in Today's Schedule. The model still decides the executive read, prep, risk, and wording.",
      "required_meetings" => [],
      "counts" => %{"required_meetings" => 0}
    }
  end

  defp commercial_coverage_contract(threads) when is_list(threads) do
    required_threads =
      threads
      |> Enum.map(&required_commercial_thread_for_prompt/1)
      |> Enum.reject(&(&1 == %{}))

    %{
      "policy" =>
        "Every required_threads item must appear in Decisions / Follow-ups or Today's Schedule unless it is clearly duplicated by another named item. The model still decides the executive read, prep, risk, and wording.",
      "required_threads" => required_threads,
      "counts" => %{"required_threads" => length(required_threads)}
    }
  end

  defp commercial_coverage_contract(_threads) do
    %{
      "policy" =>
        "Every required_threads item must appear in Decisions / Follow-ups or Today's Schedule unless it is clearly duplicated by another named item. The model still decides the executive read, prep, risk, and wording.",
      "required_threads" => [],
      "counts" => %{"required_threads" => 0}
    }
  end

  defp required_commercial_thread_for_prompt(thread) when is_map(thread) do
    %{
      "commercial_required" => true,
      "message_id" => read_string(thread, "message_id", nil),
      "thread_id" => read_string(thread, "thread_id", nil),
      "from" => read_string(thread, "from", nil),
      "to" => read_string(thread, "to", nil),
      "subject" => read_string(thread, "subject", nil),
      "date" => read_string(thread, "date", nil),
      "snippet" => read_string(thread, "snippet", nil),
      "body" => read_string(thread, "body", nil),
      "coverage_reason" =>
        "Teammate-led or known-counterparty commercial thread that needs executive readiness."
    }
    |> compact_map()
  end

  defp required_commercial_thread_for_prompt(_thread), do: %{}

  defp required_schedule_meeting_for_prompt(meeting) when is_map(meeting) do
    %{
      "event_id" => read_string(meeting, "event_id", nil),
      "summary" => read_string(meeting, "summary", nil),
      "start" => read_any(meeting, "start"),
      "end" => read_any(meeting, "end"),
      "display_start" => read_string(meeting, "display_start", nil),
      "display_end" => read_string(meeting, "display_end", nil),
      "display_date" => read_string(meeting, "display_date", nil),
      "display_timezone" => read_string(meeting, "display_timezone", nil),
      "external_attendees" => read_list(meeting, "external_attendees"),
      "candidate_people_and_orgs" => read_list(meeting, "candidate_people_and_orgs"),
      "crm_context" => read_list(meeting, "crm_context"),
      "web_context" => read_list(meeting, "web_context"),
      "data_gaps" => read_list(meeting, "data_gaps"),
      "briefing_reason" => read_string(meeting, "briefing_reason", nil)
    }
    |> compact_map()
  end

  defp dedupe_calendar_events(events) when is_list(events) do
    events
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq_by(&calendar_event_dedupe_key/1)
  end

  defp calendar_event_dedupe_key(event) when is_map(event) do
    summary = normalize_calendar_dedupe_text(read_string(event, "summary", ""))
    start = prompt_time(read_any(event, "start"))
    end_time = prompt_time(read_any(event, "end"))
    organizer = normalize_calendar_dedupe_text(read_string(event, "organizer", ""))

    cond do
      summary != "" and is_binary(start) ->
        {:time, summary, start, end_time, organizer}

      event_id = read_string(event, "event_id", nil) ->
        {:id, event_id}

      true ->
        {:raw, inspect(event)}
    end
  end

  defp calendar_event_dedupe_key(event), do: {:raw, inspect(event)}

  defp normalize_calendar_dedupe_text(value) when is_binary(value) do
    value
    |> String.downcase()
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  defp normalize_calendar_dedupe_text(_value), do: ""

  defp event_sort_key(event) when is_map(event) do
    case read_any(event, "start") do
      %DateTime{} = value -> DateTime.to_unix(value, :microsecond)
      %{"date" => value} when is_binary(value) -> value
      value when is_binary(value) -> value
      _ -> 0
    end
  end

  defp compact_brief_input_for_prompt(input) when is_map(input) do
    input
    |> Map.update("calendar", %{}, &compact_calendar_for_prompt/1)
    |> Map.update("meeting_prep", %{}, &compact_meeting_prep_for_prompt/1)
    |> Map.update("schedule_coverage", %{}, &compact_schedule_coverage_for_prompt/1)
    |> Map.update("commercial_coverage", %{}, &compact_commercial_coverage_for_prompt/1)
    |> Map.update("gmail", %{}, &compact_gmail_for_prompt/1)
    |> Map.update("slack", %{}, &compact_slack_for_prompt/1)
    |> Map.update("news", %{}, &compact_news_for_prompt/1)
    |> Map.update("commitments", %{}, &compact_prompt_value/1)
    |> Map.update("open_work", %{}, &compact_prompt_value/1)
    |> Map.update("relationships", [], &compact_relationships_for_prompt/1)
    |> Map.update("deep_memory", %{}, &compact_prompt_value/1)
    |> Map.update("imessage", %{}, &compact_prompt_value/1)
    |> Map.update("notes", %{}, &compact_prompt_value/1)
    |> Map.update("voice_memos", %{}, &compact_prompt_value/1)
    |> Map.update("reminders", %{}, &compact_prompt_value/1)
    |> Map.update("files", %{}, &compact_prompt_value/1)
    |> Map.update("browser_history", %{}, &compact_prompt_value/1)
    |> Map.update("source_health", %{}, &compact_prompt_value/1)
    |> compact_prompt_value()
  end

  defp compact_brief_input_for_prompt(input), do: input

  defp compact_calendar_for_prompt(calendar) when is_map(calendar) do
    calendar
    |> Map.update("today_events", [], fn events ->
      events
      |> read_list()
      |> Enum.map(&compact_calendar_event_for_prompt/1)
    end)
    |> Map.update("upcoming_local", [], fn events ->
      events
      |> read_list()
      |> Enum.map(&compact_calendar_event_for_prompt/1)
    end)
    |> Map.update("tomorrow_first_event", nil, &compact_calendar_event_for_prompt/1)
    |> compact_prompt_value()
  end

  defp compact_calendar_for_prompt(calendar), do: compact_prompt_value(calendar)

  defp compact_calendar_event_for_prompt(event) when is_map(event) do
    event
    |> Map.update("attendees", [], &read_list/1)
    |> compact_prompt_value()
  end

  defp compact_calendar_event_for_prompt(event), do: compact_prompt_value(event)

  defp compact_meeting_prep_for_prompt(meeting_prep) when is_map(meeting_prep) do
    meeting_prep
    |> Map.update("meetings", [], fn meetings ->
      meetings
      |> read_list()
      |> prioritize_required_prompt_items()
      |> Enum.map(&compact_meeting_for_prompt/1)
    end)
    |> compact_prompt_value()
  end

  defp compact_meeting_prep_for_prompt(meeting_prep), do: compact_prompt_value(meeting_prep)

  defp compact_schedule_coverage_for_prompt(schedule_coverage) when is_map(schedule_coverage) do
    schedule_coverage
    |> Map.update("required_meetings", [], fn meetings ->
      meetings
      |> read_list()
      |> Enum.map(&compact_meeting_for_prompt/1)
    end)
    |> compact_prompt_value()
  end

  defp compact_schedule_coverage_for_prompt(schedule_coverage),
    do: compact_prompt_value(schedule_coverage)

  defp compact_commercial_coverage_for_prompt(commercial_coverage)
       when is_map(commercial_coverage) do
    commercial_coverage
    |> Map.update("required_threads", [], fn threads ->
      threads
      |> read_list()
      |> Enum.map(&compact_gmail_message_for_prompt/1)
    end)
    |> compact_prompt_value()
  end

  defp compact_commercial_coverage_for_prompt(commercial_coverage),
    do: compact_prompt_value(commercial_coverage)

  defp compact_meeting_for_prompt(meeting) when is_map(meeting) do
    meeting
    |> Map.update("attendees", [], &read_list/1)
    |> Map.update("external_attendees", [], &read_list/1)
    |> Map.update("candidate_people_and_orgs", [], &read_list/1)
    |> Map.update("crm_context", [], &(read_list(&1) |> compact_prompt_value()))
    |> Map.update("web_context", [], &(read_list(&1) |> compact_prompt_value()))
    |> Map.update("data_gaps", [], &read_list/1)
    |> compact_prompt_value()
  end

  defp compact_meeting_for_prompt(meeting), do: compact_prompt_value(meeting)

  defp compact_gmail_for_prompt(gmail) when is_map(gmail) do
    gmail
    |> Map.update("commercial_threads", [], fn messages ->
      messages
      |> read_list()
      |> Enum.map(&compact_gmail_message_for_prompt/1)
    end)
    |> Map.update("recent_inbox", [], fn messages ->
      messages
      |> read_list()
      |> Enum.map(&compact_gmail_message_for_prompt/1)
    end)
    |> Map.update("recent_unread", [], fn messages ->
      messages
      |> read_list()
      |> Enum.map(&compact_gmail_message_for_prompt/1)
    end)
    |> compact_prompt_value()
  end

  defp compact_gmail_for_prompt(gmail), do: compact_prompt_value(gmail)

  defp compact_gmail_message_for_prompt(message) when is_map(message) do
    message
    |> Map.update("body", "", &to_string/1)
    |> Map.update("snippet", "", &to_string/1)
    |> compact_prompt_value()
  end

  defp compact_gmail_message_for_prompt(message), do: compact_prompt_value(message)

  defp compact_slack_for_prompt(slack) when is_map(slack) do
    slack
    |> Map.update("key_threads", [], fn messages ->
      messages
      |> read_list()
      |> Enum.map(&compact_prompt_value/1)
    end)
    |> Map.update("mentions", [], &read_list/1)
    |> compact_prompt_value()
  end

  defp compact_slack_for_prompt(slack), do: compact_prompt_value(slack)

  defp compact_news_for_prompt(news) when is_map(news) do
    news
    |> Map.update("items", [], &read_list/1)
    |> compact_prompt_value()
  end

  defp compact_news_for_prompt(news), do: compact_prompt_value(news)

  defp compact_relationships_for_prompt(relationships) do
    relationships
    |> read_list()
    |> compact_prompt_value()
  end

  defp compact_prompt_value(value) do
    compact_prompt_value(value, @prompt_default_list_limit, @prompt_string_limit)
  end

  defp compact_prompt_value(%DateTime{} = value, _list_limit, _string_limit),
    do: DateTime.to_iso8601(value)

  defp compact_prompt_value(%NaiveDateTime{} = value, _list_limit, _string_limit),
    do: NaiveDateTime.to_iso8601(value)

  defp compact_prompt_value(%Date{} = value, _list_limit, _string_limit),
    do: Date.to_iso8601(value)

  defp compact_prompt_value(%Time{} = value, _list_limit, _string_limit),
    do: Time.to_iso8601(value)

  defp compact_prompt_value(%{__struct__: _struct} = value, _list_limit, _string_limit),
    do: inspect(value)

  defp compact_prompt_value(value, list_limit, string_limit) when is_map(value) do
    Map.new(value, fn {key, item} ->
      {key, compact_prompt_value(item, list_limit, string_limit)}
    end)
  end

  defp compact_prompt_value(value, list_limit, string_limit) when is_list(value) do
    value
    |> Enum.map(&compact_prompt_value(&1, list_limit, string_limit))
  end

  defp compact_prompt_value(value, _list_limit, _string_limit) when is_binary(value),
    do: value

  defp compact_prompt_value(value, _list_limit, _string_limit), do: value

  defp prioritize_required_prompt_items(items) do
    {required, rest} =
      Enum.split_with(items, fn
        %{"schedule_required" => true} -> true
        %{schedule_required: true} -> true
        _item -> false
      end)

    required ++ rest
  end

  defp compact_brief_input_for_metadata(input) do
    %{
      "date" => read_string(input, "date", nil),
      "generated_at" => read_string(input, "generated_at", nil),
      "counts" => %{
        "gmail_commercial_threads" =>
          length(get_in(input, ["gmail", "commercial_threads"]) || []),
        "gmail_recent_inbox" => length(get_in(input, ["gmail", "recent_inbox"]) || []),
        "gmail_recent_unread" => length(get_in(input, ["gmail", "recent_unread"]) || []),
        "slack_key_threads" => length(get_in(input, ["slack", "key_threads"]) || []),
        "news_items" => length(get_in(input, ["news", "items"]) || []),
        "commitments_active" => get_in(input, ["commitments", "active_count"]) || 0,
        "insights" => length(get_in(input, ["open_work", "insights"]) || []),
        "todos" => length(get_in(input, ["open_work", "todos"]) || []),
        "relationships" => length(get_in(input, ["relationships"]) || []),
        "deep_memory" => deep_memory_count(input),
        "imessage_chats" => length(get_in(input, ["imessage", "chats"]) || []),
        "notes" => length(get_in(input, ["notes", "items"]) || []),
        "voice_memos" => length(get_in(input, ["voice_memos", "items"]) || []),
        "reminders_due_soon" => length(get_in(input, ["reminders", "due_soon"]) || []),
        "files_recent" => length(get_in(input, ["files", "items"]) || []),
        "browser_top_hosts" => length(get_in(input, ["browser_history", "top_hosts"]) || []),
        "calendar_local_upcoming" => length(get_in(input, ["calendar", "upcoming_local"]) || []),
        "meeting_prep_meetings" => get_in(input, ["meeting_prep", "counts", "meetings"]) || 0,
        "meeting_prep_required_schedule_meetings" =>
          get_in(input, ["meeting_prep", "counts", "required_schedule_meetings"]) || 0,
        "schedule_coverage_required_meetings" =>
          get_in(input, ["schedule_coverage", "counts", "required_meetings"]) || 0,
        "commercial_coverage_required_threads" =>
          get_in(input, ["commercial_coverage", "counts", "required_threads"]) || 0,
        "meeting_prep_crm_contexts" =>
          get_in(input, ["meeting_prep", "counts", "crm_contexts"]) || 0,
        "meeting_prep_web_searches" =>
          get_in(input, ["meeting_prep", "counts", "web_searches"]) || 0
      },
      "calendar_preferred_source" => get_in(input, ["calendar", "preferred_source"])
    }
  end

  defp deep_memory_count(input) do
    case Map.get(input, "deep_memory") || Map.get(input, :deep_memory) do
      %{count: count} when is_integer(count) -> count
      %{"count" => count} when is_integer(count) -> count
      _other -> 0
    end
  end

  defp llm_finish_reason(%{finish_reason: reason}) when is_binary(reason), do: reason
  defp llm_finish_reason(%{"finish_reason" => reason}) when is_binary(reason), do: reason
  defp llm_finish_reason(_response), do: nil

  defp due_now?(now, state) do
    local_now = local_datetime(now, state)

    local_now.hour > state.morning_hour or
      (local_now.hour == state.morning_hour and local_now.minute >= state.morning_minute)
  end

  defp next_morning_occurrence(now, state) do
    local_now = local_datetime(now, state)
    local_date = DateTime.to_date(local_now)

    scheduled_today =
      local_date
      |> DateTime.new!(Time.new!(state.morning_hour, state.morning_minute, 0), "Etc/UTC")

    target_local =
      if DateTime.compare(local_now, scheduled_today) == :lt do
        scheduled_today
      else
        Date.add(local_date, 1)
        |> DateTime.new!(Time.new!(state.morning_hour, state.morning_minute, 0), "Etc/UTC")
      end

    DateTime.add(target_local, -local_timezone_offset_hours(target_local, state), :hour)
  end

  defp local_period_key(now, state) do
    now
    |> local_date(state)
    |> Date.to_iso8601()
  end

  defp local_date(%DateTime{} = now, state) do
    now
    |> local_datetime(state)
    |> DateTime.to_date()
  end

  defp local_day_start_utc(%Date{} = date, state) do
    local_midnight = DateTime.new!(date, ~T[00:00:00], "Etc/UTC")
    DateTime.add(local_midnight, -local_timezone_offset_hours(local_midnight, state), :hour)
  end

  defp local_date_from_value(%DateTime{} = value, state),
    do: local_date(value, state)

  defp local_date_from_value(%{"date" => date}, _state) when is_binary(date) do
    case Date.from_iso8601(date) do
      {:ok, parsed} -> parsed
      _ -> nil
    end
  end

  defp local_date_from_value(value, state) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> local_date(datetime, state)
      _ -> nil
    end
  end

  defp local_date_from_value(_value, _state), do: nil

  defp decode_json(content) when is_binary(content) do
    content
    |> String.trim()
    |> String.trim_leading("```json")
    |> String.trim_leading("```")
    |> String.trim_trailing("```")
    |> String.trim()
    |> Jason.decode()
  end

  defp prompt_time(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp prompt_time(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  defp prompt_time(%{"date" => date}) when is_binary(date), do: date
  defp prompt_time(value) when is_binary(value), do: value
  defp prompt_time(_value), do: nil

  defp display_date(value, state) do
    case local_date_from_value(value, state) do
      %Date{} = date -> Date.to_iso8601(date)
      _ -> nil
    end
  end

  defp display_time(%{"date" => date}, _state) when is_binary(date), do: date

  defp display_time(%DateTime{} = value, state) do
    local = local_datetime(value, state)
    "#{format_clock(local)} #{timezone_label(state, value)}"
  end

  defp display_time(value, state) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> display_time(datetime, state)
      _ -> value
    end
  end

  defp display_time(_value, _state), do: nil

  defp datetime_from_value(%DateTime{} = value), do: value

  defp datetime_from_value(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      _ -> nil
    end
  end

  defp datetime_from_value(_value), do: nil

  defp local_datetime(%DateTime{} = datetime, state) do
    DateTime.add(datetime, timezone_offset_hours_at(datetime, state), :hour)
  end

  defp timezone_offset_hours_at(%DateTime{} = datetime, state) do
    case timezone_config(state) do
      {:us, standard, daylight, _label} ->
        if us_dst_active_utc?(datetime, standard, daylight), do: daylight, else: standard

      {:fixed, offset, _label} ->
        offset

      :unknown ->
        state.timezone_offset_hours
    end
  end

  defp local_timezone_offset_hours(%DateTime{} = local_datetime, state) do
    case timezone_config(state) do
      {:us, standard, daylight, _label} ->
        if us_dst_active_local?(local_datetime), do: daylight, else: standard

      {:fixed, offset, _label} ->
        offset

      :unknown ->
        state.timezone_offset_hours
    end
  end

  defp timezone_label(state, nil), do: timezone_label(state, DateTime.utc_now())

  defp timezone_label(state, %DateTime{} = _datetime) do
    case timezone_config(state) do
      {:us, _standard, _daylight, label} -> label
      {:fixed, _offset, label} -> label
      :unknown -> timezone_offset_label(state.timezone_offset_hours)
    end
  end

  defp timezone_config(%{timezone: timezone}) when is_binary(timezone) do
    case String.downcase(String.trim(timezone)) do
      value
      when value in ["america/los_angeles", "us/pacific", "pacific", "pacific time", "pt"] ->
        {:us, -8, -7, "PT"}

      value when value in ["america/denver", "us/mountain", "mountain", "mountain time", "mt"] ->
        {:us, -7, -6, "MT"}

      value when value in ["america/chicago", "us/central", "central", "central time", "ct"] ->
        {:us, -6, -5, "CT"}

      value
      when value in [
             "america/new_york",
             "america/toronto",
             "us/eastern",
             "eastern",
             "eastern time",
             "et"
           ] ->
        {:us, -5, -4, "ET"}

      value when value in ["utc", "etc/utc", "z"] ->
        {:fixed, 0, "UTC"}

      _ ->
        :unknown
    end
  end

  defp timezone_config(_state), do: :unknown

  defp normalize_timezone(value) when is_binary(value) do
    value
    |> String.trim()
    |> case do
      "" -> nil
      timezone -> timezone
    end
  end

  defp normalize_timezone(_value), do: nil

  defp us_dst_active_utc?(%DateTime{} = utc_datetime, standard_offset, daylight_offset) do
    year = utc_datetime.year
    starts_at = us_dst_boundary_utc(year, 3, :second, standard_offset)
    ends_at = us_dst_boundary_utc(year, 11, :first, daylight_offset)

    DateTime.compare(utc_datetime, starts_at) != :lt and
      DateTime.compare(utc_datetime, ends_at) == :lt
  end

  defp us_dst_active_local?(%DateTime{} = local_datetime) do
    year = local_datetime.year
    starts_at = us_dst_boundary_local(year, 3, :second)
    ends_at = us_dst_boundary_local(year, 11, :first)

    DateTime.compare(local_datetime, starts_at) != :lt and
      DateTime.compare(local_datetime, ends_at) == :lt
  end

  defp us_dst_boundary_utc(year, month, ordinal, offset_hours) do
    year
    |> us_dst_boundary_local(month, ordinal)
    |> DateTime.add(-offset_hours, :hour)
  end

  defp us_dst_boundary_local(year, month, ordinal) do
    year
    |> nth_sunday(month, ordinal)
    |> DateTime.new!(~T[02:00:00], "Etc/UTC")
  end

  defp nth_sunday(year, month, ordinal) do
    first = Date.new!(year, month, 1)
    days_until_sunday = rem(7 - Date.day_of_week(first), 7)
    first_sunday = Date.add(first, days_until_sunday)

    case ordinal do
      :first -> first_sunday
      :second -> Date.add(first_sunday, 7)
    end
  end

  defp format_clock(%DateTime{} = datetime) do
    hour =
      case rem(datetime.hour, 12) do
        0 -> 12
        value -> value
      end

    minute = datetime.minute |> Integer.to_string() |> String.pad_leading(2, "0")
    meridiem = if datetime.hour < 12, do: "AM", else: "PM"

    "#{hour}:#{minute} #{meridiem}"
  end

  defp timezone_offset_label(offset) when is_integer(offset) do
    sign = if offset < 0, do: "-", else: "+"
    hours = offset |> abs() |> Integer.to_string() |> String.pad_leading(2, "0")
    "UTC#{sign}#{hours}:00"
  end

  defp timezone_offset_label(_offset), do: "UTC"

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
  defp read_list(list) when is_list(list), do: list
  defp read_list(_value), do: []

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

  defp read_number(map, key, default) when is_map(map) do
    case read_any(map, key) do
      value when is_number(value) -> value
      value when is_binary(value) -> parse_float(value, default)
      _ -> default
    end
  end

  defp read_number(_map, _key, default), do: default

  defp parse_float(value, default) when is_binary(value) do
    case Float.parse(String.trim(value)) do
      {number, _rest} -> number
      :error -> default
    end
  end

  defp truthy?(true), do: true
  defp truthy?("true"), do: true
  defp truthy?(1), do: true
  defp truthy?(_value), do: false

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

  defp normalize_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      normalized -> normalized
    end
  end

  defp normalize_string(_value), do: nil

  defp normalize_reasoning_effort(value, default) do
    case normalize_string(value) do
      effort when is_binary(effort) ->
        normalized = String.downcase(effort)

        case normalized do
          effort when effort in ["high", "xhigh"] -> effort
          effort when effort in ["low", "medium"] -> default
          _other -> default
        end

      _ ->
        default
    end
  end

  defp effective_llm_max_tokens(state) do
    state
    |> Map.get(:llm_max_tokens)
    |> integer_in_range(@default_llm_max_tokens, 256, @default_llm_max_tokens)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, ""), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp compact_map(map) when is_map(map) do
    Enum.reduce(map, %{}, fn
      {_key, nil}, acc -> acc
      {_key, ""}, acc -> acc
      {key, value}, acc -> Map.put(acc, key, value)
    end)
  end

  defp stringify_top_level_keys(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), value} end)
  end

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
