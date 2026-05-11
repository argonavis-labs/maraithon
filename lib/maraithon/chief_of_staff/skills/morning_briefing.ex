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
  alias Maraithon.OpenLoops
  alias Maraithon.Todos

  @default_timezone_offset_hours -5
  @default_morning_hour 8
  @default_email_scan_limit 30
  @default_slack_channel_scan_limit 16
  @default_slack_message_scan_limit 8
  @default_news_limit 6
  @default_lookback_hours 18
  @default_llm_max_tokens 8_000
  @default_llm_reasoning_effort "high"
  @skill_path "priv/agents/skills/chief_of_staff/morning_briefing.md"
  @local_imessage_chat_limit 8
  @local_notes_limit 10
  @local_voice_memo_limit 5
  @local_calendar_limit 12
  @today_calendar_limit 32
  @local_reminders_days_ahead 7
  @local_reminders_limit 25
  @local_files_limit 6
  @local_browser_visits_limit 60
  @local_browser_top_hosts 6
  @local_files_allowed_extensions ~w(pdf md txt rtf rtfd docx pages key keynote ppt pptx xls xlsx csv numbers doc)
  @device_stale_seconds 2 * 60 * 60

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
        "origin_skill_id" => id(),
        "source_backed" => true,
        "brief_input" => compact_brief_input_for_metadata(brief_input),
        "source_health" => read_map(brief_input, "source_health")
      }
    }

    case Briefs.record(context[:user_id] || state.user_id, context[:agent_id], attrs) do
      {:ok, brief_record} ->
        period_key = read_string(brief_input, "date", nil)
        todo_result = persist_model_todos(context[:user_id] || state.user_id, brief, brief_input)

        event_type =
          if generation_mode == "llm", do: :briefs_recorded, else: :brief_generation_failed

        todo_payload = todo_event_payload(todo_result)

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
    local_date = local_date(now, offset_hours)
    tomorrow = Date.add(local_date, 1)
    lookback_start = DateTime.add(now, -state.lookback_hours, :hour)
    email_prompt_limit = min(state.email_scan_limit, 30)
    slack_prompt_limit = min(max(state.slack_message_scan_limit, 20), 60)

    # Prefer local-first calendar (macOS Calendar.app aggregates iCloud /
    # Exchange / Google / CalDAV in one place). Fall back to the Google
    # source bundle when no local events are present for this user. The
    # local snapshot can come from the source bundle (`put_calendar_local`)
    # or be queried live from `LocalCalendar` here.
    google_calendar_events = SourceBundle.calendar_events(source_bundle)
    bundle_local_calendar = SourceBundle.calendar_local_events(source_bundle)

    local_calendar_events =
      maybe_fetch_local(user_id, bundle_local_calendar, fn id ->
        LocalCalendar.events_around(id,
          since: now,
          until: DateTime.add(now, 48 * 3_600, :second),
          limit: @local_calendar_limit
        )
      end)
      |> Enum.map(&local_event_to_prompt/1)

    calendar_events =
      cond do
        local_calendar_events != [] -> local_calendar_events
        true -> google_calendar_events
      end

    calendar_source =
      cond do
        local_calendar_events != [] -> "local"
        google_calendar_events != [] -> "google"
        true -> "none"
      end

    gmail_messages = SourceBundle.gmail_inbox_messages(source_bundle)
    slack_messages = SourceBundle.slack_messages(source_bundle)
    news_items = SourceBundle.news_items(source_bundle)

    recent_slack_messages =
      Enum.filter(slack_messages, &recent_slack_message?(&1, lookback_start))

    bundle_imessage_chats = SourceBundle.imessage_chats(source_bundle)

    imessage_chats =
      maybe_fetch_local(user_id, bundle_imessage_chats, fn id ->
        LocalMessages.chats_recent(id, limit: @local_imessage_chat_limit, now: now)
      end)

    bundle_notes = SourceBundle.notes(source_bundle)

    notes =
      maybe_fetch_local(user_id, bundle_notes, fn id ->
        LocalNotes.recent_for_user(id, limit: @local_notes_limit)
      end)

    bundle_memos = SourceBundle.voice_memos(source_bundle)

    voice_memos =
      maybe_fetch_local(user_id, bundle_memos, fn id ->
        LocalVoiceMemos.recent_for_user(id, limit: @local_voice_memo_limit)
      end)

    bundle_reminders = SourceBundle.reminders(source_bundle)

    reminders =
      maybe_fetch_local(user_id, bundle_reminders, fn id ->
        LocalReminders.due_soon(id,
          days_ahead: @local_reminders_days_ahead,
          limit: @local_reminders_limit
        )
      end)

    bundle_files = SourceBundle.files(source_bundle)

    files =
      maybe_fetch_local(user_id, bundle_files, fn id ->
        id
        |> LocalFiles.recent_for_user(limit: @local_files_limit * 6)
        |> Enum.filter(&allowed_file_extension?/1)
        |> Enum.take(@local_files_limit)
      end)

    bundle_visits = SourceBundle.browser_visits(source_bundle)

    visits =
      maybe_fetch_local(user_id, bundle_visits, fn id ->
        LocalBrowserHistory.recent_visits(id, limit: @local_browser_visits_limit)
      end)

    top_hosts = top_browser_hosts(visits, now, @local_browser_top_hosts)

    today_events =
      calendar_events
      |> Enum.filter(&event_on_date?(&1, local_date, offset_hours))
      |> Enum.map(&calendar_event_for_prompt/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.take(@today_calendar_limit)

    tomorrow_first_event =
      calendar_events
      |> Enum.filter(&event_on_date?(&1, tomorrow, offset_hours))
      |> Enum.sort_by(&event_sort_key/1)
      |> List.first()
      |> calendar_event_for_prompt()

    meeting_prep =
      MeetingEnrichment.enrich(user_id, today_events,
        now: now,
        max_web_queries: 8
      )

    schedule_coverage = schedule_coverage_contract(meeting_prep)

    %{
      "date" => Date.to_iso8601(local_date),
      "generated_at" => DateTime.to_iso8601(now),
      "timezone_offset_hours" => offset_hours,
      "calendar" => %{
        "preferred_source" => calendar_source,
        "today_events" => today_events,
        "tomorrow_first_event" => tomorrow_first_event,
        "upcoming_local" =>
          local_calendar_events
          |> Enum.map(&calendar_event_for_prompt/1)
          |> Enum.take(@local_calendar_limit)
      },
      "meeting_prep" => meeting_prep,
      "schedule_coverage" => schedule_coverage,
      "imessage" => %{
        "chats" =>
          imessage_chats
          |> Enum.map(&imessage_chat_for_prompt/1)
          |> Enum.take(@local_imessage_chat_limit),
        "counts" => %{"chats" => length(imessage_chats)}
      },
      "notes" => %{
        "items" =>
          notes
          |> Enum.map(&note_for_prompt/1)
          |> Enum.take(@local_notes_limit),
        "counts" => %{"count" => length(notes)}
      },
      "voice_memos" => %{
        "items" =>
          voice_memos
          |> Enum.map(&voice_memo_for_prompt/1)
          |> Enum.take(@local_voice_memo_limit),
        "counts" => %{"count" => length(voice_memos)}
      },
      "reminders" => %{
        "due_soon" =>
          reminders
          |> Enum.map(&reminder_for_prompt/1)
          |> Enum.take(@local_reminders_limit),
        "counts" => %{
          "open" => length(reminders),
          "due_today" => Enum.count(reminders, &reminder_due_today?(&1, now))
        }
      },
      "files" => %{
        "items" =>
          files
          |> Enum.map(&file_for_prompt/1)
          |> Enum.take(@local_files_limit),
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
      "relationships" =>
        user_id
        |> Crm.summarize_for_prompt(16),
      "deep_memory" =>
        user_id
        |> Memory.prompt_context(query: "morning briefing chief of staff relevance", limit: 10),
      "source_health" =>
        source_bundle
        |> SourceBundle.freshness()
        |> merge_local_source_health(user_id, now,
          imessage: imessage_chats,
          notes: notes,
          voice_memos: voice_memos,
          calendar_local: local_calendar_events,
          reminders: reminders,
          files: files,
          browser_history: visits
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
      context = smoke_test_context(agent, user_id, skill_config, now, opts)
      brief_input = build_brief_input(user_id, now, state, context)

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
                max_tokens_used: effective_llm_max_tokens(state),
                reasoning_effort_used: state.llm_reasoning_effort,
                calendar_today_events:
                  length(get_in(brief_input, ["calendar", "today_events"]) || []),
                meeting_prep_counts: get_in(brief_input, ["meeting_prep", "counts"]),
                source_acquisition:
                  if(Map.has_key?(context, :assistant_fetch_telemetry),
                    do: "acquired",
                    else: "provided"
                  )
              }

              case parsed do
                {:ok, brief} ->
                  result = {:ok, brief, diagnostics}

                  if Keyword.get(opts, :send, false) do
                    deliver_smoke_brief(user_id, brief, diagnostics)
                  end

                  result

                {:error, reason} ->
                  {:error, {:invalid_brief, reason}, diagnostics}
              end

            {:error, reason} ->
              elapsed_ms = System.monotonic_time(:millisecond) - started_ms

              {:error, {:llm_call_failed, reason},
               %{
                 elapsed_ms: elapsed_ms,
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
        "email_scan_limit",
        "slack_channel_scan_limit",
        "slack_message_scan_limit",
        "news_enabled",
        "news_limit",
        "news_feeds",
        "lookback_hours",
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

  defp deliver_smoke_brief(user_id, brief, diagnostics) do
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

        title = read_string(brief, "title", "Morning briefing")
        summary = read_string(brief, "summary", "")
        body = read_string(brief, "body", "")

        text =
          [
            title,
            summary,
            body,
            "",
            "[smoke-test • #{diagnostics.tokens_out} out tokens • #{diagnostics.elapsed_ms}ms]"
          ]
          |> Enum.reject(&(&1 == ""))
          |> Enum.join("\n\n")

        Maraithon.TelegramResponder.send(chat_id, text)
    end
  end

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
          "reasoning_effort" => state.llm_reasoning_effort
        }
        |> maybe_put("model", state.llm_model)

      {:ok, params}
    end
  end

  defp morning_prompt(brief_input) do
    with {:ok, skill} <- MarkdownSkill.load_file(@skill_path),
         {:ok, input_json} <- Jason.encode(brief_input) do
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

       Meeting enrichment rule:
       The brief input includes meeting_prep, which is prepared CRM-first. Use CRM context
       before public web context. Use web snippets only as fallback evidence for attendees
       or companies missing from CRM, and keep uncertainty visible when the evidence is thin.

       Schedule coverage contract:
       Required external meetings are a hard coverage contract, not a ranking hint. If
       schedule_coverage.required_meetings is non-empty, Today's Schedule must include
       every item in that list. Use model judgment for what the meeting means and how Kent
       should prepare; do not write a heuristic digest. Do not say the calendar is open
       when calendar.today_events or schedule_coverage.required_meetings is non-empty.
       Before returning JSON, perform a final model review that the body includes every
       required external meeting with time, attendee or organization, why it matters, and
       the prep point, decision, or risk Kent should carry into it.

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
        OpenLoops.ingest_todos(user_id, candidates, source: "chief_of_staff_morning_briefing")
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
      todo_skipped_count: result.skipped_count
    }
  end

  defp todo_event_payload({:error, reason}) do
    %{
      todo_count: 0,
      todo_skipped_count: 0,
      todo_error: inspect(reason)
    }
  end

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
      "snippet" => truncate(read_string(message, "snippet", ""), 240),
      "body_available" => body_available,
      "body_status" =>
        read_string(message, "body_status", if(body_available, do: "available", else: "missing")),
      "body" => truncate(body, 6_000)
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
      "text" => truncate(read_string(message, "text", ""), 260),
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
      "latest_snippet" => latest && truncate(latest.text || "", 160),
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
      "snippet" => truncate(note.snippet || "", 240),
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
      "snippet" => truncate(memo.snippet || "", 240),
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

  defp maybe_fetch_local(user_id, bundle_items, fetch_fun)
       when is_binary(user_id) and is_list(bundle_items) and is_function(fetch_fun, 1) do
    case bundle_items do
      [] -> fetch_fun.(user_id)
      items -> items
    end
  end

  defp maybe_fetch_local(_user_id, _bundle_items, _fetch_fun), do: []

  defp merge_local_source_health(freshness, user_id, now, sources) when is_map(freshness) do
    devices_last_seen = latest_device_seen_at(user_id)

    Enum.reduce(sources, freshness, fn {source, items}, acc ->
      status = local_source_status(items, devices_last_seen, now)

      health =
        Map.merge(Map.get(acc, to_string(source), %{}), %{
          "source" => to_string(source),
          "status" => status,
          "device_last_seen_at" => prompt_time(devices_last_seen),
          "item_count" => length(items)
        })

      Map.put(acc, to_string(source), health)
    end)
  end

  defp merge_local_source_health(freshness, _user_id, _now, _sources), do: freshness

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

  defp required_schedule_meeting_for_prompt(meeting) when is_map(meeting) do
    %{
      "event_id" => read_string(meeting, "event_id", nil),
      "summary" => read_string(meeting, "summary", nil),
      "start" => read_any(meeting, "start"),
      "end" => read_any(meeting, "end"),
      "external_attendees" => read_list(meeting, "external_attendees"),
      "candidate_people_and_orgs" => read_list(meeting, "candidate_people_and_orgs"),
      "crm_context" => read_list(meeting, "crm_context"),
      "web_context" => read_list(meeting, "web_context"),
      "data_gaps" => read_list(meeting, "data_gaps"),
      "briefing_reason" => read_string(meeting, "briefing_reason", nil)
    }
    |> compact_map()
  end

  defp event_sort_key(event) when is_map(event) do
    case read_any(event, "start") do
      %DateTime{} = value -> DateTime.to_unix(value, :microsecond)
      %{"date" => value} when is_binary(value) -> value
      value when is_binary(value) -> value
      _ -> 0
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

  defp normalize_reasoning_effort(value, default) do
    case normalize_string(value) do
      effort when is_binary(effort) ->
        normalized = String.downcase(effort)

        case normalized do
          effort when effort in ["high", "xhigh"] -> effort
          effort when effort in ["low", "medium"] -> "high"
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
