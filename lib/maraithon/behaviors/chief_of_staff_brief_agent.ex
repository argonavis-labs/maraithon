defmodule Maraithon.Behaviors.ChiefOfStaffBriefAgent do
  @moduledoc """
  Generates recurring chief-of-staff briefs from the current insight stream.

  It does not rescan connectors directly. Instead, it turns the user's existing
  Gmail, Calendar, and Slack insights into morning briefs, end-of-day debt
  rollups, and weekly reviews for Telegram delivery.
  """

  @behaviour Maraithon.Behaviors.Behavior

  alias Maraithon.Briefs
  alias Maraithon.ChiefOfStaff.AttentionArbiter
  alias Maraithon.Insights
  alias Maraithon.Insights.Detail
  alias Maraithon.Todos

  @default_timezone_offset_hours -5
  @default_morning_hour 8
  @default_end_of_day_hour 18
  @default_weekly_day 5
  @default_weekly_hour 16
  @default_max_items 3
  @default_check_in_slots_per_day 3
  @default_check_in_max_items 2

  @impl true
  def init(config) do
    %{
      user_id: normalize_string(config["user_id"]),
      assistant_behavior:
        normalize_string(config["assistant_behavior"]) || "founder_followthrough_agent",
      timezone_offset_hours:
        integer_in_range(config["timezone_offset_hours"], @default_timezone_offset_hours, -12, 14),
      morning_hour:
        integer_in_range(config["morning_brief_hour_local"], @default_morning_hour, 0, 23),
      end_of_day_hour:
        integer_in_range(config["end_of_day_brief_hour_local"], @default_end_of_day_hour, 0, 23),
      weekly_day: integer_in_range(config["weekly_review_day_local"], @default_weekly_day, 1, 7),
      weekly_hour:
        integer_in_range(config["weekly_review_hour_local"], @default_weekly_hour, 0, 23),
      max_items: integer_in_range(config["brief_max_items"], @default_max_items, 1, 5),
      adaptive_check_ins_enabled: boolean_value(config["adaptive_check_ins_enabled"], true),
      check_in_slots_per_day:
        integer_in_range(
          config["adaptive_check_in_slots_per_day"],
          @default_check_in_slots_per_day,
          1,
          4
        ),
      check_in_max_items:
        integer_in_range(
          config["adaptive_check_in_max_items"],
          @default_check_in_max_items,
          1,
          3
        ),
      last_generated_keys: %{}
    }
  end

  @impl true
  def handle_wakeup(state, context) do
    user_id = state.user_id || normalize_string(context[:user_id])
    now = context.timestamp || DateTime.utc_now()

    due =
      state
      |> due_cadences(now)
      |> Enum.reject(fn %{cadence: cadence, period_key: period_key} ->
        generated_period?(state, cadence, period_key)
      end)

    if due == [] or is_nil(user_id) do
      {:idle, %{state | user_id: user_id}}
    else
      case build_briefs(user_id, context.agent_id, state, due, now, context) do
        {:ok, []} ->
          {:idle,
           %{state | user_id: user_id, last_generated_keys: update_generated_keys(state, due)}}

        {:ok, briefs} ->
          {:emit,
           {:briefs_recorded,
            %{
              count: length(briefs),
              user_id: user_id,
              cadences: Enum.map(briefs, & &1.cadence)
            }},
           %{state | user_id: user_id, last_generated_keys: update_generated_keys(state, due)}}
      end
    end
  end

  @impl true
  def handle_effect_result(_effect_result, state, _context), do: {:idle, state}

  @impl true
  def next_wakeup(state) do
    now = DateTime.utc_now()

    [
      next_occurrence("morning", state, now),
      next_occurrence("check_in", state, now),
      next_occurrence("end_of_day", state, now),
      next_occurrence("weekly_review", state, now)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.min_by(&DateTime.to_unix(&1, :second), fn ->
      DateTime.add(now, :timer.hours(12), :millisecond)
    end)
    |> then(&{:absolute, &1})
  end

  defp build_briefs(user_id, agent_id, state, due, now, context) do
    act_now_insights = Insights.list_open_act_now_for_user(user_id, limit: 30)
    monitor_insights = Insights.list_open_monitor_for_user(user_id, limit: 30)
    recent_insights = Insights.list_recent_for_user(user_id, limit: 60)

    due
    |> Enum.map(
      &build_brief_attrs(
        &1,
        state,
        act_now_insights,
        monitor_insights,
        recent_insights,
        now,
        context
      )
    )
    |> Enum.reject(&is_nil/1)
    |> then(&Briefs.record_many(user_id, agent_id, &1))
  end

  defp build_brief_attrs(
         %{cadence: "morning"} = plan,
         state,
         act_now_insights,
         monitor_insights,
         _recent_insights,
         now,
         context
       ) do
    due_today = Enum.filter(act_now_insights, &due_today?(&1, state.timezone_offset_hours, now))

    top_items =
      select_brief_items(
        act_now_insights,
        now,
        state.timezone_offset_hours,
        state.max_items,
        cadence: "morning"
      )

    watching_items =
      monitor_insights
      |> recent_monitor_items(now)
      |> select_brief_items(
        now,
        state.timezone_offset_hours,
        state.max_items,
        cadence: "monitor"
      )

    {title, summary} =
      cond do
        top_items == [] and watching_items == [] ->
          {"Morning brief: clean slate",
           "No urgent open items are surfacing right now across Gmail, Calendar, or Slack."}

        top_items == [] ->
          {"Morning brief: clear action list",
           "#{length(watching_items)} important threads are being watched, with no direct actions due right now."}

        true ->
          count = length(top_items)

          {"Morning brief: #{count} items worth watching",
           morning_summary(
             top_items,
             due_today,
             act_now_insights,
             monitor_insights,
             state.timezone_offset_hours,
             now
           )}
      end

    delivery_insights = card_insights(top_items ++ watching_items)

    %{
      "cadence" => "morning",
      "scheduled_for" => plan.scheduled_for,
      "dedupe_key" => dedupe_key("morning", plan.period_key),
      "title" => title,
      "summary" => summary,
      "body" =>
        morning_body(
          top_items,
          watching_items,
          act_now_insights,
          monitor_insights,
          state.timezone_offset_hours,
          now
        ),
      "metadata" =>
        metadata_for(
          plan,
          state.assistant_behavior,
          delivery_insights,
          context
        )
        |> Map.merge(brief_delivery_metadata(delivery_insights, state.timezone_offset_hours))
    }
  end

  defp build_brief_attrs(
         %{cadence: "end_of_day"} = plan,
         state,
         act_now_insights,
         monitor_insights,
         _recent_insights,
         _now,
         context
       ) do
    debt_candidates =
      act_now_insights
      |> Enum.filter(
        &(due_today?(&1, state.timezone_offset_hours, plan.scheduled_for) or
            overdue?(&1, state.timezone_offset_hours, plan.scheduled_for))
      )

    debt_items =
      select_brief_items(
        debt_candidates,
        plan.scheduled_for,
        state.timezone_offset_hours,
        state.max_items,
        cadence: "end_of_day"
      )

    watching_items =
      monitor_insights
      |> recent_monitor_items(plan.scheduled_for)
      |> select_brief_items(
        plan.scheduled_for,
        state.timezone_offset_hours,
        state.max_items,
        cadence: "monitor"
      )

    {title, summary} =
      cond do
        debt_items == [] and watching_items == [] ->
          {"End-of-day debt: all clear",
           "Nothing high-confidence still looks open at the end of the day."}

        debt_items == [] ->
          {"End-of-day debt: action list clear",
           "#{length(watching_items)} important threads are still being watched, with no direct founder debt tonight."}

        true ->
          count = length(debt_items)

          {"End-of-day debt: #{count} items still open",
           end_of_day_summary(
             debt_items,
             debt_candidates,
             monitor_insights,
             state.timezone_offset_hours,
             plan.scheduled_for
           )}
      end

    delivery_insights = card_insights(debt_items ++ watching_items)

    %{
      "cadence" => "end_of_day",
      "scheduled_for" => plan.scheduled_for,
      "dedupe_key" => dedupe_key("end_of_day", plan.period_key),
      "title" => title,
      "summary" => summary,
      "body" =>
        end_of_day_body(
          debt_items,
          watching_items,
          act_now_insights,
          monitor_insights,
          state.timezone_offset_hours,
          plan.scheduled_for
        ),
      "metadata" =>
        metadata_for(
          plan,
          state.assistant_behavior,
          delivery_insights,
          context
        )
        |> Map.merge(brief_delivery_metadata(delivery_insights, state.timezone_offset_hours))
    }
  end

  defp build_brief_attrs(
         %{cadence: "check_in"} = plan,
         state,
         act_now_insights,
         _monitor_insights,
         _recent_insights,
         _now,
         context
       ) do
    top_items =
      select_brief_items(
        act_now_insights,
        plan.scheduled_for,
        state.timezone_offset_hours,
        state.check_in_max_items,
        cadence: "check_in"
      )

    if should_send_check_in?(top_items, state.timezone_offset_hours, plan.scheduled_for) do
      count = length(top_items)

      check_in_metadata =
        brief_delivery_metadata(card_insights(top_items), state.timezone_offset_hours)

      %{
        "cadence" => "check_in",
        "scheduled_for" => plan.scheduled_for,
        "dedupe_key" => dedupe_key("check_in", plan.period_key),
        "title" =>
          "Check-in: #{count} item#{if(count == 1, do: "", else: "s")} still need movement",
        "summary" =>
          check_in_summary(
            top_items,
            act_now_insights,
            state.timezone_offset_hours,
            plan.scheduled_for
          ),
        "body" =>
          check_in_body(
            top_items,
            act_now_insights,
            state.timezone_offset_hours,
            plan.scheduled_for
          ),
        "metadata" =>
          metadata_for(plan, state.assistant_behavior, card_insights(top_items), context)
          |> Map.merge(check_in_metadata)
      }
    end
  end

  defp build_brief_attrs(
         %{cadence: "weekly_review"} = plan,
         state,
         act_now_insights,
         monitor_insights,
         recent_insights,
         _now,
         context
       ) do
    week_cutoff = DateTime.add(plan.scheduled_for, -7, :day)

    weekly_items =
      recent_insights
      |> Enum.filter(fn insight ->
        DateTime.compare(insight.inserted_at, week_cutoff) in [:eq, :gt]
      end)

    top_open =
      select_brief_items(
        act_now_insights ++ monitor_insights,
        plan.scheduled_for,
        state.timezone_offset_hours,
        state.max_items,
        cadence: "weekly_review"
      )

    open_count = Enum.count(act_now_insights) + Enum.count(monitor_insights)
    closed_count = Enum.count(weekly_items, &(&1.status in ["acknowledged", "dismissed"]))

    %{
      "cadence" => "weekly_review",
      "scheduled_for" => plan.scheduled_for,
      "dedupe_key" => dedupe_key("weekly_review", plan.period_key),
      "title" => "Weekly review: #{open_count} items still open",
      "summary" =>
        "#{length(weekly_items)} items surfaced this week, #{closed_count} were resolved or triaged, and #{open_count} remain open.",
      "body" =>
        weekly_body(top_open, weekly_items, state.timezone_offset_hours, plan.scheduled_for),
      "metadata" => metadata_for(plan, state.assistant_behavior, weekly_items, context)
    }
  end

  defp due_cadences(state, now) do
    local_now = shift_local(now, state.timezone_offset_hours)

    due =
      [
        due_plan("morning", state, now, local_now),
        due_plan("check_in", state, now, local_now),
        due_plan("end_of_day", state, now, local_now),
        due_plan("weekly_review", state, now, local_now)
      ]
      |> Enum.reject(&is_nil/1)

    if Enum.any?(due, fn %{cadence: cadence, period_key: period_key} ->
         cadence in ["morning", "end_of_day", "weekly_review"] and
           not generated_period?(state, cadence, period_key)
       end) do
      Enum.reject(due, &(&1.cadence == "check_in"))
    else
      due
    end
  end

  defp due_plan("morning", state, utc_now, local_now) do
    scheduled_local = local_datetime(DateTime.to_date(local_now), state.morning_hour)
    scheduled_utc = shift_utc(scheduled_local, state.timezone_offset_hours)

    if DateTime.compare(utc_now, scheduled_utc) != :lt do
      %{
        cadence: "morning",
        period_key: Date.to_iso8601(DateTime.to_date(local_now)),
        scheduled_for: scheduled_utc
      }
    end
  end

  defp due_plan("end_of_day", state, utc_now, local_now) do
    scheduled_local = local_datetime(DateTime.to_date(local_now), state.end_of_day_hour)
    scheduled_utc = shift_utc(scheduled_local, state.timezone_offset_hours)

    if DateTime.compare(utc_now, scheduled_utc) != :lt do
      %{
        cadence: "end_of_day",
        period_key: Date.to_iso8601(DateTime.to_date(local_now)),
        scheduled_for: scheduled_utc
      }
    end
  end

  defp due_plan("check_in", state, utc_now, local_now) do
    if state.adaptive_check_ins_enabled do
      local_now
      |> DateTime.to_date()
      |> check_in_candidates(state)
      |> Enum.filter(&(DateTime.compare(utc_now, &1.scheduled_for) != :lt))
      |> Enum.max_by(&DateTime.to_unix(&1.scheduled_for, :second), fn -> nil end)
    end
  end

  defp due_plan("weekly_review", state, utc_now, local_now) do
    local_date = DateTime.to_date(local_now)

    if Date.day_of_week(local_date) == state.weekly_day do
      scheduled_local = local_datetime(local_date, state.weekly_hour)
      scheduled_utc = shift_utc(scheduled_local, state.timezone_offset_hours)

      if DateTime.compare(utc_now, scheduled_utc) != :lt do
        %{
          cadence: "weekly_review",
          period_key: "#{Date.to_iso8601(local_date)}:#{state.weekly_day}",
          scheduled_for: scheduled_utc
        }
      end
    end
  end

  defp next_occurrence("morning", state, now) do
    next_daily_occurrence(now, state.timezone_offset_hours, state.morning_hour)
  end

  defp next_occurrence("end_of_day", state, now) do
    next_daily_occurrence(now, state.timezone_offset_hours, state.end_of_day_hour)
  end

  defp next_occurrence("check_in", state, now) do
    if state.adaptive_check_ins_enabled do
      local_now = shift_local(now, state.timezone_offset_hours)
      local_date = DateTime.to_date(local_now)

      [local_date, Date.add(local_date, 1)]
      |> Enum.flat_map(&check_in_candidates(&1, state))
      |> Enum.map(& &1.scheduled_for)
      |> Enum.filter(&(DateTime.compare(&1, now) == :gt))
      |> Enum.min_by(&DateTime.to_unix(&1, :second), fn -> nil end)
    end
  end

  defp next_occurrence("weekly_review", state, now) do
    local_now = shift_local(now, state.timezone_offset_hours)
    local_date = DateTime.to_date(local_now)
    current_weekday = Date.day_of_week(local_date)

    days_ahead =
      case state.weekly_day - current_weekday do
        diff when diff < 0 ->
          diff + 7

        0 ->
          scheduled_today = local_datetime(local_date, state.weekly_hour)
          if DateTime.compare(local_now, scheduled_today) == :lt, do: 0, else: 7

        diff ->
          diff
      end

    target_date = Date.add(local_date, days_ahead)
    target_local = local_datetime(target_date, state.weekly_hour)
    shift_utc(target_local, state.timezone_offset_hours)
  end

  defp next_daily_occurrence(now, offset_hours, target_hour) do
    local_now = shift_local(now, offset_hours)
    local_date = DateTime.to_date(local_now)
    scheduled_today = local_datetime(local_date, target_hour)

    target_local =
      if DateTime.compare(local_now, scheduled_today) == :lt do
        scheduled_today
      else
        local_datetime(Date.add(local_date, 1), target_hour)
      end

    shift_utc(target_local, offset_hours)
  end

  defp morning_body(
         top_items,
         watching_items,
         act_now_insights,
         monitor_insights,
         offset_hours,
         now
       ) do
    """
    Best use of today:
    #{morning_guidance(top_items)}

    Focus now:
    #{format_items(top_items, offset_hours, now, "1. Nothing needs direct action right now.")}

    #{watching_section(watching_items, offset_hours, now)}

    Pressure:
    - #{length(act_now_insights)} items need direct action across Gmail, Calendar, and Slack
    - #{overdue_count(act_now_insights, offset_hours, now)} already overdue
    - #{due_today_count(act_now_insights, offset_hours, now)} due today
    - #{length(monitor_insights)} threads are still in Watching
    """
    |> String.trim()
  end

  defp end_of_day_body(
         debt_items,
         watching_items,
         act_now_insights,
         monitor_insights,
         offset_hours,
         now
       ) do
    """
    Tonight's move:
    #{end_of_day_guidance(debt_items)}

    Close or reset:
    #{format_items(debt_items, offset_hours, now, "1. Nothing needs direct action tonight.")}

    #{watching_section(watching_items, offset_hours, now)}

    Pressure:
    - #{overdue_count(act_now_insights, offset_hours, now)} items are already overdue across the full backlog
    - #{due_today_count(act_now_insights, offset_hours, now)} were due today and still unresolved
    - #{length(monitor_insights)} threads are still being watched
    """
    |> String.trim()
  end

  defp check_in_body(top_items, act_now_insights, offset_hours, reference_at) do
    """
    Why I'm checking in:
    #{check_in_guidance(top_items)}

    Move now:
    #{format_items(top_items, offset_hours, reference_at, "1. Nothing high-signal still needs movement.")}

    Pressure:
    - #{length(act_now_insights)} act-now loops still score as open
    - #{overdue_count(act_now_insights, offset_hours, reference_at)} are already overdue
    - #{due_today_count(act_now_insights, offset_hours, reference_at)} still land today

    Reply here when one is handled and I'll refresh the rest.
    """
    |> String.trim()
  end

  defp weekly_body(top_open, weekly_items, offset_hours, reference_at) do
    """
    Weekly scorecard:
    - #{count_by_source(weekly_items, "gmail")} Gmail items
    - #{count_by_source(weekly_items, "calendar")} Calendar follow-ups
    - #{count_by_source(weekly_items, "slack")} Slack loops

    Most important open items:
    #{format_items(top_open, offset_hours, reference_at)}
    """
    |> String.trim()
  end

  defp format_items(
         items,
         offset_hours,
         reference_at,
         empty_text \\ "1. Nothing high-signal is open."
       )

  defp format_items([], _offset_hours, _reference_at, empty_text), do: empty_text

  defp format_items(items, offset_hours, reference_at, _empty_text) do
    items
    |> Enum.with_index(1)
    |> Enum.map(fn card ->
      format_item_block(card, offset_hours, reference_at)
    end)
    |> Enum.join("\n")
  end

  defp watching_section([], _offset_hours, _reference_at), do: ""

  defp watching_section(items, offset_hours, reference_at) do
    """
    Watching, not blocking right now:
    #{format_items(items, offset_hours, reference_at, "1. Nothing newly changed is being watched.")}
    """
    |> String.trim()
  end

  defp format_item_block({card, index}, offset_hours, reference_at) do
    insight = card.insight
    source = source_label(insight.source)

    [
      "#{index}. [#{source}] #{item_heading(card)}",
      maybe_line("Waiting on", card.requested_by),
      maybe_line(action_label(insight), truncate_text(card.primary_action, 180)),
      maybe_line("Why", item_why_now(card, offset_hours, reference_at)),
      maybe_line("Checked", item_checked(card))
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
    |> String.trim()
  end

  defp morning_summary(
         top_items,
         due_today,
         act_now_insights,
         monitor_insights,
         offset_hours,
         now
       ) do
    top_items
    |> lead_summary(offset_hours, now)
    |> append_sentence(extra_open_item_summary(top_items))
    |> append_sentence("#{length(due_today)} due today")
    |> append_sentence(
      "#{overdue_count(act_now_insights, offset_hours, now)} overdue across the backlog"
    )
    |> append_sentence("#{length(monitor_insights)} being watched")
  end

  defp end_of_day_summary(
         debt_items,
         debt_candidates,
         monitor_insights,
         offset_hours,
         reference_at
       ) do
    debt_items
    |> lead_summary(offset_hours, reference_at)
    |> append_sentence(extra_open_item_summary(debt_items))
    |> append_sentence(
      "#{overdue_count(debt_candidates, offset_hours, reference_at)} overdue tonight"
    )
    |> append_sentence("#{length(monitor_insights)} being watched")
  end

  defp check_in_summary(top_items, act_now_insights, offset_hours, reference_at) do
    top_items
    |> lead_summary(offset_hours, reference_at)
    |> append_sentence(extra_open_item_summary(top_items))
    |> append_sentence("#{overdue_count(act_now_insights, offset_hours, reference_at)} overdue")
    |> append_sentence(
      "#{due_today_count(act_now_insights, offset_hours, reference_at)} still due today"
    )
  end

  defp lead_summary([], _offset_hours, _reference_at), do: nil

  defp lead_summary([card | _], offset_hours, reference_at) do
    [
      "Most urgent: #{item_heading(card)}",
      card.requested_by && "#{card.requested_by} is waiting",
      due_context(card.insight, offset_hours, reference_at)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&strip_terminal_period/1)
    |> Enum.join(". ")
  end

  defp extra_open_item_summary(items) do
    case length(items) - 1 do
      count when count > 0 -> "#{count} more high-signal loop#{if(count == 1, do: "", else: "s")}"
      _ -> nil
    end
  end

  defp append_sentence(nil, nil), do: nil
  defp append_sentence(nil, extra), do: sentence_case(extra)
  defp append_sentence(text, nil), do: text
  defp append_sentence(text, extra), do: text <> ". " <> sentence_case(extra)

  defp morning_guidance([]), do: "Nothing needs direct action right now."

  defp morning_guidance(items) do
    if mostly_reply_loops?(items) do
      "Start with the human threads that need an owner, a concrete ETA, or a short reset in the same thread."
    else
      "Start with the items where a person is waiting on you or the deadline lands today."
    end
  end

  defp end_of_day_guidance([]), do: "Nothing needs direct action tonight."

  defp end_of_day_guidance(items) do
    if mostly_reply_loops?(items) do
      "These are mostly reply loops. If the work is not finished, send a short owner + exact ETA tonight instead of waiting for the perfect answer."
    else
      "Close the promises with a human waiting on you, or explicitly reset timing before you sign off."
    end
  end

  defp check_in_guidance([]), do: "Nothing high-signal still warrants an interruption."

  defp check_in_guidance(items) do
    if mostly_reply_loops?(items) do
      "The highest-signal work is still in human threads. Send the short owner, status, or ETA reset now instead of waiting."
    else
      "The open work still scores high enough to interrupt you. Move the item with a person or deadline attached, then tell me it is handled."
    end
  end

  defp item_why_now(card, offset_hours, reference_at) do
    [
      truncate_text(card.open_loop_reason, 180),
      due_context(card.insight, offset_hours, reference_at)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.join(" ")
    |> normalize_string()
  end

  defp item_checked(%{evidence: nil}), do: nil
  defp item_checked(%{evidence: evidence}), do: truncate_text(evidence, 160)

  defp item_heading(card) do
    title = normalize_string(card.insight.title)

    cond do
      is_nil(title) and is_nil(card.promise_text) ->
        "Open loop"

      generic_heading?(title) and not is_nil(card.promise_text) ->
        card.promise_text

      true ->
        title || card.promise_text
    end
    |> prepend_requester(card.requested_by)
    |> truncate_text(120)
  end

  defp prepend_requester(title, nil), do: title
  defp prepend_requester(nil, requester), do: requester

  defp prepend_requester(title, requester) do
    if contains_text?(title, requester) do
      title
    else
      "#{requester}: #{title}"
    end
  end

  defp maybe_line(_label, nil), do: nil
  defp maybe_line(label, value), do: "#{label}: #{value}"

  defp action_label(%{attention_mode: "monitor"}), do: "Watch"
  defp action_label(_insight), do: "Do"

  defp select_brief_items([], _reference_at, _offset_hours, _limit, _opts), do: []

  defp select_brief_items(insights, reference_at, offset_hours, limit, opts) do
    cadence = Keyword.get(opts, :cadence, "general")

    insights
    |> Enum.map(&build_item_card(&1, reference_at, offset_hours, cadence))
    |> Enum.sort_by(
      fn card ->
        {
          card.score,
          urgency_score(card.insight, offset_hours, reference_at),
          datetime_sort_value(card.insight.updated_at || card.insight.inserted_at)
        }
      end,
      :desc
    )
    |> take_diverse_cards(limit)
  end

  defp build_item_card(insight, reference_at, offset_hours, cadence) do
    metadata = insight.metadata || %{}
    record = read_map(metadata, "record")
    detail = Detail.build(insight, [])

    %{
      insight: insight,
      promise_text: detail_text(detail.promise_text) || read_string(record, "commitment"),
      requested_by:
        detail_text(detail.requested_by) ||
          read_string(record, "person") ||
          read_string(metadata, "person") ||
          read_string(metadata, "from"),
      primary_action:
        read_string(record, "next_action") ||
          read_string(metadata, "next_action") ||
          insight.recommended_action,
      open_loop_reason:
        read_string(metadata, "why_now") ||
          read_string(metadata, "reasoning_summary") ||
          detail_reason_text(detail.open_loop_reason) ||
          insight.summary,
      evidence: best_evidence_text(detail.evidence_checked),
      group_key: item_group_key(insight, detail, metadata, record),
      score: item_score(insight, detail, metadata, offset_hours, reference_at, cadence)
    }
  end

  defp item_score(insight, detail, metadata, offset_hours, reference_at, cadence) do
    base = insight.priority * 10 + urgency_score(insight, offset_hours, reference_at)

    richness =
      0
      |> maybe_add(detail_text(detail.promise_text), 70)
      |> maybe_add(detail_text(detail.requested_by), 60)
      |> maybe_add(best_evidence_text(detail.evidence_checked), 50)
      |> maybe_add(detail_reason_text(detail.open_loop_reason), 30)
      |> maybe_add(read_string_list(metadata, "follow_up_ideas"), 20)
      |> maybe_add(read_boolean(metadata, "human_counterparty"), 30)
      |> maybe_add(read_boolean(metadata, "reply_obligation"), 30)

    cadence_bonus =
      case cadence do
        "end_of_day" -> if(overdue?(insight, offset_hours, reference_at), do: 50, else: 0)
        "monitor" -> 20
        _ -> 0
      end

    risk_penalty = round(read_float(metadata, "false_positive_risk", 0.0) * 100)

    base + richness + cadence_bonus - risk_penalty
  end

  defp urgency_score(insight, offset_hours, reference_at) do
    cond do
      overdue?(insight, offset_hours, reference_at) -> 400
      due_today?(insight, offset_hours, reference_at) -> 250
      due_tomorrow?(insight, offset_hours, reference_at) -> 120
      true -> 0
    end
  end

  defp maybe_add(score, nil, _bonus), do: score
  defp maybe_add(score, false, _bonus), do: score
  defp maybe_add(score, [], _bonus), do: score
  defp maybe_add(score, _value, bonus), do: score + bonus

  defp take_diverse_cards(cards, limit) do
    {selected, deferred, _seen} =
      Enum.reduce(cards, {[], [], MapSet.new()}, fn card, {selected, deferred, seen} ->
        key = card.group_key || "idx:#{length(selected)}:#{length(deferred)}"

        cond do
          length(selected) < limit and not MapSet.member?(seen, key) ->
            {[card | selected], deferred, MapSet.put(seen, key)}

          true ->
            {selected, [card | deferred], seen}
        end
      end)

    selected = Enum.reverse(selected)
    remaining = max(limit - length(selected), 0)

    selected ++
      (deferred
       |> Enum.reverse()
       |> Enum.take(remaining))
  end

  defp item_group_key(insight, detail, metadata, record) do
    normalize_group_key(
      detail_text(detail.requested_by) ||
        read_string(record, "person") ||
        read_string(metadata, "thread_id") ||
        read_string(record, "source") ||
        insight.source_id ||
        insight.title
    )
  end

  defp normalize_group_key(nil), do: nil

  defp normalize_group_key(value) do
    value
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/u, "-")
  end

  defp mostly_reply_loops?(items) do
    Enum.all?(items, fn card ->
      card.insight.source == "gmail" and
        card.insight.category in ["reply_urgent", "commitment_unresolved", "meeting_follow_up"]
    end)
  end

  defp card_insights(cards), do: Enum.map(cards, & &1.insight)

  defp detail_text(%{text: text}) when is_binary(text), do: normalize_string(text)
  defp detail_text(_), do: nil

  defp detail_reason_text(%{text: text}) when is_binary(text), do: normalize_string(text)
  defp detail_reason_text(_), do: nil

  defp best_evidence_text(items) when is_list(items) do
    items
    |> Enum.find_value(fn
      %{kind: :source_evidence} = item -> evidence_text(item)
      _ -> nil
    end)
  end

  defp best_evidence_text(_items), do: nil

  defp evidence_text(%{label: label, detail: detail}) do
    cond do
      normalize_string(label) && normalize_string(detail) -> "#{label}: #{detail}"
      normalize_string(label) -> label
      normalize_string(detail) -> detail
      true -> nil
    end
  end

  defp evidence_text(_item), do: nil

  defp generic_heading?(nil), do: false

  defp generic_heading?(title) do
    normalized = String.downcase(title)

    Enum.any?(
      [
        "reply owed",
        "overdue promise",
        "action needed",
        "follow up",
        "possible follow-up",
        "monitoring:"
      ],
      &String.starts_with?(normalized, &1)
    )
  end

  defp contains_text?(nil, _needle), do: false
  defp contains_text?(_haystack, nil), do: false

  defp contains_text?(haystack, needle) do
    String.contains?(String.downcase(haystack), String.downcase(needle))
  end

  defp truncate_text(nil, _max), do: nil

  defp truncate_text(text, max) when is_binary(text) and is_integer(max) and max > 3 do
    if String.length(text) > max do
      String.slice(text, 0, max - 3) <> "..."
    else
      text
    end
  end

  defp strip_terminal_period(text) when is_binary(text) do
    String.trim_trailing(text, ".")
  end

  defp sentence_case(nil), do: nil

  defp sentence_case(text) do
    text
    |> normalize_string()
    |> case do
      nil -> nil
      normalized -> String.capitalize(normalized)
    end
  end

  defp due_context(insight, offset_hours, reference_at) do
    case insight.due_at do
      %DateTime{} = due_at ->
        due_local = shift_local(due_at, offset_hours)
        now_local = shift_local(reference_at, offset_hours)
        due_date = DateTime.to_date(due_local)
        today = DateTime.to_date(now_local)

        cond do
          DateTime.compare(due_local, now_local) == :lt ->
            "Overdue since #{Calendar.strftime(due_local, "%a %-m/%-d %-I:%M %p")}."

          due_date == today ->
            "Due today by #{Calendar.strftime(due_local, "%-I:%M %p")}."

          due_date == Date.add(today, 1) ->
            "Due tomorrow by #{Calendar.strftime(due_local, "%-I:%M %p")}."

          true ->
            "Due #{Calendar.strftime(due_local, "%a %-m/%-d %-I:%M %p")}."
        end

      _ ->
        nil
    end
  end

  defp metadata_for(plan, behavior, insights, context) do
    %{
      "period_key" => plan.period_key,
      "agent_behavior" => behavior,
      "insight_count" => length(insights),
      "sources" => insights |> Enum.map(& &1.source) |> Enum.uniq()
    }
    |> AttentionArbiter.merge_artifact_metadata(context)
  end

  defp brief_delivery_metadata(insights, offset_hours) when is_list(insights) do
    linked_todo_ids =
      case Todos.sync_many_from_insights(insights) do
        {:ok, todos} -> Enum.map(todos, & &1.id)
        _ -> []
      end

    %{
      "linked_todo_ids" => linked_todo_ids,
      "linked_insight_ids" => Enum.map(insights, & &1.id),
      "timezone_offset_hours" => offset_hours
    }
  end

  defp generated_period?(state, cadence, period_key) do
    Map.get(state.last_generated_keys, cadence) == period_key
  end

  defp update_generated_keys(state, due) do
    Enum.reduce(due, state.last_generated_keys, fn %{cadence: cadence, period_key: period_key},
                                                   acc ->
      Map.put(acc, cadence, period_key)
    end)
  end

  defp dedupe_key(cadence, period_key), do: "brief:#{cadence}:#{period_key}"

  defp overdue_count(insights, offset_hours, reference_at),
    do: Enum.count(insights, &overdue?(&1, offset_hours, reference_at))

  defp due_today_count(insights, offset_hours, reference_at),
    do: Enum.count(insights, &due_today?(&1, offset_hours, reference_at))

  defp count_by_source(insights, source) do
    Enum.count(insights, fn insight -> normalize_source(insight.source) == source end)
  end

  defp recent_monitor_items(insights, reference_at) do
    cutoff = DateTime.add(reference_at, -36, :hour)

    insights
    |> Enum.filter(fn insight ->
      DateTime.compare(insight.updated_at || insight.inserted_at, cutoff) in [:eq, :gt]
    end)
  end

  defp due_today?(insight, offset_hours, reference_at) do
    case insight.due_at do
      %DateTime{} = due_at ->
        due_local_date = due_at |> shift_local(offset_hours) |> DateTime.to_date()
        now_local_date = reference_at |> shift_local(offset_hours) |> DateTime.to_date()
        Date.compare(due_local_date, now_local_date) == :eq

      _ ->
        false
    end
  end

  defp overdue?(insight, offset_hours, reference_at) do
    case insight.due_at do
      %DateTime{} = due_at ->
        due_local = shift_local(due_at, offset_hours)
        now_local = shift_local(reference_at, offset_hours)
        DateTime.compare(due_local, now_local) == :lt

      _ ->
        false
    end
  end

  defp due_tomorrow?(insight, offset_hours, reference_at) do
    case insight.due_at do
      %DateTime{} = due_at ->
        due_local_date = due_at |> shift_local(offset_hours) |> DateTime.to_date()
        now_local_date = reference_at |> shift_local(offset_hours) |> DateTime.to_date()
        Date.compare(due_local_date, Date.add(now_local_date, 1)) == :eq

      _ ->
        false
    end
  end

  defp should_send_check_in?([], _offset_hours, _reference_at), do: false

  defp should_send_check_in?(top_items, offset_hours, reference_at) do
    top_two_priority_sum =
      top_items
      |> Enum.take(2)
      |> Enum.reduce(0, fn card, acc -> acc + (card.insight.priority || 0) end)

    [top_item | _] = top_items

    overdue?(top_item.insight, offset_hours, reference_at) or
      due_today?(top_item.insight, offset_hours, reference_at) or
      (top_item.insight.priority || 0) >= 88 or
      top_two_priority_sum >= 165
  end

  defp check_in_candidates(local_date, state) do
    with true <- state.adaptive_check_ins_enabled,
         {:ok, start_local, end_local, span_minutes} <- check_in_window(local_date, state) do
      0..(state.check_in_slots_per_day - 1)
      |> Enum.map(
        &check_in_candidate_for_slot(state, local_date, &1, start_local, end_local, span_minutes)
      )
      |> Enum.uniq_by(&DateTime.to_unix(&1.scheduled_for, :second))
      |> Enum.sort_by(&DateTime.to_unix(&1.scheduled_for, :second))
    else
      _ -> []
    end
  end

  defp check_in_window(local_date, state) do
    start_hour = min(state.end_of_day_hour - 1, state.morning_hour + 2)
    end_hour = max(start_hour + 2, state.end_of_day_hour - 1)

    if end_hour <= start_hour do
      :error
    else
      start_local = local_datetime(local_date, start_hour)
      end_local = local_datetime(local_date, end_hour)
      span_minutes = max(div(DateTime.diff(end_local, start_local, :second), 60), 120)
      {:ok, start_local, end_local, span_minutes}
    end
  end

  defp check_in_candidate_for_slot(
         state,
         local_date,
         slot_index,
         start_local,
         end_local,
         span_minutes
       ) do
    segments = state.check_in_slots_per_day + 1
    base_minutes = div(span_minutes * (slot_index + 1), segments)
    jitter_range = min(35, max(div(span_minutes, max(segments * 3, 1)), 10))
    jitter_seed = :erlang.phash2({state.user_id, local_date, slot_index}, jitter_range * 2 + 1)
    jitter_minutes = jitter_seed - jitter_range
    offset_minutes = clamp_integer(base_minutes + jitter_minutes, 0, span_minutes)
    scheduled_local = DateTime.add(start_local, offset_minutes * 60, :second)

    %{
      cadence: "check_in",
      period_key: "#{Date.to_iso8601(local_date)}:slot:#{slot_index + 1}",
      scheduled_for:
        if(DateTime.compare(scheduled_local, end_local) == :gt,
          do: end_local,
          else: scheduled_local
        )
        |> shift_utc(state.timezone_offset_hours)
    }
  end

  defp source_label(source),
    do: source |> normalize_source() |> to_string() |> String.capitalize()

  defp normalize_source("google_calendar"), do: "calendar"
  defp normalize_source(other), do: other

  defp shift_local(datetime, offset_hours) do
    DateTime.add(datetime, offset_hours * 3600, :second)
  end

  defp shift_utc(datetime, offset_hours) do
    DateTime.add(datetime, offset_hours * -3600, :second)
  end

  defp local_datetime(date, hour) do
    {:ok, dt} = DateTime.new(date, Time.new!(hour, 0, 0), "Etc/UTC")
    dt
  end

  defp integer_in_range(value, default, min, max) do
    case value do
      int when is_integer(int) and int >= min and int <= max ->
        int

      binary when is_binary(binary) ->
        case Integer.parse(binary) do
          {int, ""} when int >= min and int <= max -> int
          _ -> default
        end

      _ ->
        default
    end
  end

  defp boolean_value(value, default) do
    case value do
      true -> true
      false -> false
      "true" -> true
      "false" -> false
      _ -> default
    end
  end

  defp normalize_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_string(_), do: nil

  defp read_string(attrs, key) when is_map(attrs) and is_binary(key) do
    attrs
    |> Map.get(key)
    |> normalize_string()
  end

  defp read_string(_attrs, _key), do: nil

  defp read_map(attrs, key) when is_map(attrs) and is_binary(key) do
    case Map.get(attrs, key) do
      value when is_map(value) -> value
      _ -> %{}
    end
  end

  defp read_boolean(attrs, key) when is_map(attrs) and is_binary(key) do
    case Map.get(attrs, key) do
      true -> true
      "true" -> true
      _ -> false
    end
  end

  defp read_float(attrs, key, default) when is_map(attrs) and is_binary(key) do
    case Map.get(attrs, key) do
      value when is_float(value) ->
        value

      value when is_integer(value) ->
        value / 1

      value when is_binary(value) ->
        case Float.parse(value) do
          {parsed, ""} -> parsed
          _ -> default
        end

      _ ->
        default
    end
  end

  defp read_string_list(attrs, key) when is_map(attrs) and is_binary(key) do
    case Map.get(attrs, key) do
      values when is_list(values) ->
        values
        |> Enum.map(&normalize_string/1)
        |> Enum.reject(&is_nil/1)

      _ ->
        []
    end
  end

  defp datetime_sort_value(%DateTime{} = datetime), do: DateTime.to_unix(datetime, :second)
  defp datetime_sort_value(_datetime), do: 0

  defp clamp_integer(value, min, _max) when is_integer(value) and value < min, do: min
  defp clamp_integer(value, _min, max) when is_integer(value) and value > max, do: max
  defp clamp_integer(value, _min, _max), do: value
end
