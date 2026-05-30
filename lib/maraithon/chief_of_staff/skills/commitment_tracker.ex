defmodule Maraithon.ChiefOfStaff.Skills.CommitmentTracker do
  @moduledoc """
  Daily model-backed commitment tracker for the AI Chief of Staff.
  """

  @behaviour Maraithon.ChiefOfStaff.Skill

  alias Maraithon.AgentHarness.MarkdownSkill
  alias Maraithon.Briefs
  alias Maraithon.ChiefOfStaff.{SourceBundle, SourceScope}
  alias Maraithon.Crm
  alias Maraithon.Memory
  alias Maraithon.OpenLoops
  alias Maraithon.SourceLabels
  alias Maraithon.Timezones
  alias Maraithon.Todos
  alias Maraithon.Todos.Todo
  alias Maraithon.Tracing

  @default_timezone_offset_hours -5
  @default_review_hour 7
  @default_email_scan_limit 80
  @default_event_scan_limit 40
  @default_lookback_hours 24
  @default_calendar_forward_days 7
  @default_llm_max_tokens 8_000
  @default_llm_reasoning_effort "high"
  @skill_path "priv/agents/skills/chief_of_staff/commitment_tracker.md"

  @impl true
  def id, do: "commitment_tracker"

  @impl true
  def label, do: "Commitment tracker"

  @impl true
  def description do
    "Finds work-related promises and asks, then saves them as open work."
  end

  @impl true
  def default_config do
    %{
      "assistant_behavior" => "ai_chief_of_staff",
      "timezone_offset_hours" => @default_timezone_offset_hours,
      "commitment_review_hour_local" => @default_review_hour,
      "email_scan_limit" => @default_email_scan_limit,
      "event_scan_limit" => @default_event_scan_limit,
      "lookback_hours" => @default_lookback_hours,
      "calendar_forward_days" => @default_calendar_forward_days,
      "llm_max_tokens" => @default_llm_max_tokens,
      "llm_reasoning_effort" => @default_llm_reasoning_effort
    }
  end

  @impl true
  def requirements do
    [
      %{
        kind: :provider_service,
        provider: "google",
        service: "gmail",
        label: "Gmail",
        description: "Required to scan recent sent and received mail for commitments.",
        required?: true
      },
      %{
        kind: :provider_service,
        provider: "google",
        service: "calendar",
        label: "Google Calendar",
        description: "Required to scan upcoming events for time-bound commitments.",
        required?: true
      },
      %{
        kind: :provider,
        provider: "telegram",
        label: "Telegram",
        description: "Needed to deliver the commitment tracker summary.",
        required?: false
      }
    ]
  end

  @impl true
  def subscriptions(config, user_id) when is_binary(user_id) do
    SourceScope.subscriptions(Map.get(config, "source_scope", %{}), user_id)
  end

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
      review_hour:
        integer_in_range(config["commitment_review_hour_local"], @default_review_hour, 0, 23),
      email_scan_limit:
        integer_in_range(config["email_scan_limit"], @default_email_scan_limit, 1, 200),
      event_scan_limit:
        integer_in_range(config["event_scan_limit"], @default_event_scan_limit, 1, 120),
      lookback_hours: integer_in_range(config["lookback_hours"], @default_lookback_hours, 1, 168),
      calendar_forward_days:
        integer_in_range(
          config["calendar_forward_days"],
          @default_calendar_forward_days,
          1,
          30
        ),
      llm_model: normalize_string(config["llm_model"]),
      llm_max_tokens:
        integer_in_range(config["llm_max_tokens"], @default_llm_max_tokens, 512, 12_000),
      llm_reasoning_effort:
        normalize_reasoning_effort(config["llm_reasoning_effort"], @default_llm_reasoning_effort),
      pending_tracker_input: nil,
      pending_dedupe_key: nil,
      last_run_keys: %{}
    }
  end

  @impl true
  def handle_wakeup(state, context) do
    user_id = state.user_id || normalize_string(context[:user_id])
    now = context[:timestamp] || DateTime.utc_now()
    period_key = local_period_key(now, timezone_offset_hours_at(now, state))
    dedupe_key = "commitment_tracker:#{period_key}"

    cond do
      is_nil(user_id) ->
        {:idle, state}

      not scheduled_trigger?(context) ->
        {:idle, %{state | user_id: user_id}}

      Map.get(state.last_run_keys, "daily") == period_key ->
        {:idle, %{state | user_id: user_id}}

      not due_now?(now, state) ->
        {:idle, %{state | user_id: user_id}}

      true ->
        tracker_input = build_tracker_input(user_id, now, state, context)

        pending_state = %{
          state
          | user_id: user_id,
            pending_tracker_input: tracker_input,
            pending_dedupe_key: dedupe_key
        }

        case llm_params(tracker_input, state) do
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
    Tracing.with_span(
      "chief_of_staff.commitment_tracker",
      %{
        skill: "commitment_tracker",
        user_id: context[:user_id] || state.user_id,
        finish_reason: llm_finish_reason(response) || "ok"
      },
      fn ->
        tracker_input = state.pending_tracker_input || %{}
        parsed_report = parse_llm_report(response)

        {report, generation_mode, error_message} =
          report_or_error_notice(parsed_report, response, tracker_input)

        if generation_mode == "error" do
          Tracing.record_error(
            "commitment_tracker generation failed: " <>
              String.slice(error_message || "unknown", 0, 300)
          )
        end

        todo_result =
          if generation_mode == "llm" do
            persist_model_todos(context[:user_id] || state.user_id, report, tracker_input)
          else
            {:ok, :no_todos}
          end

        report = append_todo_write_summary(report, todo_result)

        attrs = %{
          "cadence" => "commitment_tracker",
          "scheduled_for" =>
            read_string(
              tracker_input,
              "generated_at",
              DateTime.utc_now() |> DateTime.to_iso8601()
            ),
          "dedupe_key" =>
            state.pending_dedupe_key ||
              "commitment_tracker:#{read_string(tracker_input, "date", "unknown")}",
          "status" => "pending",
          "title" =>
            report
            |> read_string(
              "title",
              "Open work review - #{read_string(tracker_input, "date", "today")}"
            )
            |> truncate(180),
          "summary" =>
            report
            |> read_string("summary", "Review new commitments captured from connected sources.")
            |> truncate(500),
          "body" =>
            report
            |> read_string("body", "Open work review did not produce a body.")
            |> truncate(3_900),
          "error_message" => error_message,
          "metadata" => %{
            "agent_behavior" => state.assistant_behavior,
            "assistant_behavior" => state.assistant_behavior,
            "assistant_cycle_id" => context[:assistant_cycle_id],
            "brief_type" => id(),
            "error_message" => error_message,
            "generation_mode" => generation_mode,
            "llm_finish_reason" => llm_finish_reason(response),
            "origin_skill_id" => id(),
            "source_backed" => true,
            "tracker_input" => compact_tracker_input_for_metadata(tracker_input),
            "source_health" => read_map(tracker_input, "source_health"),
            "source_access" => read_map(tracker_input, "source_access"),
            "todo_write" => summarize_todo_result(todo_result)
          }
        }

        case Briefs.record(context[:user_id] || state.user_id, context[:agent_id], attrs) do
          {:ok, brief_record} ->
            period_key = read_string(tracker_input, "date", nil)

            event_type =
              if generation_mode in ["llm", "source_fallback"],
                do: :briefs_recorded,
                else: :brief_generation_failed

            {:emit,
             {event_type,
              %{
                count: 1,
                error_message: error_message,
                generation_mode: generation_mode,
                user_id: context[:user_id] || state.user_id,
                cadences: ["commitment_tracker"],
                source_backed: true,
                brief_id: brief_record.id
              }
              |> Map.merge(todo_event_payload(todo_result))},
             %{
               state
               | pending_tracker_input: nil,
                 pending_dedupe_key: nil,
                 last_run_keys: Map.put(state.last_run_keys, "daily", period_key)
             }}

          {:error, _reason} ->
            {:idle, %{state | pending_tracker_input: nil, pending_dedupe_key: nil}}
        end
      end
    )
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
    {:absolute, next_review_occurrence(now, state)}
  end

  def build_tracker_input(user_id, now, state, context) do
    source_bundle = context[:source_bundle] || %{}
    offset_hours = timezone_offset_hours_at(now, state)
    local_date = local_date(now, offset_hours)
    lookback_start = DateTime.add(now, -state.lookback_hours, :hour)
    calendar_end = Date.add(local_date, state.calendar_forward_days)

    inbox_messages =
      source_bundle
      |> SourceBundle.gmail_inbox_messages()
      |> Enum.filter(&recent_gmail_message?(&1, lookback_start))

    sent_messages =
      source_bundle
      |> SourceBundle.gmail_sent_messages()
      |> Enum.filter(&recent_gmail_message?(&1, lookback_start))

    calendar_events =
      source_bundle
      |> SourceBundle.calendar_events()
      |> Enum.filter(&event_in_date_window?(&1, local_date, calendar_end, offset_hours))
      |> Enum.sort_by(&event_sort_key/1)

    %{
      "date" => Date.to_iso8601(local_date),
      "generated_at" => DateTime.to_iso8601(now),
      "timezone" => timezone_label(state, now),
      "timezone_offset_hours" => offset_hours,
      "lookback_hours" => state.lookback_hours,
      "calendar_forward_days" => state.calendar_forward_days,
      "source_access" => source_access(source_bundle),
      "gmail" => %{
        "recent_inbox" =>
          inbox_messages
          |> Enum.map(&gmail_message_for_prompt/1)
          |> Enum.take(state.email_scan_limit),
        "recent_sent" =>
          sent_messages
          |> Enum.map(&gmail_message_for_prompt/1)
          |> Enum.take(state.email_scan_limit),
        "counts" => %{
          "recent_inbox" => length(inbox_messages),
          "recent_sent" => length(sent_messages)
        }
      },
      "calendar" => %{
        "window_start" => Date.to_iso8601(local_date),
        "window_end" => Date.to_iso8601(calendar_end),
        "upcoming_events" =>
          calendar_events
          |> Enum.map(&calendar_event_for_prompt/1)
          |> Enum.take(state.event_scan_limit),
        "counts" => %{"upcoming_events" => length(calendar_events)}
      },
      "open_work" => %{
        "todos" =>
          user_id
          |> Todos.list_open_for_user(limit: 40)
          |> Enum.map(&todo_for_prompt/1)
      },
      "relationships" => Crm.summarize_for_prompt(user_id, 24),
      "deep_memory" =>
        Memory.prompt_context(user_id,
          query:
            "commitment tracker work commitments promises asks pending replies relevance feedback",
          limit: 12
        ),
      "source_health" => SourceBundle.freshness(source_bundle)
    }
  end

  defp llm_params(tracker_input, state) do
    with {:ok, prompt} <- commitment_prompt(tracker_input) do
      params =
        %{
          "messages" => [
            %{
              "role" => "user",
              "content" => prompt
            }
          ],
          "max_tokens" => state.llm_max_tokens,
          "temperature" => 0.1,
          "reasoning_effort" => state.llm_reasoning_effort
        }
        |> maybe_put("model", state.llm_model)

      {:ok, params}
    end
  end

  defp commitment_prompt(tracker_input) do
    with {:ok, skill} <- MarkdownSkill.load_file(@skill_path),
         {:ok, input_json} <- Jason.encode(tracker_input) do
      {:ok,
       """
       Execute the loaded Markdown skill against the supplied connector context.

       Skill: #{skill.name}
       Skill path: #{@skill_path}

       Response contract:
       Return only valid JSON with this shape:
       {
         "title": "Open work review - YYYY-MM-DD",
         "summary": "...",
         "body": "Telegram-friendly plain text or simple markdown. No tables.",
         "pending_replies": [],
         "already_tracked": [],
         "missing_sources": [],
         "todos": [
           {
             "source": "gmail | calendar | imessage | whatsapp | chief_of_staff_commitment_tracker",
             "title": "concise action title",
             "summary": "actual todo",
             "next_action": "suggested next action",
             "due_at": "ISO-8601 datetime or omitted",
             "notes": "source evidence and metadata",
             "action_plan": "draft or plan of next action",
             "owner_user_id": null,
             "owner_label": "null for the main user, or named non-user owner",
             "source_account_label": "email/calendar account when known",
             "source_item_id": "message/thread/event id when known",
             "source_occurred_at": "ISO-8601 datetime when known",
             "dedupe_key": "stable semantic key",
             "people": [],
             "memories": [],
             "metadata": {
               "commitment_direction": "i_owe | asked_of_me | pending_reply",
               "source_ref": "...",
               "source_tags": ["runner","gmail"],
               "quote": "...",
               "company": "company or organization when known",
               "relationship_context": "why this person matters or why they are in the thread",
               "relationship_strength": 0,
               "why_it_matters": "business, project, or relationship reason this deserves attention",
               "life_domain": "personal | family | home | work when known",
               "omni_project": "best-fit OmniFocus project name when known"
             }
           }
         ]
       }

       Do not invent source access. Do not claim iMessage, WhatsApp, OmniFocus, or
       calendar write/delete were scanned or changed unless source_access says they
       are available. Current Maraithon writes commitment work items to built-in
       open work; OmniFocus/calendar mirrors are future integrations unless tools
       are explicitly present in the source_access payload.

       User-facing copy requirements:
       - Frame the report as "Open work review"; do not write "Commitment
         Tracker", skill names, source_behavior values, or automation names in
         title, summary, body, or work-item text.
       - Write directly to the operator as "you"; never write "the user" or
         "User committed".
       - If no new commitments are saved, do not write an all-clear. State
         what was checked, what remains unknown, and end with "Today's move:".
       - Every work item title, summary, next_action, notes, and action_plan must
         answer: who is involved, what the commitment is about, why it matters,
         and the best next step.
       - If the exact ask is ambiguous, say "open the source thread to confirm
         the exact promise" rather than creating a generic follow-up item.
       - Include company, organization, relationship context, project, source
         quote/body excerpt, and confidence in metadata whenever available.

       Skill instructions:
       #{skill.instructions}

       Commitment tracker input JSON:
       #{input_json}
       """}
    end
  end

  defp parse_llm_report(response) do
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

        {:ok,
         %{
           "title" => title,
           "summary" => summary,
           "body" => body,
           "todos" => todos,
           "pending_replies" => read_list(data, "pending_replies"),
           "already_tracked" => read_list(data, "already_tracked"),
           "missing_sources" => read_list(data, "missing_sources")
         }}
      else
        _ -> {:error, "model_response_invalid_or_missing_required_commitment_json"}
      end
    end
  end

  defp report_or_error_notice({:ok, report}, _response, tracker_input),
    do: {repair_commitment_report(report, tracker_input), "llm", nil}

  defp report_or_error_notice({:error, reason}, response, tracker_input) do
    error_message =
      [
        "Commitment tracker model synthesis failed",
        reason,
        llm_finish_reason(response) && "finish_reason=#{llm_finish_reason(response)}"
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(": ")

    {fallback_commitment_report(tracker_input), "source_fallback", error_message}
  end

  defp repair_commitment_report(report, tracker_input) when is_map(report) do
    report = normalize_report_public_copy(report)
    todos = read_list(report, "todos")

    if todos == [] do
      report
      |> Map.put("summary", repair_empty_commitment_summary(report, tracker_input))
      |> Map.put("body", repair_empty_commitment_body(report, tracker_input))
    else
      report
    end
  end

  defp repair_commitment_report(report, _tracker_input), do: report

  defp normalize_report_public_copy(report) when is_map(report) do
    report
    |> Map.update("title", nil, &normalize_commitment_report_text/1)
    |> Map.update("summary", nil, &normalize_commitment_report_text/1)
    |> Map.update("body", nil, &normalize_commitment_report_text/1)
  end

  defp normalize_commitment_report_text(text) when is_binary(text) do
    text
    |> String.replace(~r/\bCommitment Tracker\b/i, "Open work review")
    |> String.replace(~r/\bCommitment tracker\b/i, "Open work review")
    |> String.replace(~r/\bcommitment tracker\b/i, "open work review")
    |> String.replace(~r/\bchief_of_staff_commitment_tracker\b/i, "open work review")
  end

  defp normalize_commitment_report_text(value), do: value

  defp repair_empty_commitment_summary(report, tracker_input) do
    summary = read_string(report, "summary", "")

    if overconfident_empty_summary?(summary) do
      empty_commitment_fallback_summary(tracker_input)
    else
      summary
    end
  end

  defp repair_empty_commitment_body(report, tracker_input) do
    body = read_string(report, "body", "")
    open_todos = tracker_input |> read_map("open_work") |> read_list("todos")
    gmail = read_map(tracker_input, "gmail")
    calendar = read_map(tracker_input, "calendar")
    inbox_count = gmail |> read_list("recent_inbox") |> length()
    sent_count = gmail |> read_list("recent_sent") |> length()
    calendar_count = calendar |> read_list("upcoming_events") |> length()

    [
      body,
      unless contains_heading?(body, "Checked") do
        fallback_section(
          "Checked",
          fallback_checked_lines(open_todos, inbox_count, sent_count, calendar_count)
        )
      end,
      unless contains_heading?(body, "Unknowns") do
        fallback_section(
          "Unknowns",
          fallback_unknown_lines(inbox_count, sent_count, calendar_count)
        )
      end,
      unless String.contains?(String.downcase(body), "today's move:") do
        fallback_commitment_move(open_todos, inbox_count, sent_count, calendar_count)
      end
    ]
    |> Enum.reject(&blank?/1)
    |> Enum.join("\n\n")
    |> String.trim()
  end

  defp empty_commitment_fallback_summary(tracker_input) when is_map(tracker_input) do
    open_todos = tracker_input |> read_map("open_work") |> read_list("todos")
    gmail = read_map(tracker_input, "gmail")
    calendar = read_map(tracker_input, "calendar")

    fallback_commitment_summary(
      open_todos,
      gmail |> read_list("recent_inbox") |> length(),
      gmail |> read_list("recent_sent") |> length(),
      calendar |> read_list("upcoming_events") |> length()
    )
  end

  defp empty_commitment_fallback_summary(_tracker_input) do
    fallback_commitment_summary([], 0, 0, 0)
  end

  defp overconfident_empty_summary?(summary) when is_binary(summary) do
    normalized = summary |> String.downcase() |> String.trim()

    normalized == "" or
      String.contains?(normalized, "no new commitments were found") or
      String.contains?(normalized, "no new commitments found") or
      String.contains?(normalized, "nothing new was found") or
      String.contains?(normalized, "nothing is owed") or
      String.contains?(normalized, "all clear")
  end

  defp overconfident_empty_summary?(_summary), do: true

  defp contains_heading?(body, heading) when is_binary(body) and is_binary(heading) do
    Regex.match?(~r/(^|\n)\s{0,3}#{Regex.escape(heading)}\s*:?(\n|$)/i, body) or
      Regex.match?(~r/(^|\n)\s{0,3}#{Regex.escape("## " <> heading)}\s*(\n|$)/i, body)
  end

  defp contains_heading?(_body, _heading), do: false

  defp fallback_commitment_report(tracker_input) when is_map(tracker_input) do
    open_todos = tracker_input |> read_map("open_work") |> read_list("todos")
    gmail = read_map(tracker_input, "gmail")
    calendar = read_map(tracker_input, "calendar")
    inbox_count = gmail |> read_list("recent_inbox") |> length()
    sent_count = gmail |> read_list("recent_sent") |> length()
    calendar_count = calendar |> read_list("upcoming_events") |> length()

    body =
      [
        fallback_section(
          "Needs Your Attention",
          fallback_open_work_lines(open_todos, tracker_input)
        ),
        fallback_section(
          "Checked",
          fallback_checked_lines(open_todos, inbox_count, sent_count, calendar_count)
        ),
        fallback_section(
          "Unknowns",
          fallback_unknown_lines(inbox_count, sent_count, calendar_count)
        ),
        fallback_commitment_move(open_todos, inbox_count, sent_count, calendar_count)
      ]
      |> Enum.reject(&blank?/1)
      |> Enum.join("\n\n")

    %{
      "title" => fallback_commitment_title(open_todos),
      "summary" =>
        fallback_commitment_summary(open_todos, inbox_count, sent_count, calendar_count),
      "body" => body,
      "todos" => []
    }
  end

  defp fallback_commitment_report(_tracker_input) do
    fallback_commitment_report(%{})
  end

  defp fallback_commitment_title(open_todos) do
    if length(open_todos) > 0 do
      "Open work review: check existing work"
    else
      "Open work review needs source review"
    end
  end

  defp fallback_commitment_summary(open_todos, inbox_count, sent_count, calendar_count) do
    open_count = length(open_todos)
    checked_count = inbox_count + sent_count + calendar_count

    cond do
      open_count > 0 ->
        "Start with #{count_phrase(open_count, "existing open item", "existing open items")}; no new commitments were saved from this pass."

      checked_count > 0 ->
        "No new commitments were saved from this pass; review the checked source threads before assuming open work is clear."

      true ->
        "No reliable commitment review was available; refresh Gmail and Calendar, then check the most urgent thread."
    end
  end

  defp fallback_open_work_lines(open_todos, tracker_input) do
    case Enum.take(open_todos, 5) do
      [] ->
        [
          "- No existing open commitment is already saved in open work. Do not treat that as clear; check the specific thread before assuming nothing is owed."
        ]

      todos ->
        Enum.map(todos, &fallback_todo_line(&1, tracker_input))
    end
  end

  defp fallback_todo_line(todo, tracker_input) when is_map(todo) do
    title = read_string(todo, "title", "Open commitment")

    next_action =
      read_string(
        todo,
        "next_action",
        read_string(todo, "summary", "Open the source thread and decide the next action.")
      )

    due = todo |> read_any("due_at") |> fallback_due_label(tracker_input)
    source = read_string(todo, "source", nil)
    source_account = read_string(todo, "source_account_label", nil)

    [
      "- ",
      title,
      fallback_due_sentence(due),
      " Next: ",
      next_action,
      fallback_source_phrase(source, source_account)
    ]
    |> Enum.join("")
  end

  defp fallback_todo_line(_todo, _tracker_input) do
    "- Open commitment. Next: open the source thread and decide the next action."
  end

  defp fallback_due_sentence(nil), do: "."
  defp fallback_due_sentence(""), do: "."
  defp fallback_due_sentence(due), do: ". Due #{due}."

  defp fallback_due_label(%DateTime{} = value, tracker_input) do
    offset = tracker_input_timezone_offset_hours(tracker_input)
    label = tracker_input_timezone_label(tracker_input, offset)

    value
    |> DateTime.add(offset, :hour)
    |> Calendar.strftime("%b %-d, %Y at %-I:%M %p #{label}")
  end

  defp fallback_due_label(%NaiveDateTime{} = value, _tracker_input) do
    Calendar.strftime(value, "%b %-d, %Y at %-I:%M %p")
  end

  defp fallback_due_label(%Date{} = value, _tracker_input),
    do: Calendar.strftime(value, "%b %-d, %Y")

  defp fallback_due_label(value, tracker_input) when is_binary(value) do
    value = String.trim(value)

    cond do
      value == "" ->
        nil

      match?({:ok, _, _}, DateTime.from_iso8601(value)) ->
        {:ok, datetime, _offset} = DateTime.from_iso8601(value)
        fallback_due_label(datetime, tracker_input)

      match?({:ok, _}, Date.from_iso8601(value)) ->
        {:ok, date} = Date.from_iso8601(value)
        fallback_due_label(date, tracker_input)

      true ->
        value
    end
  end

  defp fallback_due_label(_value, _tracker_input), do: nil

  defp tracker_input_timezone_offset_hours(tracker_input) when is_map(tracker_input) do
    case read_any(tracker_input, "timezone_offset_hours") do
      value when is_integer(value) -> Timezones.normalize_offset(value)
      value when is_float(value) -> value |> trunc() |> Timezones.normalize_offset()
      value when is_binary(value) -> Timezones.normalize_offset(value)
      _ -> @default_timezone_offset_hours
    end
  end

  defp tracker_input_timezone_offset_hours(_tracker_input), do: @default_timezone_offset_hours

  defp tracker_input_timezone_label(tracker_input, offset) when is_map(tracker_input) do
    case read_string(tracker_input, "timezone", nil) do
      nil ->
        Timezones.label(nil, offset)

      value ->
        case Timezones.normalize(value) do
          normalized when is_binary(normalized) -> Timezones.label(normalized, offset)
          _ -> value
        end
    end
  end

  defp tracker_input_timezone_label(_tracker_input, offset), do: Timezones.label(nil, offset)

  defp fallback_source_phrase(source, account) do
    label = fallback_source_label(source)
    account = fallback_account_label(account, label)

    cond do
      blank?(label) and blank?(account) -> "."
      blank?(label) -> " From #{account}."
      blank?(account) -> " From #{label}."
      true -> " From #{label} (#{account})."
    end
  end

  defp fallback_source_label(nil), do: nil
  defp fallback_source_label(""), do: nil
  defp fallback_source_label(source), do: SourceLabels.label(source, fallback: nil)

  defp fallback_account_label(account, source_label) when is_binary(account) do
    account = String.trim(account)

    cond do
      account == "" -> nil
      String.downcase(account) == String.downcase(to_string(source_label || "")) -> nil
      true -> account
    end
  end

  defp fallback_account_label(_account, _source_label), do: nil

  defp fallback_checked_lines(open_todos, inbox_count, sent_count, calendar_count) do
    [
      "- Gmail checked: #{count_phrase(inbox_count, "recent inbox message", "recent inbox messages")} and #{count_phrase(sent_count, "recent sent message", "recent sent messages")}.",
      "- Calendar checked: #{count_phrase(calendar_count, "upcoming event", "upcoming events")}.",
      "- Existing open work checked: #{count_phrase(length(open_todos), "open item", "open items")}."
    ]
  end

  defp fallback_unknown_lines(inbox_count, sent_count, calendar_count) do
    checked_count = inbox_count + sent_count + calendar_count

    [
      "- No new commitments were saved because the checked source evidence did not clearly show a new promise.",
      if(checked_count > 0,
        do: "- Anything outside the checked Gmail, Calendar, and existing open work is unknown.",
        else:
          "- Gmail, Calendar, and source threads still need a fresh pass before you rely on open work."
      )
    ]
  end

  defp fallback_commitment_move(open_todos, inbox_count, sent_count, calendar_count) do
    cond do
      length(open_todos) > 0 ->
        "Today's move: clear or explicitly keep the first open item before inbox triage."

      inbox_count + sent_count > 0 ->
        "Today's move: inspect the highest-stakes recent thread and decide whether you owe a reply."

      calendar_count > 0 ->
        "Today's move: review the next meeting for promises you owe before the day gets busy."

      true ->
        "Today's move: refresh Gmail and Calendar, then check the one thread most likely to contain a promise."
    end
  end

  defp fallback_section(_heading, []), do: nil

  defp fallback_section(heading, lines) when is_list(lines) do
    "## #{heading}\n" <> Enum.join(lines, "\n")
  end

  defp count_phrase(1, singular, _plural), do: "1 #{singular}"
  defp count_phrase(count, _singular, plural), do: "#{count} #{plural}"

  defp persist_model_todos(_user_id, %{"todos" => []}, _tracker_input), do: {:ok, :no_todos}
  defp persist_model_todos(nil, _report, _tracker_input), do: {:ok, :no_todos}

  defp persist_model_todos(user_id, %{"todos" => todos}, tracker_input)
       when is_binary(user_id) and is_list(todos) do
    candidates =
      todos
      |> Enum.filter(&is_map/1)
      |> Enum.map(&commitment_todo_candidate(&1, tracker_input))

    case candidates do
      [] ->
        {:ok, :no_todos}

      candidates ->
        OpenLoops.ingest_todos(user_id, candidates,
          source: "chief_of_staff_commitment_tracker",
          now: read_string(tracker_input, "generated_at", nil)
        )
    end
  end

  defp persist_model_todos(_user_id, _report, _tracker_input), do: {:ok, :no_todos}

  defp commitment_todo_candidate(todo, tracker_input) when is_map(todo) do
    metadata =
      todo
      |> read_map("metadata")
      |> Map.merge(%{
        "origin_skill_id" => id(),
        "origin_cadence" => "commitment_tracker",
        "tracker_date" => read_string(tracker_input, "date", nil),
        "tracker_generated_at" => read_string(tracker_input, "generated_at", nil)
      })
      |> compact_map()

    todo
    |> stringify_top_level_keys()
    |> Map.put("metadata", metadata)
    |> Map.put_new("source", "chief_of_staff_commitment_tracker")
    |> Map.put_new("kind", "general")
    |> Map.put_new("source_occurred_at", read_string(tracker_input, "generated_at", nil))
  end

  defp append_todo_write_summary(report, {:ok, :no_todos}), do: report

  defp append_todo_write_summary(report, {:ok, result}) when is_map(result) do
    todos = Map.get(result, :todos, [])
    skipped_count = Map.get(result, :skipped_count, 0)

    lines =
      todos
      |> Enum.take(10)
      |> Enum.map(fn %Todo{} = todo ->
        "- #{todo_title(todo)}"
      end)

    additional_count = max(length(todos) - length(lines), 0)

    summary_lines =
      []
      |> maybe_append(lines != [], ["", "Added to open work:"] ++ lines)
      |> maybe_append(additional_count > 0, [saved_more_line(additional_count)])
      |> maybe_append(skipped_count > 0, [already_covered_line(skipped_count)])

    if summary_lines == [] do
      report
    else
      append_report_body(report, Enum.join(summary_lines, "\n"))
    end
  end

  defp append_todo_write_summary(report, {:error, _reason}) do
    append_report_body(
      report,
      "\nMaraithon found possible commitments, but could not save them as open work. Review the checked summary above before acting."
    )
  end

  defp todo_title(%Todo{title: title}) when is_binary(title) and title != "", do: title
  defp todo_title(%Todo{}), do: "Open commitment"

  defp saved_more_line(1), do: "- 1 more work item saved."
  defp saved_more_line(count), do: "- #{count} more work items saved."

  defp already_covered_line(1), do: "- Already covered in open work: 1 item."

  defp already_covered_line(count),
    do: "- Already covered in open work: #{count} items."

  defp append_report_body(report, addition) do
    body = read_string(report, "body", "")

    Map.put(report, "body", String.trim(body <> "\n" <> addition))
  end

  defp todo_event_payload({:ok, :no_todos}) do
    %{todo_count: 0, todo_skipped_count: 0}
  end

  defp todo_event_payload({:ok, result}) when is_map(result) do
    %{
      todo_count: length(Map.get(result, :todos, [])),
      todo_skipped_count: Map.get(result, :skipped_count, 0)
    }
  end

  defp todo_event_payload({:error, reason}) do
    %{
      todo_count: 0,
      todo_skipped_count: 0,
      todo_error: inspect(reason)
    }
  end

  defp summarize_todo_result({:ok, :no_todos}) do
    %{"todo_count" => 0, "skipped_count" => 0}
  end

  defp summarize_todo_result({:ok, result}) when is_map(result) do
    %{
      "todo_count" => length(Map.get(result, :todos, [])),
      "skipped_count" => Map.get(result, :skipped_count, 0),
      "decisions" => Map.get(result, :decisions, [])
    }
  end

  defp summarize_todo_result({:error, reason}) do
    %{"todo_count" => 0, "skipped_count" => 0, "error" => inspect(reason)}
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

  defp calendar_event_for_prompt(event) when is_map(event) do
    %{
      "event_id" => read_string(event, "event_id", nil),
      "summary" => read_string(event, "summary", "Untitled event"),
      "start" => prompt_time(read_any(event, "start")),
      "end" => prompt_time(read_any(event, "end")),
      "location" => read_string(event, "location", nil),
      "attendees" => read_list(event, "attendees") |> Enum.take(16),
      "organizer" => read_string(event, "organizer", nil),
      "html_link" => read_string(event, "html_link", nil),
      "account" => read_string(event, "account", read_string(event, "google_account_email", nil))
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
      "source_account_label" => todo.source_account_label,
      "source_item_id" => todo.source_item_id,
      "source_occurred_at" => prompt_time(todo.source_occurred_at),
      "metadata" => summarize_todo_metadata(todo.metadata)
    }
  end

  defp summarize_todo_metadata(metadata) when is_map(metadata) do
    Map.take(metadata, [
      "thread_id",
      "google_account_email",
      "from",
      "to",
      "subject",
      "account_email",
      "source_ref",
      "commitment_direction",
      "origin_skill_id",
      "person",
      "people"
    ])
  end

  defp summarize_todo_metadata(_metadata), do: %{}

  defp source_access(source_bundle) do
    freshness = SourceBundle.freshness(source_bundle)

    %{
      "gmail" => source_status(freshness, "gmail"),
      "google_calendar" => source_status(freshness, "calendar"),
      "imessage" => %{
        "status" => "unavailable",
        "reason" => "imessage_connector_not_available_in_runtime"
      },
      "whatsapp" => %{
        "status" => "unavailable",
        "reason" => "whatsapp_connector_not_available_in_runtime"
      },
      "omnifocus" => %{
        "status" => "unavailable",
        "reason" => "omnifocus_write_tool_not_available_in_runtime"
      },
      "google_calendar_write" => %{
        "status" => "unavailable",
        "reason" => "calendar_create_delete_tools_not_available_in_runtime"
      }
    }
  end

  defp source_status(freshness, source) when is_map(freshness) do
    case Map.get(freshness, source) do
      value when is_map(value) -> value
      _ -> %{"status" => "unavailable", "reason" => "#{source}_not_fetched"}
    end
  end

  defp compact_tracker_input_for_metadata(input) do
    %{
      "date" => read_string(input, "date", nil),
      "generated_at" => read_string(input, "generated_at", nil),
      "timezone" => read_string(input, "timezone", nil),
      "timezone_offset_hours" => tracker_input_timezone_offset_hours(input),
      "counts" => %{
        "gmail_recent_inbox" => length(get_in(input, ["gmail", "recent_inbox"]) || []),
        "gmail_recent_sent" => length(get_in(input, ["gmail", "recent_sent"]) || []),
        "calendar_upcoming_events" =>
          length(get_in(input, ["calendar", "upcoming_events"]) || []),
        "open_todos" => length(get_in(input, ["open_work", "todos"]) || []),
        "relationships" => length(get_in(input, ["relationships"]) || []),
        "deep_memory" => deep_memory_count(input)
      }
    }
  end

  defp deep_memory_count(input) do
    case Map.get(input, "deep_memory") || Map.get(input, :deep_memory) do
      %{count: count} when is_integer(count) -> count
      %{"count" => count} when is_integer(count) -> count
      _other -> 0
    end
  end

  defp recent_gmail_message?(message, lookback_start) when is_map(message) do
    case read_datetime(message, "internal_date") || read_datetime(message, "date") do
      nil -> true
      timestamp -> DateTime.compare(timestamp, lookback_start) != :lt
    end
  end

  defp recent_gmail_message?(_message, _lookback_start), do: false

  defp event_in_date_window?(event, start_date, end_date, offset_hours) when is_map(event) do
    case event |> read_any("start") |> local_date_from_value(offset_hours) do
      nil ->
        true

      event_date ->
        Date.compare(event_date, start_date) in [:eq, :gt] and
          Date.compare(event_date, end_date) in [:eq, :lt]
    end
  end

  defp event_in_date_window?(_event, _start_date, _end_date, _offset_hours), do: false

  defp event_sort_key(event) when is_map(event) do
    case read_any(event, "start") do
      %DateTime{} = value -> DateTime.to_unix(value, :microsecond)
      %{"date" => value} when is_binary(value) -> value
      value when is_binary(value) -> value
      _ -> 0
    end
  end

  defp llm_finish_reason(%{finish_reason: reason}) when is_binary(reason), do: reason
  defp llm_finish_reason(%{"finish_reason" => reason}) when is_binary(reason), do: reason
  defp llm_finish_reason(_response), do: nil

  defp due_now?(now, state) do
    local_now = DateTime.add(now, timezone_offset_hours_at(now, state), :hour)
    local_now.hour >= state.review_hour
  end

  defp next_review_occurrence(now, state) do
    offset_hours = timezone_offset_hours_at(now, state)
    local_now = DateTime.add(now, offset_hours, :hour)
    local_date = DateTime.to_date(local_now)

    scheduled_today =
      local_date
      |> DateTime.new!(Time.new!(state.review_hour, 0, 0), "Etc/UTC")

    target_local =
      if DateTime.compare(local_now, scheduled_today) == :lt do
        scheduled_today
      else
        Date.add(local_date, 1)
        |> DateTime.new!(Time.new!(state.review_hour, 0, 0), "Etc/UTC")
      end

    DateTime.add(target_local, -local_timezone_offset_hours(target_local, state), :hour)
  end

  defp scheduled_trigger?(context) do
    case get_in(context, [:trigger, :type]) do
      nil -> is_nil(context[:event]) and is_nil(context[:last_message])
      :wakeup -> true
      _ -> false
    end
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

  defp timezone_offset_hours_at(%DateTime{} = datetime, state) do
    Timezones.offset_at(Map.get(state, :timezone), datetime, state.timezone_offset_hours)
  end

  defp local_timezone_offset_hours(%DateTime{} = local_datetime, state) do
    Timezones.offset_for_local(
      Map.get(state, :timezone),
      local_datetime,
      state.timezone_offset_hours
    )
  end

  defp timezone_label(state, %DateTime{} = datetime) do
    offset = timezone_offset_hours_at(datetime, state)
    Timezones.label(Map.get(state, :timezone), offset)
  end

  defp decode_json(content) when is_binary(content) do
    content
    |> json_decode_candidates()
    |> Enum.reduce_while({:error, :no_json_candidate}, fn candidate, _error ->
      case Jason.decode(candidate) do
        {:ok, decoded} -> {:halt, {:ok, decoded}}
        {:error, reason} -> {:cont, {:error, reason}}
      end
    end)
  end

  defp json_decode_candidates(content) do
    trimmed = String.trim(content)

    ([trimmed, strip_markdown_json_fence(trimmed)] ++
       fenced_json_candidates(trimmed) ++ [first_balanced_json_object(trimmed)])
    |> Enum.reject(&blank?/1)
    |> Enum.uniq()
  end

  defp strip_markdown_json_fence(content) when is_binary(content) do
    case Regex.run(~r/\A```(?:json)?\s*(.*?)\s*```\z/s, content, capture: :all_but_first) do
      [json] -> String.trim(json)
      _ -> content
    end
  end

  defp fenced_json_candidates(content) when is_binary(content) do
    ~r/```(?:json)?\s*(.*?)\s*```/s
    |> Regex.scan(content, capture: :all_but_first)
    |> List.flatten()
    |> Enum.map(&String.trim/1)
  end

  defp first_balanced_json_object(content) when is_binary(content) do
    content
    |> String.graphemes()
    |> Enum.reduce_while({:searching, []}, &collect_first_json_object/2)
    |> case do
      {:done, chars} -> chars |> Enum.reverse() |> Enum.join() |> String.trim()
      _ -> nil
    end
  end

  defp collect_first_json_object("{", {:searching, _chars}),
    do: {:cont, {:collecting, 1, false, false, ["{"]}}

  defp collect_first_json_object(_char, {:searching, _chars}), do: {:cont, {:searching, []}}

  defp collect_first_json_object(char, {:collecting, depth, in_string?, escaped?, chars}) do
    chars = [char | chars]

    cond do
      in_string? and escaped? ->
        {:cont, {:collecting, depth, true, false, chars}}

      in_string? and char == "\\" ->
        {:cont, {:collecting, depth, true, true, chars}}

      in_string? and char == "\"" ->
        {:cont, {:collecting, depth, false, false, chars}}

      in_string? ->
        {:cont, {:collecting, depth, true, false, chars}}

      char == "\"" ->
        {:cont, {:collecting, depth, true, false, chars}}

      char == "{" ->
        {:cont, {:collecting, depth + 1, false, false, chars}}

      char == "}" ->
        depth = depth - 1

        if depth == 0 do
          {:halt, {:done, chars}}
        else
          {:cont, {:collecting, depth, false, false, chars}}
        end

      true ->
        {:cont, {:collecting, depth, false, false, chars}}
    end
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

  defp read_datetime(_map, _key), do: nil

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

  defp normalize_reasoning_effort(value, _default)
       when value in ["low", "medium", "high", "xhigh"],
       do: value

  defp normalize_reasoning_effort(_value, default), do: default

  defp normalize_string(value) when is_binary(value) do
    value
    |> String.trim()
    |> case do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_string(_value), do: nil

  defp normalize_timezone(value) when is_binary(value) do
    case Timezones.normalize(value) do
      normalized when is_binary(normalized) -> normalized
      _ -> nil
    end
  end

  defp normalize_timezone(_value), do: nil

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, ""), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp maybe_append(list, true, values), do: list ++ values
  defp maybe_append(list, false, _values), do: list

  defp compact_map(map) when is_map(map) do
    map
    |> Enum.reject(fn {_key, value} -> blank?(value) end)
    |> Map.new()
  end

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?([]), do: true
  defp blank?(%{} = map), do: map_size(map) == 0
  defp blank?(_value), do: false

  defp stringify_top_level_keys(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), value} end)
  end

  defp to_existing_atom(key) when is_binary(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> nil
  end

  defp to_existing_atom(_key), do: nil

  defp truncate(nil, _max), do: nil

  defp truncate(value, max) when is_binary(value) and is_integer(max) and max > 3 do
    if String.length(value) <= max do
      value
    else
      value
      |> String.slice(0, max - 3)
      |> Kernel.<>("...")
    end
  end

  defp truncate(value, _max), do: value
end
