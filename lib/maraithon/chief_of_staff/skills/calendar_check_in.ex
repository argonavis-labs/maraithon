defmodule Maraithon.ChiefOfStaff.Skills.CalendarCheckIn do
  @moduledoc """
  Proactive calendar check-in skill for the AI Chief of Staff.

  A few times during the work day this skill looks for genuine openings in
  the operator's calendar and, when there is something useful to say, sends a short
  proactive check-in over Telegram — pointing at the opening and one or two
  concrete things they could tee up (a todo, prep for an upcoming meeting, a
  reply they owe).

  Opening detection is deterministic interval math over the day's timed
  events; the *decision to interrupt* and the wording are model-backed, so a
  fragmented or low-value opening is held rather than turned into noise.
  """

  @behaviour Maraithon.ChiefOfStaff.Skill

  alias Maraithon.Briefs
  alias Maraithon.ChiefOfStaff.SourceBundle
  alias Maraithon.Todos
  alias Maraithon.Tracing

  require Logger

  @default_timezone_offset_hours -5
  @default_work_day_start_hour 9
  @default_work_day_end_hour 18
  @default_check_in_interval_hours 3
  @default_min_opening_minutes 45
  @default_llm_max_tokens 2_000
  @default_llm_reasoning_effort "low"

  @impl true
  def id, do: "calendar_check_in"

  @impl true
  def label, do: "Calendar check-in"

  @impl true
  def description do
    "Looks for openings in the work day and proactively checks in to see if the operator needs anything."
  end

  @impl true
  def default_config do
    %{
      "assistant_behavior" => "ai_chief_of_staff",
      "timezone_offset_hours" => @default_timezone_offset_hours,
      "work_day_start_hour" => @default_work_day_start_hour,
      "work_day_end_hour" => @default_work_day_end_hour,
      "check_in_interval_hours" => @default_check_in_interval_hours,
      "min_opening_minutes" => @default_min_opening_minutes,
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
        service: "calendar",
        label: "Google Calendar",
        description: "Used to find openings in the work day. Local calendar also works.",
        required?: false
      },
      %{
        kind: :provider,
        provider: "telegram",
        label: "Telegram",
        description: "Needed to deliver the proactive check-in.",
        required?: false
      }
    ]
  end

  @impl true
  def subscriptions(_config, _user_id), do: []

  @impl true
  def interested_in?(_config, context) do
    # Purely scheduled — never reacts to inbound messages or pubsub events.
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
      work_day_start_hour:
        integer_in_range(config["work_day_start_hour"], @default_work_day_start_hour, 0, 23),
      work_day_end_hour:
        integer_in_range(config["work_day_end_hour"], @default_work_day_end_hour, 1, 24),
      check_in_interval_hours:
        integer_in_range(
          config["check_in_interval_hours"],
          @default_check_in_interval_hours,
          1,
          12
        ),
      min_opening_minutes:
        integer_in_range(config["min_opening_minutes"], @default_min_opening_minutes, 15, 240),
      llm_model: normalize_string(config["llm_model"]),
      llm_max_tokens:
        integer_in_range(config["llm_max_tokens"], @default_llm_max_tokens, 256, 8_000),
      llm_reasoning_effort:
        normalize_reasoning_effort(config["llm_reasoning_effort"], @default_llm_reasoning_effort),
      pending_check_in_input: nil,
      pending_dedupe_key: nil,
      last_check_in_at: nil
    }
  end

  @impl true
  def handle_wakeup(state, context) do
    user_id = state.user_id || normalize_string(context[:user_id])
    now = context[:timestamp] || DateTime.utc_now()

    cond do
      is_nil(user_id) ->
        {:idle, state}

      not scheduled_trigger?(context) ->
        {:idle, %{state | user_id: user_id}}

      not within_work_day?(now, state) ->
        {:idle, %{state | user_id: user_id}}

      checked_in_recently?(state, now) ->
        {:idle, %{state | user_id: user_id}}

      true ->
        check_in_input = build_check_in_input(user_id, now, state, context)

        if check_in_input["openings"] == [] do
          # The work day is fully booked — nothing to check in about, and no
          # reason to spend a model call deciding that.
          {:idle, %{state | user_id: user_id}}
        else
          pending_state = %{
            state
            | user_id: user_id,
              pending_check_in_input: check_in_input,
              pending_dedupe_key: "calendar_check_in:#{check_in_input["window_key"]}"
          }

          case llm_params(check_in_input, state) do
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
  end

  @impl true
  def handle_effect_result({:llm_call, response}, state, context) do
    Tracing.with_span(
      "chief_of_staff.calendar_check_in",
      %{skill: "calendar_check_in", user_id: context[:user_id] || state.user_id},
      fn -> deliver_check_in(response, state, context) end
    )
  end

  def handle_effect_result(_effect_result, state, _context), do: {:idle, state}

  @impl true
  def handle_effect_error(:llm_call, reason, state, context) do
    handle_effect_result(
      {:llm_call, %{content: "", error: inspect(reason), finish_reason: "error"}},
      state,
      context
    )
  end

  def handle_effect_error(_effect_type, _reason, state, _context), do: {:idle, state}

  @impl true
  def next_wakeup(state) do
    {:relative, state.check_in_interval_hours * 60 * 60 * 1000}
  end

  # ==========================================================================
  # Check-in input
  # ==========================================================================

  @doc false
  def build_check_in_input(user_id, now, state, context) do
    offset = state.timezone_offset_hours
    local_now = DateTime.add(now, offset, :hour)
    local_date = DateTime.to_date(local_now)

    events =
      context
      |> Map.get(:source_bundle, %{})
      |> Kernel.||(%{})
      |> SourceBundle.calendar_events()
      |> List.wrap()

    openings = compute_openings(events, now, state)

    %{
      "date" => Date.to_iso8601(local_date),
      "generated_at" => DateTime.to_iso8601(now),
      "local_time" =>
        local_now |> DateTime.to_time() |> Time.truncate(:second) |> Time.to_iso8601(),
      "timezone_offset_hours" => offset,
      "window_key" => "#{Date.to_iso8601(local_date)}:#{local_now.hour}",
      "work_day" => %{
        "start_hour" => state.work_day_start_hour,
        "end_hour" => state.work_day_end_hour
      },
      "openings" => openings,
      "todays_events" =>
        events
        |> Enum.map(&calendar_event_for_prompt(&1, offset))
        |> Enum.reject(&is_nil/1)
        |> Enum.take(20),
      "open_work" => %{
        "todos" =>
          user_id
          |> Todos.list_open_for_user(limit: 25)
          |> Enum.map(&Todos.serialize_for_prompt/1)
      },
      "last_check_in_at" => state.last_check_in_at
    }
  end

  # Deterministic interval math: free stretches >= min_opening_minutes between
  # now (or the work-day start) and the work-day end, ignoring all-day events.
  defp compute_openings(events, now, state) do
    offset = state.timezone_offset_hours
    local_now = DateTime.add(now, offset, :hour)
    local_date = DateTime.to_date(local_now)

    work_start_utc =
      local_date
      |> DateTime.new!(Time.new!(state.work_day_start_hour, 0, 0), "Etc/UTC")
      |> DateTime.add(-offset, :hour)

    work_end_utc =
      local_date
      |> work_day_end_datetime(state.work_day_end_hour)
      |> DateTime.add(-offset, :hour)

    window_start = latest(now, work_start_utc)
    window_end = work_end_utc

    if DateTime.compare(window_start, window_end) != :lt do
      []
    else
      busy =
        events
        |> Enum.map(&event_interval/1)
        |> Enum.reject(&is_nil/1)
        |> Enum.filter(fn {s, e} ->
          DateTime.compare(e, window_start) == :gt and DateTime.compare(s, window_end) == :lt
        end)
        |> Enum.sort_by(fn {s, _e} -> DateTime.to_unix(s, :microsecond) end)

      {openings, cursor} =
        Enum.reduce(busy, {[], window_start}, fn {s, e}, {acc, cursor} ->
          gap_end = earliest(s, window_end)
          acc = maybe_add_opening(acc, cursor, gap_end, offset, state.min_opening_minutes)
          {acc, latest(e, cursor)}
        end)

      openings
      |> maybe_add_opening(cursor, window_end, offset, state.min_opening_minutes)
      |> Enum.reverse()
    end
  end

  defp work_day_end_datetime(date, 24), do: DateTime.new!(date, ~T[23:59:59], "Etc/UTC")

  defp work_day_end_datetime(date, hour),
    do: DateTime.new!(date, Time.new!(hour, 0, 0), "Etc/UTC")

  defp maybe_add_opening(acc, gap_start, gap_end, offset, min_minutes) do
    minutes = gap_end |> DateTime.diff(gap_start, :second) |> div(60)

    if minutes >= min_minutes do
      [
        %{
          "start" => DateTime.to_iso8601(gap_start),
          "end" => DateTime.to_iso8601(gap_end),
          "local_start" => local_clock(gap_start, offset),
          "local_end" => local_clock(gap_end, offset),
          "minutes" => minutes
        }
        | acc
      ]
    else
      acc
    end
  end

  defp event_interval(event) when is_map(event) do
    with %DateTime{} = start_at <- coerce_datetime(read_any(event, "start")),
         %DateTime{} = end_at <- coerce_datetime(read_any(event, "end")),
         :lt <- DateTime.compare(start_at, end_at) do
      {start_at, end_at}
    else
      _ -> nil
    end
  end

  defp event_interval(_event), do: nil

  # All-day events arrive as %{"date" => "..."} and do not block timed work.
  defp coerce_datetime(%DateTime{} = value), do: value

  defp coerce_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      _ -> nil
    end
  end

  defp coerce_datetime(_value), do: nil

  defp latest(a, b), do: if(DateTime.compare(a, b) == :gt, do: a, else: b)
  defp earliest(a, b), do: if(DateTime.compare(a, b) == :lt, do: a, else: b)

  defp local_clock(%DateTime{} = datetime, offset) do
    datetime
    |> DateTime.add(offset, :hour)
    |> DateTime.to_time()
    |> Time.truncate(:second)
    |> Time.to_iso8601()
  end

  defp calendar_event_for_prompt(event, offset) when is_map(event) do
    case event_interval(event) do
      {start_at, end_at} ->
        %{
          "summary" => read_string(event, "summary", "Untitled event"),
          "local_start" => local_clock(start_at, offset),
          "local_end" => local_clock(end_at, offset),
          "location" => read_string(event, "location", nil),
          "organizer" => read_string(event, "organizer", nil)
        }

      nil ->
        nil
    end
  end

  defp calendar_event_for_prompt(_event, _offset), do: nil

  # ==========================================================================
  # Model call + delivery
  # ==========================================================================

  defp llm_params(check_in_input, state) do
    with {:ok, input_json} <- Jason.encode(check_in_input) do
      params =
        %{
          "messages" => [%{"role" => "user", "content" => check_in_prompt(input_json)}],
          "max_tokens" => state.llm_max_tokens,
          "temperature" => 0.3,
          "reasoning_effort" => state.llm_reasoning_effort
        }
        |> maybe_put("model", state.llm_model)

      {:ok, params}
    end
  end

  defp check_in_prompt(input_json) do
    """
    You are the operator's chief of staff, deciding whether to send a short proactive
    check-in over Telegram right now.

    It is a work day and the operator has one or more openings in the calendar (see the
    input JSON). Send a check-in only when it would genuinely help: point at a
    real opening and, when possible, one or two concrete things the operator could use the
    time for — a specific open todo, prep for an upcoming meeting, or a reply he
    owes. Hold when the openings are short or fragmented, when there is nothing
    useful to suggest, or when a message would just be noise. A "hold" is a
    perfectly good, common outcome — do not invent work to justify a send.

    Voice: warm, specific, and brief, like a trusted operator — not a system
    notification. Use the local clock times from the input. Plain Telegram text,
    no markdown tables, no internal labels.

    Return ONLY valid JSON with this exact shape:
    {
      "decision": "send" | "hold",
      "title": "short title, e.g. 'Open afternoon'",
      "summary": "one-line summary of the check-in",
      "body": "the Telegram-ready check-in text, or an empty string when holding",
      "reason": "short reasoning for the decision"
    }

    Check-in input JSON:
    #{input_json}
    """
  end

  defp deliver_check_in(response, state, context) do
    user_id = context[:user_id] || state.user_id
    now = DateTime.utc_now()
    cleared = %{state | pending_check_in_input: nil, pending_dedupe_key: nil}

    case parse_response(response) do
      {:ok, %{"decision" => "send"} = check_in} ->
        record_and_emit(check_in, cleared, state, user_id, context, now)

      {:ok, _hold} ->
        # The model chose not to interrupt — a valid, expected outcome.
        {:idle, cleared}

      {:error, reason} ->
        # A proactive check-in failing should be silent to the operator (no error
        # brief) but visible to us in Logfire.
        _ = Tracing.record_error("calendar_check_in: " <> String.slice(reason, 0, 200))
        Logger.warning("Calendar check-in model synthesis failed", reason: reason)
        {:idle, cleared}
    end
  end

  defp record_and_emit(check_in, cleared_state, state, user_id, context, now) do
    check_in_input = state.pending_check_in_input || %{}
    check_in = user_facing_check_in(check_in, check_in_input)

    attrs = %{
      "cadence" => "check_in",
      "scheduled_for" => DateTime.to_iso8601(now),
      "dedupe_key" => state.pending_dedupe_key || "calendar_check_in:#{DateTime.to_iso8601(now)}",
      "status" => "pending",
      "title" => check_in["title"],
      "summary" => check_in["summary"],
      "body" => check_in["body"],
      "metadata" => %{
        "origin_skill_id" => id(),
        "generation_mode" => "llm",
        "openings" => Map.get(check_in_input, "openings", []),
        "reason" => read_string(check_in, "reason", nil)
      }
    }

    case Briefs.record(user_id, context[:agent_id], attrs) do
      {:ok, brief_record} ->
        {:emit,
         {:briefs_recorded,
          %{
            count: 1,
            generation_mode: "llm",
            user_id: user_id,
            cadences: ["check_in"],
            source_backed: true,
            brief_id: brief_record.id
          }}, %{cleared_state | last_check_in_at: DateTime.to_iso8601(now)}}

      {:error, _reason} ->
        {:idle, cleared_state}
    end
  end

  defp user_facing_check_in(check_in, check_in_input) when is_map(check_in) do
    body = safe_check_in_body(read_string(check_in, "body", nil), check_in_input)

    %{
      "title" => safe_check_in_title(read_string(check_in, "title", nil), check_in_input),
      "summary" =>
        safe_check_in_summary(read_string(check_in, "summary", nil), check_in_input, body),
      "body" => body,
      "reason" => read_string(check_in, "reason", nil)
    }
  end

  defp user_facing_check_in(_check_in, check_in_input) do
    %{
      "title" => fallback_check_in_title(check_in_input),
      "summary" => fallback_check_in_summary(check_in_input),
      "body" => fallback_check_in_body(check_in_input),
      "reason" => nil
    }
  end

  defp safe_check_in_title(value, check_in_input) do
    first_safe_user_line(value) || fallback_check_in_title(check_in_input)
  end

  defp safe_check_in_summary(value, check_in_input, body) do
    first_safe_user_line(value) ||
      summary_from_check_in_body(body) ||
      fallback_check_in_summary(check_in_input)
  end

  defp safe_check_in_body(value, check_in_input) do
    lines =
      value
      |> raw_user_lines()
      |> Enum.map(&strip_check_in_label/1)
      |> Enum.map(&safe_user_line/1)
      |> Enum.reject(&is_nil/1)

    case lines do
      [] -> fallback_check_in_body(check_in_input)
      lines -> Enum.join(lines, "\n\n")
    end
  end

  defp first_safe_user_line(value) do
    value
    |> raw_user_lines()
    |> Enum.map(&strip_check_in_label/1)
    |> Enum.find_value(&safe_user_line/1)
  end

  defp summary_from_check_in_body(body) do
    best_use =
      case Regex.run(
             ~r/(?:^|[.!?]\s+)(?:best use|recommended use|suggested use)\s*:\s*([^\n]+)/iu,
             body || ""
           ) do
        [_match, move] -> safe_user_line(move)
        _ -> nil
      end

    (best_use || first_safe_user_line(body))
    |> case do
      nil ->
        nil

      line ->
        line =
          String.replace(
            line,
            ~r/^\s*(?:best use|recommended use|suggested use)\s*:\s*/iu,
            ""
          )

        "Best use: #{sentence(line)}"
    end
  end

  defp raw_user_lines(value) do
    value
    |> normalize_string()
    |> case do
      nil -> []
      text -> String.split(text, ~r/\n+/u, trim: true)
    end
  end

  defp strip_check_in_label(line) do
    String.replace(
      line,
      ~r/^\s*(?:action|next|suggested next step|body|message|summary)\s*:\s*/iu,
      ""
    )
  end

  defp safe_user_line(value) do
    value
    |> normalize_string()
    |> case do
      nil ->
        nil

      text ->
        text = String.trim_trailing(text, ".")

        if internal_process_line?(text) do
          nil
        else
          text
        end
    end
  end

  defp internal_process_line?(line) do
    normalized = String.downcase(line)

    Regex.match?(~r/\b\d{1,3}%/u, normalized) or
      Enum.any?(
        [
          "confidence",
          "score",
          "threshold",
          "model",
          "json",
          "heuristic",
          "classified",
          "llm",
          "reasoning"
        ],
        &String.contains?(normalized, &1)
      )
  end

  defp fallback_check_in_title(check_in_input) do
    case opening_range_label(check_in_input) do
      nil -> "Calendar opening"
      range -> "Open time: #{range}"
    end
  end

  defp fallback_check_in_summary(check_in_input) do
    case primary_todo_move(check_in_input) do
      nil -> "Use the opening for the most important reply or meeting prep."
      move -> "Best use: #{sentence(move)}"
    end
  end

  defp fallback_check_in_body(check_in_input) do
    opening =
      case opening_range_label(check_in_input) do
        nil -> "You have usable open time on the calendar."
        range -> "You have #{range} open."
      end

    next_move =
      case primary_todo_move(check_in_input) do
        nil -> "Use it to clear the most important reply or prep the next meeting."
        move -> "Best use: #{sentence(move)}"
      end

    "#{opening} #{next_move}"
  end

  defp opening_range_label(check_in_input) do
    check_in_input
    |> read_list("openings")
    |> List.first()
    |> case do
      opening when is_map(opening) ->
        start_at = opening |> read_string("local_start", nil) |> clock_label()
        end_at = opening |> read_string("local_end", nil) |> clock_label()

        if start_at && end_at do
          "#{start_at}-#{end_at}"
        end

      _ ->
        nil
    end
  end

  defp primary_todo_move(check_in_input) do
    check_in_input
    |> primary_todo()
    |> case do
      todo when is_map(todo) ->
        read_string(todo, "next_action", nil) ||
          read_string(todo, "summary", nil) ||
          read_string(todo, "title", nil)

      _ ->
        nil
    end
  end

  defp primary_todo(check_in_input) do
    check_in_input
    |> read_map("open_work")
    |> read_list("todos")
    |> List.first()
  end

  defp sentence(value) when is_binary(value) do
    value = String.trim(value)

    if String.ends_with?(value, [".", "!", "?"]) do
      value
    else
      value <> "."
    end
  end

  defp sentence(_value), do: ""

  defp clock_label(nil), do: nil

  defp clock_label(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.split(":")
    |> case do
      [hour, minute | _] -> "#{hour}:#{minute}"
      _ -> nil
    end
  end

  defp clock_label(_value), do: nil

  defp parse_response(response) do
    error =
      case response do
        %{error: error} -> error
        %{"error" => error} -> error
        _ -> nil
      end

    content =
      case response do
        %{content: content} when is_binary(content) -> content
        %{"content" => content} when is_binary(content) -> content
        content when is_binary(content) -> content
        _ -> nil
      end

    cond do
      error ->
        {:error, to_string(error)}

      is_binary(content) and content != "" ->
        case decode_json(content) do
          {:ok, %{"decision" => decision} = data} when decision in ["send", "hold"] ->
            {:ok, data}

          {:ok, %{}} ->
            {:error, "model_response_missing_or_invalid_decision"}

          _ ->
            {:error, "model_response_invalid_json"}
        end

      true ->
        {:error, "model_response_empty"}
    end
  end

  # ==========================================================================
  # Gating helpers
  # ==========================================================================

  defp scheduled_trigger?(context) do
    case get_in(context, [:trigger, :type]) do
      nil -> is_nil(context[:event]) and is_nil(context[:last_message])
      :wakeup -> true
      _ -> false
    end
  end

  defp within_work_day?(now, state) do
    local = DateTime.add(now, state.timezone_offset_hours, :hour)
    weekday? = Date.day_of_week(DateTime.to_date(local)) in 1..5

    weekday? and local.hour >= state.work_day_start_hour and
      local.hour < state.work_day_end_hour
  end

  defp checked_in_recently?(%{last_check_in_at: nil}, _now), do: false

  defp checked_in_recently?(%{last_check_in_at: iso} = state, now) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, last, _offset} ->
        DateTime.diff(now, last, :second) < state.check_in_interval_hours * 3600

      _ ->
        false
    end
  end

  defp checked_in_recently?(_state, _now), do: false

  # ==========================================================================
  # Small utilities
  # ==========================================================================

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
    |> Enum.map(&normalize_string/1)
    |> Enum.reject(&is_nil/1)
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

  defp read_any(map, key) when is_map(map) do
    Map.get(map, key, Map.get(map, safe_existing_atom(key)))
  end

  defp read_any(_map, _key), do: nil

  defp read_string(map, key, default) when is_map(map) do
    case read_any(map, key) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> default
          trimmed -> trimmed
        end

      nil ->
        default

      value ->
        to_string(value)
    end
  end

  defp read_string(_map, _key, default), do: default

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

  defp safe_existing_atom(key) when is_binary(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> nil
  end

  defp safe_existing_atom(key), do: key

  defp normalize_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_string(_value), do: nil

  defp normalize_reasoning_effort(value, default) when is_binary(value) do
    normalized = value |> String.trim() |> String.downcase()
    if normalized in ~w(low medium high xhigh), do: normalized, else: default
  end

  defp normalize_reasoning_effort(_value, default), do: default

  defp integer_in_range(value, default, min, max) do
    parsed =
      cond do
        is_integer(value) -> value
        is_binary(value) -> parse_integer(value, default)
        true -> default
      end

    parsed |> max(min) |> min(max)
  end

  defp parse_integer(value, default) do
    case Integer.parse(String.trim(value)) do
      {parsed, ""} -> parsed
      _ -> default
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, ""), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
