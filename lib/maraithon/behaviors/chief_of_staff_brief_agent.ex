defmodule Maraithon.Behaviors.ChiefOfStaffBriefAgent do
  @moduledoc """
  Generates recurring chief-of-staff briefs from the current insight stream.

  It does not rescan connectors directly. Instead, it turns the user's existing
  insight stream into morning briefs, end-of-day review rollups, and weekly
  reviews for Telegram delivery.
  """

  @behaviour Maraithon.Behaviors.Behavior

  alias Maraithon.Briefs
  alias Maraithon.ChiefOfStaff.AttentionArbiter
  alias Maraithon.Insights
  alias Maraithon.Insights.Detail
  alias Maraithon.SourceLabels
  alias Maraithon.Timezones
  alias Maraithon.Todos

  @default_timezone_offset_hours -5
  @default_morning_hour 8
  @default_end_of_day_hour 18
  @default_weekly_day 5
  @default_weekly_hour 16
  @default_max_items 12
  @max_items 30
  @default_check_in_slots_per_day 3
  @default_check_in_max_items 2

  @impl true
  def init(config) do
    %{
      user_id: normalize_string(config["user_id"]),
      assistant_behavior:
        normalize_string(config["assistant_behavior"]) || "founder_followthrough_agent",
      timezone: normalize_timezone(config["timezone"] || config["timezone_name"]),
      timezone_offset_hours:
        integer_in_range(config["timezone_offset_hours"], @default_timezone_offset_hours, -12, 14),
      morning_hour:
        integer_in_range(config["morning_brief_hour_local"], @default_morning_hour, 0, 23),
      end_of_day_hour:
        integer_in_range(config["end_of_day_brief_hour_local"], @default_end_of_day_hour, 0, 23),
      weekly_day: integer_in_range(config["weekly_review_day_local"], @default_weekly_day, 1, 7),
      weekly_hour:
        integer_in_range(config["weekly_review_hour_local"], @default_weekly_hour, 0, 23),
      max_items: integer_in_range(config["brief_max_items"], @default_max_items, 1, @max_items),
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
    due_today = Enum.filter(act_now_insights, &due_today?(&1, state, now))

    top_items =
      select_brief_items(
        act_now_insights,
        now,
        state,
        state.max_items,
        cadence: "morning"
      )

    watching_items =
      monitor_insights
      |> recent_monitor_items(now)
      |> select_brief_items(
        now,
        state,
        state.max_items,
        cadence: "monitor"
      )

    {title, summary} =
      cond do
        top_items == [] and watching_items == [] ->
          {"Morning brief: no direct action ready",
           "No direct action or watched thread is ready for this brief."}

        top_items == [] ->
          count = length(watching_items)

          {"Morning brief: watching items only",
           "#{count_phrase(count, "important thread")} #{be_verb(count)} being watched, with no direct action needed from you right now."}

        true ->
          count = length(top_items)

          {"Morning brief: #{count_phrase(count, "item")} worth watching",
           morning_summary(
             top_items,
             due_today,
             act_now_insights,
             monitor_insights,
             state,
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
          state,
          now
        ),
      "metadata" =>
        metadata_for(
          plan,
          state.assistant_behavior,
          delivery_insights,
          context
        )
        |> Map.merge(brief_delivery_metadata(delivery_insights, state, now))
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
        &(due_today?(&1, state, plan.scheduled_for) or
            overdue?(&1, state, plan.scheduled_for))
      )

    debt_items =
      select_brief_items(
        debt_candidates,
        plan.scheduled_for,
        state,
        state.max_items,
        cadence: "end_of_day"
      )

    watching_items =
      monitor_insights
      |> recent_monitor_items(plan.scheduled_for)
      |> select_brief_items(
        plan.scheduled_for,
        state,
        state.max_items,
        cadence: "monitor"
      )

    {title, summary} =
      cond do
        debt_items == [] and watching_items == [] ->
          {"End-of-day review: no unresolved work ready",
           "No unresolved action item is ready for tonight's review."}

        debt_items == [] ->
          count = length(watching_items)

          {"End-of-day review: watching items only",
           "#{count_phrase(count, "important thread")} #{be_verb(count)} still being watched, with no direct action needed from you tonight."}

        true ->
          count = length(debt_items)

          {"End-of-day review: #{count_phrase(count, "item")} still open",
           end_of_day_summary(
             debt_items,
             debt_candidates,
             monitor_insights,
             state,
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
          state,
          plan.scheduled_for
        ),
      "metadata" =>
        metadata_for(
          plan,
          state.assistant_behavior,
          delivery_insights,
          context
        )
        |> Map.merge(brief_delivery_metadata(delivery_insights, state, plan.scheduled_for))
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
        state,
        state.check_in_max_items,
        cadence: "check_in"
      )

    if should_send_check_in?(top_items, state, plan.scheduled_for) do
      count = length(top_items)
      movement_verb = if count == 1, do: "needs", else: "need"

      check_in_metadata =
        brief_delivery_metadata(card_insights(top_items), state, plan.scheduled_for)

      %{
        "cadence" => "check_in",
        "scheduled_for" => plan.scheduled_for,
        "dedupe_key" => dedupe_key("check_in", plan.period_key),
        "title" =>
          "Check-in: #{count} item#{if(count == 1, do: "", else: "s")} still #{movement_verb} movement",
        "summary" =>
          check_in_summary(
            top_items,
            act_now_insights,
            state,
            plan.scheduled_for
          ),
        "body" =>
          check_in_body(
            top_items,
            act_now_insights,
            state,
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
        state,
        state.max_items,
        cadence: "weekly_review"
      )

    open_count = Enum.count(act_now_insights) + Enum.count(monitor_insights)
    closed_count = Enum.count(weekly_items, &(&1.status in ["acknowledged", "dismissed"]))

    %{
      "cadence" => "weekly_review",
      "scheduled_for" => plan.scheduled_for,
      "dedupe_key" => dedupe_key("weekly_review", plan.period_key),
      "title" => weekly_title(open_count),
      "summary" => weekly_summary(length(weekly_items), closed_count, open_count),
      "body" => weekly_body(top_open, weekly_items, state, plan.scheduled_for),
      "metadata" =>
        metadata_for(plan, state.assistant_behavior, weekly_items, context)
        |> Map.merge(timezone_metadata(state, plan.scheduled_for))
    }
  end

  defp due_cadences(state, now) do
    local_now = shift_local(now, state)

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
    scheduled_utc = shift_utc(scheduled_local, state)

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
    scheduled_utc = shift_utc(scheduled_local, state)

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
      scheduled_utc = shift_utc(scheduled_local, state)

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
    next_daily_occurrence(now, state, state.morning_hour)
  end

  defp next_occurrence("end_of_day", state, now) do
    next_daily_occurrence(now, state, state.end_of_day_hour)
  end

  defp next_occurrence("check_in", state, now) do
    if state.adaptive_check_ins_enabled do
      local_now = shift_local(now, state)
      local_date = DateTime.to_date(local_now)

      [local_date, Date.add(local_date, 1)]
      |> Enum.flat_map(&check_in_candidates(&1, state))
      |> Enum.map(& &1.scheduled_for)
      |> Enum.filter(&(DateTime.compare(&1, now) == :gt))
      |> Enum.min_by(&DateTime.to_unix(&1, :second), fn -> nil end)
    end
  end

  defp next_occurrence("weekly_review", state, now) do
    local_now = shift_local(now, state)
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
    shift_utc(target_local, state)
  end

  defp next_daily_occurrence(now, time_context, target_hour) do
    local_now = shift_local(now, time_context)
    local_date = DateTime.to_date(local_now)
    scheduled_today = local_datetime(local_date, target_hour)

    target_local =
      if DateTime.compare(local_now, scheduled_today) == :lt do
        scheduled_today
      else
        local_datetime(Date.add(local_date, 1), target_hour)
      end

    shift_utc(target_local, time_context)
  end

  defp morning_body(
         top_items,
         watching_items,
         act_now_insights,
         monitor_insights,
         time_context,
         now
       ) do
    workload =
      workload_section(
        [
          count_line(
            length(act_now_insights),
            "item needs direct action in connected sources",
            "items need direct action in connected sources"
          ),
          count_line(
            overdue_count(act_now_insights, time_context, now),
            "item is already overdue",
            "items are already overdue"
          ),
          count_line(
            due_today_count(act_now_insights, time_context, now),
            "item is due today",
            "items are due today"
          ),
          count_line(
            length(monitor_insights),
            "thread is still in Watching",
            "threads are still in Watching"
          )
        ],
        "No direct action is ready for this brief."
      )

    """
    Best use of today:
    #{morning_guidance(top_items)}

    Focus now:
    #{format_items(top_items, time_context, now, "1. No direct action is ready for this brief.")}

    #{watching_section(watching_items, time_context, now)}

    #{workload}
    """
    |> String.trim()
  end

  defp end_of_day_body(
         debt_items,
         watching_items,
         act_now_insights,
         monitor_insights,
         time_context,
         now
       ) do
    workload =
      workload_section(
        [
          count_line(
            overdue_count(act_now_insights, time_context, now),
            "item is already overdue across the full backlog",
            "items are already overdue across the full backlog"
          ),
          count_line(
            due_today_count(act_now_insights, time_context, now),
            "item was due today and is still unresolved",
            "items were due today and are still unresolved"
          ),
          count_line(
            length(monitor_insights),
            "thread is still being watched",
            "threads are still being watched"
          )
        ],
        "No unresolved work is ready for tonight's review."
      )

    """
    Tonight's move:
    #{end_of_day_guidance(debt_items)}

    Close or reset:
    #{format_items(debt_items, time_context, now, "1. No unresolved item is ready for tonight's review.")}

    #{watching_section(watching_items, time_context, now)}

    #{workload}
    """
    |> String.trim()
  end

  defp check_in_body(top_items, act_now_insights, time_context, reference_at) do
    workload =
      workload_section(
        [
          count_line(
            length(act_now_insights),
            "item still needs a decision or reply",
            "items still need a decision or reply"
          ),
          count_line(
            overdue_count(act_now_insights, time_context, reference_at),
            "item is already overdue",
            "items are already overdue"
          ),
          count_line(
            due_today_count(act_now_insights, time_context, reference_at),
            "item still lands today",
            "items still land today"
          )
        ],
        "No active work warrants an interruption."
      )

    """
    Why this check-in matters:
    #{check_in_guidance(top_items)}

    Move now:
    #{format_items(top_items, time_context, reference_at, "1. No active work needs movement right now.")}

    #{workload}

    Reply here when one is handled; Maraithon will refresh the rest.
    """
    |> String.trim()
  end

  defp weekly_body(top_open, weekly_items, time_context, reference_at) do
    """
    Week in review:
    #{weekly_source_lines(weekly_items)}

    Next week's move:
    #{weekly_guidance(top_open)}

    Most important open items:
    #{format_items(top_open, time_context, reference_at, "1. No open work is ready from this week's review.")}
    """
    |> String.trim()
  end

  defp format_items(
         items,
         time_context,
         reference_at,
         empty_text
       )

  defp format_items([], _time_context, _reference_at, empty_text), do: empty_text

  defp format_items(items, time_context, reference_at, _empty_text) do
    items
    |> Enum.with_index(1)
    |> Enum.map(fn card ->
      format_item_block(card, time_context, reference_at)
    end)
    |> Enum.join("\n")
  end

  defp watching_section([], _time_context, _reference_at), do: ""

  defp watching_section(items, time_context, reference_at) do
    """
    Watching, not blocking right now:
    #{format_items(items, time_context, reference_at, "1. No newly changed watched items found.")}
    """
    |> String.trim()
  end

  defp workload_section(lines, empty_text) do
    lines = Enum.reject(lines, &is_nil/1)

    if lines == [] do
      """
      Status:
      #{empty_text}
      """
    else
      """
      Open work:
      #{Enum.join(lines, "\n")}
      """
    end
    |> String.trim()
  end

  defp count_line(0, _singular, _plural), do: nil
  defp count_line(1, singular, _plural), do: "- 1 #{singular}"

  defp count_line(count, _singular, plural) when is_integer(count) and count > 1,
    do: "- #{count} #{plural}"

  defp count_line(_count, _singular, _plural), do: nil

  defp weekly_source_lines(weekly_items) do
    [
      count_line(count_by_source(weekly_items, "gmail"), "Gmail item", "Gmail items"),
      count_line(
        count_by_source(weekly_items, "calendar"),
        "Calendar follow-up",
        "Calendar follow-ups"
      ),
      count_line(count_by_source(weekly_items, "slack"), "Slack follow-up", "Slack follow-ups")
    ]
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> "- No activity needed review this week"
      lines -> Enum.join(lines, "\n")
    end
  end

  defp format_item_block({card, index}, time_context, reference_at) do
    insight = card.insight
    source = source_label(insight.source)

    [
      "#{index}. [#{source}] #{item_heading(card)}",
      maybe_line("Waiting on", card.requested_by),
      maybe_line(action_label(insight), truncate_text(card.primary_action, 180)),
      maybe_line("Why", item_why_now(card, time_context, reference_at)),
      maybe_line("Context", item_checked(card))
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
         time_context,
         now
       ) do
    top_items
    |> lead_summary(time_context, now)
    |> append_sentence(extra_open_item_summary(top_items))
    |> append_sentence(count_summary(length(due_today), "due today", "due today"))
    |> append_sentence(
      count_summary(
        overdue_count(act_now_insights, time_context, now),
        "overdue across the backlog",
        "overdue across the backlog"
      )
    )
    |> append_sentence(count_summary(length(monitor_insights), "being watched", "being watched"))
  end

  defp end_of_day_summary(
         debt_items,
         debt_candidates,
         monitor_insights,
         time_context,
         reference_at
       ) do
    debt_items
    |> lead_summary(time_context, reference_at)
    |> append_sentence(extra_open_item_summary(debt_items))
    |> append_sentence(
      count_summary(
        overdue_count(debt_candidates, time_context, reference_at),
        "overdue tonight",
        "overdue tonight"
      )
    )
    |> append_sentence(count_summary(length(monitor_insights), "being watched", "being watched"))
  end

  defp check_in_summary(top_items, act_now_insights, time_context, reference_at) do
    top_items
    |> lead_summary(time_context, reference_at)
    |> append_sentence(extra_open_item_summary(top_items))
    |> append_sentence(
      count_summary(
        overdue_count(act_now_insights, time_context, reference_at),
        "overdue",
        "overdue"
      )
    )
    |> append_sentence(
      count_summary(
        due_today_count(act_now_insights, time_context, reference_at),
        "still due today",
        "still due today"
      )
    )
  end

  defp count_summary(0, _singular, _plural), do: nil
  defp count_summary(1, singular, _plural), do: "1 #{singular}"

  defp count_summary(count, _singular, plural) when is_integer(count) and count > 1,
    do: "#{count} #{plural}"

  defp count_summary(_count, _singular, _plural), do: nil

  defp weekly_summary(weekly_count, closed_count, open_count) do
    [
      count_summary(weekly_count, "item reviewed this week", "items reviewed this week"),
      count_summary(closed_count, "was resolved or triaged", "were resolved or triaged"),
      count_summary(open_count, "remains open", "remain open")
    ]
    |> Enum.reject(&is_nil/1)
    |> summary_sentence()
  end

  defp summary_sentence([]), do: "No open work is ready from this week's review."
  defp summary_sentence([part]), do: part <> "."
  defp summary_sentence([first, second]), do: "#{first}, and #{second}."

  defp summary_sentence(parts) do
    {last, rest} = List.pop_at(parts, -1)
    "#{Enum.join(rest, ", ")}, and #{last}."
  end

  defp count_phrase(1, noun), do: "1 #{noun}"
  defp count_phrase(count, noun) when is_integer(count), do: "#{count} #{noun}s"

  defp be_verb(1), do: "is"
  defp be_verb(_count), do: "are"

  defp weekly_title(0), do: "Weekly review: no open work ready"

  defp weekly_title(open_count),
    do: "Weekly review: #{count_phrase(open_count, "item")} still open"

  defp lead_summary([], _time_context, _reference_at), do: nil

  defp lead_summary([card | _], time_context, reference_at) do
    [
      "Most urgent: #{item_heading(card)}",
      card.requested_by && "#{card.requested_by} is waiting",
      due_context(card.insight, time_context, reference_at)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&strip_terminal_period/1)
    |> Enum.join(". ")
  end

  defp extra_open_item_summary(items) do
    case length(items) - 1 do
      count when count > 0 -> "#{count} more open item#{if(count == 1, do: "", else: "s")}"
      _ -> nil
    end
  end

  defp append_sentence(nil, nil), do: nil
  defp append_sentence(nil, extra), do: sentence_case(extra)
  defp append_sentence(text, nil), do: text
  defp append_sentence(text, extra), do: text <> ". " <> sentence_case(extra)

  defp morning_guidance([]), do: "No direct action is ready for this brief."

  defp morning_guidance(items) do
    if mostly_reply_loops?(items) do
      "Start with the human threads that need an owner, a concrete ETA, or a short reset in the same thread."
    else
      "Start with the items where a person is waiting on you or the deadline lands today."
    end
  end

  defp end_of_day_guidance([]), do: "No direct action is ready for tonight's review."

  defp end_of_day_guidance(items) do
    if mostly_reply_loops?(items) do
      "These are mostly reply threads. If the work is not finished, send a short owner + exact ETA tonight instead of waiting for the perfect answer."
    else
      "Close the promises with a human waiting on you, or explicitly reset timing before you sign off."
    end
  end

  defp check_in_guidance([]), do: "No item warrants an interruption."

  defp check_in_guidance(items) do
    if mostly_reply_loops?(items) do
      "The most important work is still in human threads. Send the short owner, status, or ETA reset now instead of waiting."
    else
      "This is important enough to interrupt you. Move the item with a person or deadline attached, then tell me it is handled."
    end
  end

  defp weekly_guidance([]) do
    "Use Monday's first planning block to confirm calendar context and any new promises before adding more work."
  end

  defp weekly_guidance(items) do
    if mostly_reply_loops?(items) do
      "Start Monday by sending the owner, status, or ETA reset on the first open human thread before taking on new work."
    else
      "Start Monday by closing or explicitly rescoping the first open item before taking on new work."
    end
  end

  defp item_why_now(card, time_context, reference_at) do
    [
      truncate_text(card.open_loop_reason, 180),
      due_context(card.insight, time_context, reference_at)
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
        "Open follow-up"

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

  defp action_label(%{attention_mode: "monitor"}), do: "Track"
  defp action_label(_insight), do: "Do"

  defp select_brief_items([], _reference_at, _time_context, _limit, _opts), do: []

  defp select_brief_items(insights, reference_at, time_context, limit, opts) do
    cadence = Keyword.get(opts, :cadence, "general")

    insights
    |> Enum.map(&build_item_card(&1, reference_at, time_context, cadence))
    |> Enum.sort_by(
      fn card ->
        {
          card.score,
          urgency_score(card.insight, time_context, reference_at),
          datetime_sort_value(card.insight.updated_at || card.insight.inserted_at)
        }
      end,
      :desc
    )
    |> take_diverse_cards(limit)
  end

  defp build_item_card(insight, reference_at, time_context, cadence) do
    metadata = insight.metadata || %{}
    record = read_map(metadata, "record")

    detail =
      Detail.build(insight, [],
        timezone_info: timezone_info(time_context, reference_at),
        reference_at: reference_at
      )

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
      score: item_score(insight, detail, metadata, time_context, reference_at, cadence)
    }
  end

  defp item_score(insight, detail, metadata, time_context, reference_at, cadence) do
    base = insight.priority * 10 + urgency_score(insight, time_context, reference_at)

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
        "end_of_day" -> if(overdue?(insight, time_context, reference_at), do: 50, else: 0)
        "monitor" -> 20
        _ -> 0
      end

    risk_penalty = round(read_float(metadata, "false_positive_risk", 0.0) * 100)

    base + richness + cadence_bonus - risk_penalty
  end

  defp urgency_score(insight, time_context, reference_at) do
    cond do
      overdue?(insight, time_context, reference_at) -> 400
      due_today?(insight, time_context, reference_at) -> 250
      due_tomorrow?(insight, time_context, reference_at) -> 120
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

  defp due_context(insight, time_context, reference_at) do
    case insight.due_at do
      %DateTime{} = due_at ->
        due_local = shift_local(due_at, time_context)
        now_local = shift_local(reference_at, time_context)
        due_date = DateTime.to_date(due_local)
        today = DateTime.to_date(now_local)
        suffix = timezone_suffix(time_context, due_at)

        cond do
          DateTime.compare(due_at, reference_at) == :lt ->
            "Overdue since #{brief_datetime(due_local)}#{suffix}."

          due_date == today ->
            "Due today by #{brief_time(due_local)}#{suffix}."

          due_date == Date.add(today, 1) ->
            "Due tomorrow by #{brief_time(due_local)}#{suffix}."

          true ->
            "Due #{brief_datetime(due_local)}#{suffix}."
        end

      _ ->
        nil
    end
  end

  defp brief_datetime(%DateTime{} = datetime) do
    Calendar.strftime(datetime, "%a, %b %-d at %-I:%M %p")
  end

  defp brief_time(%DateTime{} = datetime) do
    Calendar.strftime(datetime, "%-I:%M %p")
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

  defp brief_delivery_metadata(insights, time_context, reference_at) when is_list(insights) do
    linked_todo_ids =
      case Todos.sync_many_from_insights(insights) do
        {:ok, todos} -> Enum.map(todos, & &1.id)
        _ -> []
      end

    %{
      "linked_todo_ids" => linked_todo_ids,
      "linked_insight_ids" => Enum.map(insights, & &1.id)
    }
    |> Map.merge(timezone_metadata(time_context, reference_at))
  end

  defp timezone_metadata(time_context, reference_at) do
    %{
      "timezone_offset_hours" => timezone_offset_hours_at(reference_at, time_context),
      "timezone" => timezone_label(time_context, reference_at),
      "timezone_name" => timezone_name(time_context)
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

  defp overdue_count(insights, time_context, reference_at),
    do: Enum.count(insights, &overdue?(&1, time_context, reference_at))

  defp due_today_count(insights, time_context, reference_at),
    do: Enum.count(insights, &due_today?(&1, time_context, reference_at))

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

  defp due_today?(insight, time_context, reference_at) do
    case insight.due_at do
      %DateTime{} = due_at ->
        due_local_date = due_at |> shift_local(time_context) |> DateTime.to_date()
        now_local_date = reference_at |> shift_local(time_context) |> DateTime.to_date()
        Date.compare(due_local_date, now_local_date) == :eq

      _ ->
        false
    end
  end

  defp overdue?(insight, _time_context, reference_at) do
    case insight.due_at do
      %DateTime{} = due_at ->
        DateTime.compare(due_at, reference_at) == :lt

      _ ->
        false
    end
  end

  defp due_tomorrow?(insight, time_context, reference_at) do
    case insight.due_at do
      %DateTime{} = due_at ->
        due_local_date = due_at |> shift_local(time_context) |> DateTime.to_date()
        now_local_date = reference_at |> shift_local(time_context) |> DateTime.to_date()
        Date.compare(due_local_date, Date.add(now_local_date, 1)) == :eq

      _ ->
        false
    end
  end

  defp should_send_check_in?([], _time_context, _reference_at), do: false

  defp should_send_check_in?(top_items, time_context, reference_at) do
    top_two_priority_sum =
      top_items
      |> Enum.take(2)
      |> Enum.reduce(0, fn card, acc -> acc + (card.insight.priority || 0) end)

    [top_item | _] = top_items

    overdue?(top_item.insight, time_context, reference_at) or
      due_today?(top_item.insight, time_context, reference_at) or
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
        |> shift_utc(state)
    }
  end

  defp source_label(source), do: SourceLabels.label(source)

  defp normalize_source("google_calendar"), do: "calendar"
  defp normalize_source(other), do: other

  defp shift_local(%DateTime{} = datetime, time_context) do
    offset_hours = timezone_offset_hours_at(datetime, time_context)
    DateTime.add(datetime, offset_hours * 3600, :second)
  end

  defp shift_utc(%DateTime{} = datetime, time_context) do
    offset_hours = timezone_offset_hours_for_local(datetime, time_context)
    DateTime.add(datetime, offset_hours * -3600, :second)
  end

  defp timezone_offset_hours_at(_datetime, offset_hours) when is_integer(offset_hours),
    do: offset_hours

  defp timezone_offset_hours_at(%DateTime{} = datetime, time_context)
       when is_map(time_context) do
    Timezones.offset_at(
      timezone_name(time_context),
      datetime,
      timezone_fallback_offset(time_context)
    )
  end

  defp timezone_offset_hours_for_local(_datetime, offset_hours) when is_integer(offset_hours),
    do: offset_hours

  defp timezone_offset_hours_for_local(%DateTime{} = datetime, time_context)
       when is_map(time_context) do
    Timezones.offset_for_local(
      timezone_name(time_context),
      datetime,
      timezone_fallback_offset(time_context)
    )
  end

  defp timezone_label(time_context, %DateTime{} = datetime) do
    offset = timezone_offset_hours_at(datetime, time_context)
    Timezones.label(timezone_name(time_context), offset)
  end

  defp timezone_info(time_context, %DateTime{} = datetime) do
    %{
      name: timezone_name(time_context),
      offset_hours: timezone_offset_hours_at(datetime, time_context)
    }
  end

  defp timezone_suffix(time_context, %DateTime{} = datetime) do
    case timezone_name(time_context) do
      nil -> ""
      _timezone -> " #{timezone_label(time_context, datetime)}"
    end
  end

  defp timezone_name(time_context) when is_map(time_context), do: Map.get(time_context, :timezone)
  defp timezone_name(_time_context), do: nil

  defp timezone_fallback_offset(time_context) when is_map(time_context) do
    case Map.get(time_context, :timezone_offset_hours) do
      offset when is_integer(offset) -> offset
      _ -> @default_timezone_offset_hours
    end
  end

  defp timezone_fallback_offset(_time_context), do: @default_timezone_offset_hours

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

  defp normalize_timezone(value) when is_binary(value) do
    case Timezones.normalize(value) do
      normalized when is_binary(normalized) -> normalized
      _ -> nil
    end
  end

  defp normalize_timezone(_value), do: nil

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
