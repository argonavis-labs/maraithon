defmodule Maraithon.ChiefOfStaff.Skills.GoalAlignment do
  @moduledoc """
  Chief of Staff skill that keeps active goals in the routine review loop.
  """

  @behaviour Maraithon.ChiefOfStaff.Skill

  alias Maraithon.ChiefOfStaff.{Acquisition, SourceBundle, SourceScope}
  alias Maraithon.Crm
  alias Maraithon.Goals
  alias Maraithon.OpenLoops
  alias Maraithon.Todos

  @default_review_interval_hours 24
  @default_max_goals_per_cycle 8
  @default_lookback_hours 24 * 14
  @default_llm_max_tokens 8_000
  @default_llm_reasoning_effort "medium"
  @source_item_limit 18
  @text_limit 800

  @impl true
  def id, do: "goal_alignment"

  @impl true
  def label, do: "Goal alignment"

  @impl true
  def description do
    "Reviews active goals against connected context and saves concrete next moves when progress, drift, or blockers are detected."
  end

  @impl true
  def default_config do
    %{
      "assistant_behavior" => "ai_chief_of_staff",
      "review_interval_hours" => @default_review_interval_hours,
      "max_goals_per_cycle" => @default_max_goals_per_cycle,
      "source_policy" => "all_connected",
      "lookback_hours" => @default_lookback_hours,
      "email_scan_limit" => 80,
      "event_scan_limit" => 80,
      "slack_channel_scan_limit" => 20,
      "slack_message_scan_limit" => 120,
      "local_calendar_limit" => 120,
      "local_message_limit" => 160,
      "local_chat_limit" => 80,
      "local_voice_memo_limit" => 60,
      "local_note_limit" => 80,
      "local_reminder_limit" => 100,
      "local_file_limit" => 80,
      "local_browser_visit_limit" => 120,
      "llm_max_tokens" => @default_llm_max_tokens,
      "llm_reasoning_effort" => @default_llm_reasoning_effort
    }
  end

  @impl true
  def requirements do
    [
      %{
        kind: :internal,
        label: "Goals",
        description: "Requires active goals saved in Maraithon.",
        required?: true
      },
      %{
        kind: :provider_service,
        provider: "google",
        service: "gmail",
        label: "Gmail",
        description: "Optional inbox and sent-mail context for work, person, and life goals.",
        required?: false
      },
      %{
        kind: :provider_service,
        provider: "google",
        service: "calendar",
        label: "Google Calendar",
        description: "Optional schedule context for goal alignment and time conflicts.",
        required?: false
      },
      %{
        kind: :provider_service,
        provider: "slack",
        service: "channels",
        label: "Slack Channels",
        description: "Optional work context for commitments and blockers.",
        required?: false
      },
      %{
        kind: :provider_service,
        provider: "slack",
        service: "dms",
        label: "Slack DMs",
        description: "Optional relationship and work context for direct-message follow-through.",
        required?: false
      },
      %{
        kind: :provider,
        provider: "mac_companion",
        label: "Mac companion",
        description:
          "Optional local context from iMessage, Notes, Reminders, files, browser history, local calendar, and voice memos.",
        required?: false
      },
      %{
        kind: :provider,
        provider: "telegram",
        label: "Telegram",
        description: "Optional delivery channel for high-signal goal alignment summaries.",
        required?: false
      }
    ]
  end

  @impl true
  def subscriptions(config, user_id) when is_binary(user_id) do
    config
    |> Map.get("source_scope", SourceScope.resolve(user_id))
    |> SourceScope.subscriptions(user_id)
  end

  def subscriptions(_config, _user_id), do: []

  @impl true
  def interested_in?(_config, context) do
    case get_in(context, [:trigger, :type]) do
      nil -> is_nil(context[:event]) and is_nil(context[:last_message])
      :wakeup -> true
      :message -> false
      :pubsub_event -> false
      _other -> false
    end
  end

  @impl true
  def init(config) do
    %{
      user_id: normalize_string(config["user_id"]),
      review_interval_hours:
        integer_in_range(
          config["review_interval_hours"],
          @default_review_interval_hours,
          1,
          168
        ),
      max_goals_per_cycle:
        integer_in_range(config["max_goals_per_cycle"], @default_max_goals_per_cycle, 1, 20),
      lookback_hours:
        integer_in_range(config["lookback_hours"], @default_lookback_hours, 24, 24 * 90),
      llm_max_tokens:
        integer_in_range(config["llm_max_tokens"], @default_llm_max_tokens, 512, 16_000),
      llm_reasoning_effort:
        normalize_reasoning_effort(config["llm_reasoning_effort"], @default_llm_reasoning_effort),
      config: config,
      pending_review_run_id: nil,
      pending_goal_ids: [],
      pending_started_at: nil,
      pending_source_summary: %{},
      last_reviewed_at: nil
    }
  end

  @impl true
  def handle_wakeup(state, context) do
    user_id = state.user_id || normalize_string(context[:user_id])
    now = context[:timestamp] || DateTime.utc_now()

    cond do
      is_nil(user_id) ->
        {:idle, %{state | user_id: user_id}}

      not scheduled_trigger?(context) ->
        {:idle, %{state | user_id: user_id}}

      reviewed_recently?(state, now) ->
        {:idle, %{state | user_id: user_id}}

      true ->
        review_due_goals(user_id, now, state, context)
    end
  end

  @impl true
  def handle_effect_result({:llm_call, response}, state, _context) do
    with {:ok, content} <- response_content(response),
         {:ok, output} <- decode_json_payload(content),
         {:ok, applied} <-
           Goals.apply_review_output(
             state.user_id,
             state.pending_review_run_id,
             Map.put_new(output, "reviewed_goal_ids", state.pending_goal_ids),
             now: state.pending_started_at || DateTime.utc_now()
           ) do
      summary = applied.summary
      next_state = clear_pending(state)

      {:emit,
       {:goal_alignment_reviewed,
        %{
          user_id: state.user_id,
          count: length(Map.get(summary, "reviewed_goal_ids", [])),
          review_run_ids: [applied.review_run.id],
          progress_updates_count: Map.get(summary, "progress_updates_count", 0),
          todos_count: Map.get(summary, "todos_count", 0),
          links_count: Map.get(summary, "links_count", 0),
          advice_count: length(Map.get(summary, "advice", [])),
          source_summary: state.pending_source_summary
        }}, next_state}
    else
      {:error, reason} ->
        fail_pending_review(state, reason)
    end
  end

  def handle_effect_result({_kind, _result}, state, _context), do: {:idle, state}

  @impl true
  def handle_effect_error(:llm_call, reason, state, _context),
    do: fail_pending_review(state, reason)

  def handle_effect_error(_kind, _reason, state, _context), do: {:idle, state}

  @impl true
  def next_wakeup(state) do
    {:relative, state.review_interval_hours * 60 * 60 * 1000}
  end

  defp review_due_goals(user_id, now, state, context) do
    goals =
      Goals.due_for_review(now,
        user_id: user_id,
        limit: state.max_goals_per_cycle
      )

    if goals == [] do
      next_state = %{state | user_id: user_id, last_reviewed_at: now}
      {:idle, next_state}
    else
      context = Map.put_new(context, :timestamp, now)
      {source_bundle, telemetry} = source_bundle(user_id, state, context)
      source_summary = source_summary(source_bundle, telemetry)
      goal_ids = Enum.map(goals, & &1.id)

      case Goals.record_review_run(
             user_id,
             %{
               "goal_id" => List.first(goal_ids),
               "trigger" => "scheduled",
               "status" => "running",
               "started_at" => now,
               "source_summary" => source_summary,
               "metadata" => %{"goal_ids" => goal_ids}
             },
             now: now
           ) do
        {:ok, review_run} ->
          payload = review_payload(user_id, goals, source_bundle, source_summary, now, state)

          next_state = %{
            state
            | user_id: user_id,
              pending_review_run_id: review_run.id,
              pending_goal_ids: goal_ids,
              pending_started_at: now,
              pending_source_summary: source_summary,
              last_reviewed_at: now
          }

          {:effect, {:llm_call, llm_params(payload, state)}, next_state}

        {:error, _reason} ->
          {:idle, %{state | user_id: user_id, last_reviewed_at: now}}
      end
    end
  end

  defp source_bundle(user_id, state, context) do
    case Map.get(context, :source_bundle) do
      %{} = bundle ->
        {bundle, Map.get(context, :assistant_fetch_telemetry, %{})}

      _other ->
        Acquisition.build(user_id, [id()], %{id() => state.config}, context)
    end
  end

  defp review_payload(user_id, goals, source_bundle, source_summary, now, state) do
    %{
      "generated_at" => DateTime.to_iso8601(now),
      "source_policy" => "all_connected_bounded",
      "reviewed_goals" => Enum.map(goals, &Goals.serialize_goal/1),
      "goal_context" => Goals.context_snapshot(user_id, limit: state.max_goals_per_cycle),
      "open_loops" => OpenLoops.snapshot(user_id, limit: 10, include_memory?: false),
      "open_work" => Todos.summarize_for_prompt(user_id, 20),
      "people" => Crm.summarize_for_prompt(user_id, 20),
      "source_summary" => source_summary,
      "connected_sources" => compact_source_bundle(source_bundle)
    }
  end

  defp llm_params(payload, state) do
    %{
      "messages" => [
        %{
          "role" => "user",
          "content" => goal_alignment_prompt(payload)
        }
      ],
      "max_tokens" => state.llm_max_tokens,
      "temperature" => 0.1,
      "reasoning_effort" => state.llm_reasoning_effort
    }
  end

  defp goal_alignment_prompt(payload) do
    """
    You are Maraithon's proactive Chief of Staff goal-alignment loop.

    Review the user's due goals against all connected context in the payload: open work, People, Gmail, Google Calendar, Slack, local calendar, iMessage, Notes, Reminders, files, browser history, and voice memos. Missing or stale sources are source-health facts, not failures.

    Create outputs only when they are high quality:
    - Advice must be specific, grounded in connected context, and useful for the goal.
    - Todo candidates must have a concrete next action, clear source-backed reason, and evidence.redacted_summary.
    - Do not create motivational, vague, duplicate, or "try harder" todos.
    - For health, fitness, person, and life goals, preserve privacy. Use summaries, not sensitive raw excerpts.
    - Never propose external sends, calendar changes, or third-party mutations. Only propose Maraithon todos, progress, links, findings, and advice.
    - Every progress update, finding, advice item, and todo candidate must include goal_id.
    - Use source_refs like "gmail:<thread_id>", "calendar:<event_id>", "slack:<channel_id>:<ts>", "imessage:<guid>", "notes:<note_id>", "reminders:<reminder_id>", "files:<file_id>", "browser_history:<visit_id>", or "open_work:<todo_id>" when possible.

    Return ONLY valid JSON with this exact shape:
    {
      "reviewed_goal_ids": ["goal id"],
      "findings": [
        {"goal_id":"...", "kind":"supports|blocks|drift|opportunity|source_gap", "summary":"grounded finding", "source_refs":["..."], "confidence":0.0}
      ],
      "advice": [
        {"goal_id":"...", "headline":"short advice headline", "summary":"specific advice", "urgency":"now|soon|later", "source_refs":["..."], "confidence":0.0}
      ],
      "progress_updates": [
        {"goal_id":"...", "summary":"what changed or what the evidence says", "progress_state":"on_track|at_risk|blocked|stale|achieved|unknown", "confidence":0.0, "evidence":{"redacted_summary":"why this is grounded", "source_refs":["..."]}}
      ],
      "resource_links": [
        {"goal_id":"...", "resource_type":"todo|person|insight|brief|chat_thread|memory|source_observation|scheduled_task", "resource_id":"...", "relationship":"supports|blocks|evidence|next_move|progress|context", "confidence":0.0, "metadata":{"reason":"short reason"}}
      ],
      "todo_candidates": [
        {"goal_id":"...", "title":"short action title", "summary":"context-rich reason this advances or protects the goal", "next_action":"specific next move", "priority":0, "attention_mode":"act_now|monitor", "due_at":null, "confidence":0.0, "evidence":{"redacted_summary":"source-backed rationale", "source_refs":["..."]}}
      ]
    }

    Payload JSON:
    #{Jason.encode!(payload)}
    """
  end

  defp source_summary(source_bundle, telemetry) do
    %{
      "freshness" => SourceBundle.freshness(source_bundle),
      "acquisition" => telemetry
    }
  end

  defp compact_source_bundle(source_bundle) do
    %{
      "gmail" => compact_items("gmail", SourceBundle.gmail_messages(source_bundle)),
      "google_calendar" => compact_items("calendar", SourceBundle.calendar_events(source_bundle)),
      "local_calendar" =>
        compact_items("calendar_local", SourceBundle.calendar_local_events(source_bundle)),
      "slack" => compact_items("slack", SourceBundle.slack_messages(source_bundle)),
      "slack_mentions" => compact_items("slack", SourceBundle.slack_mentions(source_bundle)),
      "imessage" => compact_items("imessage", SourceBundle.imessage_messages(source_bundle)),
      "imessage_chats" =>
        compact_items("imessage_chat", SourceBundle.imessage_chats(source_bundle)),
      "notes" => compact_items("notes", SourceBundle.notes(source_bundle)),
      "voice_memos" => compact_items("voice_memos", SourceBundle.voice_memos(source_bundle)),
      "reminders" => compact_items("reminders", SourceBundle.reminders(source_bundle)),
      "files" => compact_items("files", SourceBundle.files(source_bundle)),
      "browser_history" =>
        compact_items("browser_history", SourceBundle.browser_visits(source_bundle)),
      "freshness" => SourceBundle.freshness(source_bundle)
    }
  end

  defp compact_items(source, items) when is_list(items) do
    items
    |> Enum.take(@source_item_limit)
    |> Enum.map(&compact_source_item(source, &1))
  end

  defp compact_items(_source, _items), do: []

  defp compact_source_item(source, item) when is_map(item) do
    string_item = stringify_keys(item)

    string_item
    |> Map.take(~w(
      id guid uid local_id message_id thread_id source_item_id event_id note_id memo_id
      reminder_id file_id visit_id chat_key channel_id channel_name team_id team_name ts
      subject title summary text snippet body_text sender sender_name sender_email from to
      participants start_at end_at due_at occurred_at sent_at created_at updated_at
      modified_at last_visited_at url host path list_name folder_name
    ))
    |> truncate_string_values()
    |> Map.put("source", source)
    |> Map.put("source_ref", source_ref(source, string_item))
  end

  defp compact_source_item(source, value) do
    %{"source" => source, "value" => inspect(value)}
  end

  defp source_ref(source, item) do
    id =
      Enum.find_value(
        ~w(id guid uid local_id message_id thread_id source_item_id event_id note_id memo_id reminder_id file_id visit_id chat_key ts),
        &Map.get(item, &1)
      )

    if is_binary(id) and String.trim(id) != "", do: "#{source}:#{id}", else: source
  end

  defp truncate_string_values(map) do
    Map.new(map, fn
      {key, value} when is_binary(value) -> {key, truncate(value, @text_limit)}
      {key, value} -> {key, value}
    end)
  end

  defp truncate(value, limit) when is_binary(value) and byte_size(value) > limit do
    binary_part(value, 0, limit) <> "..."
  end

  defp truncate(value, _limit), do: value

  defp response_content(%{content: content}) when is_binary(content), do: {:ok, content}
  defp response_content(%{"content" => content}) when is_binary(content), do: {:ok, content}
  defp response_content(content) when is_binary(content), do: {:ok, content}
  defp response_content(_response), do: {:error, :goal_alignment_missing_llm_content}

  defp decode_json_payload(content) do
    trimmed =
      content
      |> String.trim()
      |> String.trim_leading("```json")
      |> String.trim_leading("```")
      |> String.trim_trailing("```")
      |> String.trim()

    case Jason.decode(trimmed) do
      {:ok, %{} = decoded} -> {:ok, decoded}
      _other -> {:error, :goal_alignment_invalid_json}
    end
  end

  defp fail_pending_review(
         %{pending_review_run_id: review_run_id, user_id: user_id} = state,
         reason
       )
       when is_binary(review_run_id) and is_binary(user_id) do
    _ =
      Goals.complete_review_run(user_id, review_run_id, %{
        "status" => "failed",
        "finished_at" => DateTime.utc_now(),
        "error" => %{"reason" => inspect(reason)}
      })

    {:emit,
     {:goal_alignment_failed,
      %{
        user_id: user_id,
        review_run_id: review_run_id,
        reason: inspect(reason)
      }}, clear_pending(state)}
  end

  defp fail_pending_review(state, _reason), do: {:idle, clear_pending(state)}

  defp clear_pending(state) do
    %{
      state
      | pending_review_run_id: nil,
        pending_goal_ids: [],
        pending_started_at: nil,
        pending_source_summary: %{}
    }
  end

  defp reviewed_recently?(%{last_reviewed_at: %DateTime{} = last_reviewed_at} = state, now) do
    DateTime.diff(now, last_reviewed_at, :hour) < state.review_interval_hours
  end

  defp reviewed_recently?(_state, _now), do: false

  defp scheduled_trigger?(context) do
    case get_in(context, [:trigger, :type]) do
      nil -> is_nil(context[:event]) and is_nil(context[:last_message])
      :wakeup -> true
      _other -> false
    end
  end

  defp normalize_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_string(_value), do: nil

  defp integer_in_range(value, default, min, max) do
    case value do
      int when is_integer(int) and int >= min and int <= max ->
        int

      text when is_binary(text) ->
        case Integer.parse(String.trim(text)) do
          {int, ""} when int >= min and int <= max -> int
          _other -> default
        end

      _other ->
        default
    end
  end

  defp normalize_reasoning_effort(value, default) when is_binary(value) do
    value = String.trim(value)
    if value in ["minimal", "low", "medium", "high"], do: value, else: default
  end

  defp normalize_reasoning_effort(_value, default), do: default

  defp stringify_keys(%_{} = struct), do: struct

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), value}
      {key, value} when is_binary(key) -> {key, value}
      {key, value} -> {to_string(key), value}
    end)
  end

  defp stringify_keys(value), do: value
end
