defmodule Maraithon.TelegramAssistant.Proactive do
  @moduledoc """
  Model-backed proactive Telegram planning and delivery.

  This module is the proactive counterpart to the inbound Telegram assistant
  loop. It supplies durable open-loop context to the assistant harness and asks
  the model whether a Telegram interruption is useful right now.
  """

  import Ecto.Query

  alias Maraithon.ActionLedger
  alias Maraithon.AssistantHarness
  alias Maraithon.BriefingSchedules
  alias Maraithon.ConnectedAccounts
  alias Maraithon.Repo
  alias Maraithon.TelegramAssistant
  alias Maraithon.Timezones

  alias Maraithon.TelegramAssistant.{
    Context,
    ProactiveQualityGate,
    PushBroker,
    PushReceipt,
    TodoActions
  }

  alias Maraithon.TelegramConversations.Conversation
  alias Maraithon.Todos
  alias Maraithon.Todos.UserFacingCopy

  @recent_push_limit 8
  @default_due_batch_size 25
  @default_timezone_offset_hours -5

  def enabled? do
    config = Application.get_env(:maraithon, :telegram_assistant, [])

    case Keyword.get(config, :telegram_proactive_checkins_enabled) do
      true -> true
      false -> false
      nil -> false
    end
  end

  def plan_check_in(user_id, opts \\ [])

  def plan_check_in(user_id, opts) when is_binary(user_id) do
    chat_id = Keyword.get(opts, :chat_id) || ConnectedAccounts.telegram_destination(user_id)

    payload = %{
      trigger: proactive_trigger(user_id, chat_id, opts),
      context:
        Keyword.get(opts, :context) ||
          Context.build(%{user_id: user_id, chat_id: chat_id || "unavailable"}),
      recent_pushes:
        recent_pushes(user_id, Keyword.get(opts, :recent_push_limit, @recent_push_limit))
    }

    with {:ok, plan} <- AssistantHarness.proactive_plan(payload, opts) do
      {:ok, ProactiveQualityGate.verify_proactive_plan(plan, payload, opts)}
    end
  end

  def plan_check_in(_user_id, _opts), do: {:error, :invalid_user}

  def deliver_check_in(user_id, opts \\ [])

  def deliver_check_in(user_id, opts) when is_binary(user_id) do
    cond do
      not Keyword.get(opts, :force, false) and not enabled?() ->
        {:ok, %{decision: "disabled"}}

      is_nil(Keyword.get(opts, :chat_id) || ConnectedAccounts.telegram_destination(user_id)) ->
        {:error, :telegram_not_connected}

      true ->
        do_deliver_check_in(user_id, opts)
    end
  end

  def deliver_check_in(_user_id, _opts), do: {:error, :invalid_user}

  def deliver_due_check_ins(opts \\ []) do
    if enabled?() or Keyword.get(opts, :force, false) do
      batch_size = Keyword.get(opts, :batch_size, @default_due_batch_size)

      "telegram"
      |> ConnectedAccounts.list_connected_provider()
      |> Enum.take(batch_size)
      |> Enum.reduce(%{sent: 0, held: 0, suppressed: 0, failed: 0, disabled: 0}, fn account,
                                                                                    acc ->
        case deliver_check_in(account.user_id, opts) do
          {:ok, %{"decision" => "sent_now"}} -> %{acc | sent: acc.sent + 1}
          {:ok, %{decision: "sent_now"}} -> %{acc | sent: acc.sent + 1}
          {:ok, %{"decision" => "queued"}} -> %{acc | sent: acc.sent + 1}
          {:ok, %{"decision" => "hold"}} -> %{acc | held: acc.held + 1}
          {:ok, %{decision: "hold"}} -> %{acc | held: acc.held + 1}
          {:ok, %{"decision" => "suppressed"}} -> %{acc | suppressed: acc.suppressed + 1}
          {:ok, %{decision: "suppressed"}} -> %{acc | suppressed: acc.suppressed + 1}
          {:ok, %{"decision" => "disabled"}} -> %{acc | disabled: acc.disabled + 1}
          {:ok, %{decision: "disabled"}} -> %{acc | disabled: acc.disabled + 1}
          {:ok, _other} -> acc
          {:error, _reason} -> %{acc | failed: acc.failed + 1}
        end
      end)
    else
      %{sent: 0, held: 0, suppressed: 0, failed: 0, disabled: 0}
    end
  end

  defp do_deliver_check_in(user_id, opts) do
    chat_id = Keyword.get(opts, :chat_id) || ConnectedAccounts.telegram_destination(user_id)

    context =
      Keyword.get(opts, :context) ||
        Context.build(%{user_id: user_id, chat_id: chat_id || "unavailable"})

    case plan_check_in(
           user_id,
           opts |> Keyword.put(:chat_id, chat_id) |> Keyword.put(:context, context)
         ) do
      {:ok, %{"decision" => "send_now"} = plan} ->
        deliver_plan(user_id, chat_id, plan, opts)

      {:ok, %{"decision" => "hold"} = plan} ->
        if no_review_todos?(context) do
          deliver_no_review_notice(user_id, chat_id, context, opts)
        else
          record_proactive_decision(
            user_id,
            nil,
            plan,
            proactive_trigger(user_id, chat_id, opts),
            %{
              event_type: "proactive.held",
              status: "held"
            }
          )

          {:ok, Map.put(plan, "decision", "hold")}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp deliver_plan(user_id, chat_id, plan, opts) do
    trigger = proactive_trigger(user_id, chat_id, opts)
    dedupe_key = plan_dedupe_key(user_id, plan, trigger)

    if TelegramAssistant.proactive_delivery_planner_enabled?() do
      enqueue_plan_candidate(user_id, chat_id, plan, trigger, dedupe_key)
    else
      deliver_plan_now(user_id, chat_id, plan, trigger, dedupe_key)
    end
  end

  defp deliver_no_review_notice(user_id, chat_id, context, opts) do
    trigger = proactive_trigger(user_id, chat_id, opts)
    dedupe_key = no_review_notice_dedupe_key(user_id, trigger)

    plan = %{
      "decision" => "send_now",
      "assistant_message" => no_review_notice_message(context),
      "message_class" => "system_notice",
      "urgency" => 0.35,
      "interrupt_now" => true,
      "dedupe_key" => dedupe_key,
      "todo_ids" => [],
      "summary" => "No saved open work is ready for review, so an all-clear check-in was sent."
    }

    deliver_plan_now(user_id, chat_id, plan, trigger, dedupe_key)
  end

  defp deliver_plan_now(user_id, chat_id, plan, trigger, dedupe_key) do
    candidate = %{
      user_id: user_id,
      chat_id: chat_id,
      origin_type: "assistant_digest",
      origin_id: Map.get(trigger, "id"),
      dedupe_key: dedupe_key,
      title: "Maraithon check-in",
      body: delivery_text(Map.fetch!(plan, "assistant_message")),
      urgency: Map.get(plan, "urgency", 0.0),
      interrupt_now: Map.get(plan, "interrupt_now", false),
      why_now: Map.get(plan, "summary"),
      structured_data: %{
        "message_class" => Map.get(plan, "message_class"),
        "summary" => Map.get(plan, "summary"),
        "todo_ids" => Map.get(plan, "todo_ids", []),
        "trigger" => trigger
      },
      conversation_metadata: %{"mode" => "proactive_check_in"}
    }

    case PushBroker.deliver(candidate) do
      {:ok, %{decision: "sent_now", conversation_id: conversation_id} = result} ->
        result =
          if Map.get(plan, "message_class") == "todo_digest" do
            Map.put(result, :todo_items_sent, send_todo_cards(conversation_id, user_id, plan))
          else
            result
          end

        record_proactive_decision(user_id, dedupe_key, plan, trigger, %{
          event_type: "proactive.sent",
          status: "sent",
          result: result
        })

        {:ok, Map.merge(plan, stringify_result(result))}

      {:ok, %{decision: decision} = result} ->
        record_proactive_decision(user_id, dedupe_key, plan, trigger, %{
          event_type: "proactive.held",
          status: "held",
          result: result
        })

        {:ok, plan |> Map.put("decision", decision) |> Map.merge(stringify_result(result))}

      {:fallback, reason} ->
        {:ok,
         plan
         |> Map.put("decision", "disabled")
         |> Map.put("reason", to_string(reason))}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp enqueue_plan_candidate(user_id, _chat_id, plan, trigger, dedupe_key) do
    TelegramAssistant.enqueue_proactive_candidate(%{
      user_id: user_id,
      source: "proactive_check_in",
      source_id: Map.fetch!(trigger, "id"),
      dedupe_key: dedupe_key,
      title: "Maraithon check-in",
      body: delivery_text(Map.fetch!(plan, "assistant_message")),
      urgency: Map.get(plan, "urgency", 0.0),
      why_now: Map.get(plan, "summary"),
      structured_data: %{
        "message_class" => Map.get(plan, "message_class"),
        "summary" => Map.get(plan, "summary"),
        "todo_ids" => Map.get(plan, "todo_ids", []),
        "interrupt_now" => Map.get(plan, "interrupt_now"),
        "trigger" => trigger
      },
      telegram_opts: %{"parse_mode" => "HTML"}
    })
    |> case do
      {:ok, candidate} ->
        {:ok,
         plan
         |> Map.put("decision", "queued")
         |> Map.put("candidate_id", candidate.id)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp send_todo_cards(conversation_id, user_id, plan) do
    with %Conversation{} = conversation <- Repo.get(Conversation, conversation_id),
         todo_ids when todo_ids != [] <- Map.get(plan, "todo_ids", []) do
      todos = Todos.list_by_ids(user_id, todo_ids, statuses: ["open", "snoozed"])

      Enum.reduce(todos, 0, fn todo, count ->
        payload = TodoActions.telegram_payload(todo)

        case TelegramAssistant.send_turn(
               conversation,
               conversation.chat_id,
               payload.text,
               send_mode: :send,
               turn_kind: "assistant_push",
               origin_type: "assistant_digest",
               preserve_safe_label_prefixes: true,
               structured_data: %{
                 "message_class" => "todo_item",
                 "linked_todo" => Todos.serialize_for_prompt(todo)
               },
               telegram_opts: [parse_mode: "HTML", reply_markup: payload.reply_markup]
             ) do
          {:ok, _conversation, _turn, _telegram_result} -> count + 1
          {:error, _reason} -> count
        end
      end)
    else
      _other -> 0
    end
  end

  defp delivery_text(value) when is_binary(value), do: UserFacingCopy.polish_text(value)
  defp delivery_text(value), do: value

  defp no_review_todos?(context) when is_map(context) do
    with todos when is_list(todos) <- read_field(context, "todos"),
         true <- todos == [],
         true <- context_fetch_ready_for?(context, "todos") do
      true
    else
      _other -> false
    end
  end

  defp no_review_todos?(_context), do: false

  defp context_fetch_ready_for?(context, key) do
    context
    |> read_field("context_fetch")
    |> read_field("failures")
    |> case do
      failures when is_list(failures) ->
        not Enum.any?(failures, &(read_field(&1, "key") == key))

      _other ->
        true
    end
  end

  defp no_review_notice_dedupe_key(user_id, trigger) do
    local_date =
      trigger
      |> read_field("local_time")
      |> read_field("date")

    date = local_date || Date.utc_today() |> Date.to_iso8601()
    "proactive:no_open_work_review:#{user_id}:#{date}"
  end

  defp no_review_notice_message(_context) do
    [
      "No open work is waiting for review right now.",
      "I'll keep watching and send something when there's a concrete next move."
    ]
    |> Enum.join(" ")
  end

  defp recent_pushes(user_id, limit) when is_binary(user_id) do
    PushReceipt
    |> where([receipt], receipt.user_id == ^user_id)
    |> where([receipt], receipt.origin_type == "assistant_digest")
    |> order_by([receipt], desc: receipt.inserted_at)
    |> limit(^limit)
    |> Repo.all()
    |> Enum.map(fn receipt ->
      %{
        id: receipt.id,
        dedupe_key: receipt.dedupe_key,
        decision: receipt.decision,
        origin_id: receipt.origin_id,
        inserted_at: receipt.inserted_at
      }
    end)
  end

  defp proactive_trigger(user_id, chat_id, opts) do
    now = Keyword.get(opts, :now) || DateTime.utc_now()
    trigger_type = Keyword.get(opts, :trigger_type, "scheduled_check_in")

    timezone = proactive_timezone_context(user_id, opts, now)

    %{
      "id" =>
        Keyword.get(opts, :trigger_id) ||
          "#{trigger_type}:#{user_id}:#{Date.to_iso8601(DateTime.to_date(now))}",
      "type" => trigger_type,
      "user_id" => user_id,
      "chat_id" => chat_id,
      "now" => DateTime.to_iso8601(DateTime.truncate(now, :second)),
      "local_time" => local_time_context(now, timezone)
    }
  end

  defp proactive_timezone_context(user_id, opts, %DateTime{} = now) do
    cond do
      Keyword.has_key?(opts, :timezone) or Keyword.has_key?(opts, :timezone_name) or
          Keyword.has_key?(opts, :timezone_offset_hours) ->
        timezone_context_from_values(
          Keyword.get(opts, :timezone) || Keyword.get(opts, :timezone_name),
          Keyword.get(opts, :timezone_offset_hours, @default_timezone_offset_hours),
          now
        )

      briefing_schedule = briefing_schedule_from_opts(opts) ->
        timezone_context_from_map(briefing_schedule, now)

      true ->
        user_id
        |> BriefingSchedules.summarize_for_prompt(now: now)
        |> timezone_context_from_map(now)
    end
  end

  defp timezone_context_from_map(summary, %DateTime{} = now) when is_map(summary) do
    timezone_context_from_values(
      read_field(summary, "timezone_name") || read_field(summary, "timezone"),
      read_field(summary, "timezone_offset_hours"),
      now,
      read_field(summary, "local_timezone")
    )
  end

  defp timezone_context_from_map(_summary, %DateTime{} = now) do
    timezone_context_from_values(nil, @default_timezone_offset_hours, now)
  end

  defp timezone_context_from_values(timezone_name, offset_hours, %DateTime{} = now, label \\ nil) do
    normalized_name = Timezones.normalize(to_string(timezone_name || ""))
    configured_offset = normalize_timezone_offset(offset_hours)
    active_offset = Timezones.offset_at(normalized_name, now, configured_offset)

    %{
      timezone_name: normalized_name,
      timezone_offset_hours: active_offset,
      local_timezone: label || Timezones.label(normalized_name, active_offset)
    }
  end

  defp briefing_schedule_from_opts(opts) do
    opts
    |> Keyword.get(:context, %{})
    |> read_field("briefing_schedule")
  end

  defp local_time_context(%DateTime{} = now, timezone) when is_map(timezone) do
    offset_hours = Map.fetch!(timezone, :timezone_offset_hours)
    local_now = DateTime.add(now, offset_hours * 3600, :second)
    local_date = DateTime.to_date(local_now)
    weekday = Date.day_of_week(local_date)

    base = %{
      "date" => Date.to_iso8601(local_date),
      "weekday" => weekday_name(weekday),
      "weekday_number" => weekday,
      "hour" => local_now.hour,
      "day_phase" => day_phase(local_now.hour),
      "weekend" => weekday in [6, 7],
      "weekly_prep_window" => weekday in [6, 7],
      "timezone_offset_hours" => offset_hours,
      "local_timezone" => Map.get(timezone, :local_timezone)
    }

    case Map.get(timezone, :timezone_name) do
      nil -> base
      timezone_name -> Map.put(base, "timezone_name", timezone_name)
    end
  end

  defp day_phase(hour) when hour >= 5 and hour < 11, do: "morning"
  defp day_phase(hour) when hour >= 11 and hour < 17, do: "daytime"
  defp day_phase(hour) when hour >= 17 and hour < 22, do: "evening"
  defp day_phase(_hour), do: "night"

  defp weekday_name(1), do: "Monday"
  defp weekday_name(2), do: "Tuesday"
  defp weekday_name(3), do: "Wednesday"
  defp weekday_name(4), do: "Thursday"
  defp weekday_name(5), do: "Friday"
  defp weekday_name(6), do: "Saturday"
  defp weekday_name(7), do: "Sunday"
  defp weekday_name(_), do: nil

  defp normalize_timezone_offset(value) when is_integer(value) and value >= -12 and value <= 14,
    do: value

  defp normalize_timezone_offset(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, ""} when parsed >= -12 and parsed <= 14 -> parsed
      _ -> @default_timezone_offset_hours
    end
  end

  defp normalize_timezone_offset(_value), do: @default_timezone_offset_hours

  defp read_field(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, atom_field_key(key))
  end

  defp read_field(_map, _key), do: nil

  defp atom_field_key("briefing_schedule"), do: :briefing_schedule
  defp atom_field_key("context_fetch"), do: :context_fetch
  defp atom_field_key("date"), do: :date
  defp atom_field_key("failures"), do: :failures
  defp atom_field_key("key"), do: :key
  defp atom_field_key("local_time"), do: :local_time
  defp atom_field_key("local_timezone"), do: :local_timezone
  defp atom_field_key("timezone"), do: :timezone
  defp atom_field_key("timezone_name"), do: :timezone_name
  defp atom_field_key("timezone_offset_hours"), do: :timezone_offset_hours
  defp atom_field_key("todos"), do: :todos
  defp atom_field_key(_key), do: :unknown

  defp plan_dedupe_key(_user_id, %{"dedupe_key" => key}, _trigger)
       when is_binary(key) and key != "" do
    key
  end

  defp plan_dedupe_key(user_id, _plan, %{"id" => trigger_id}) do
    "assistant_digest:#{user_id}:#{trigger_id}"
  end

  defp stringify_result(result) when is_map(result) do
    Map.new(result, fn {key, value} -> {to_string(key), value} end)
  end

  defp record_proactive_decision(user_id, dedupe_key, plan, trigger, opts) do
    result = Map.get(opts, :result, %{})

    attrs = %{
      user_id: user_id,
      surface: "telegram",
      event_type: Map.fetch!(opts, :event_type),
      status: Map.fetch!(opts, :status),
      source_evidence: %{
        trigger: trigger,
        dedupe_key: dedupe_key || Map.get(plan, "dedupe_key"),
        todo_ids: Map.get(plan, "todo_ids", [])
      },
      model_summary: Map.get(plan, "summary"),
      result_object_refs: %{
        dedupe_key: dedupe_key || Map.get(plan, "dedupe_key"),
        conversation_id: Map.get(result, :conversation_id),
        turn_id: Map.get(result, :turn_id),
        message_id: Map.get(result, :message_id)
      },
      metadata: %{
        decision: Map.get(plan, "decision"),
        message_class: Map.get(plan, "message_class"),
        interrupt_now: Map.get(plan, "interrupt_now"),
        urgency: Map.get(plan, "urgency")
      }
    }

    case ActionLedger.record(attrs) do
      {:ok, _action} -> :ok
      {:error, _reason} -> :ok
    end
  rescue
    _error -> :ok
  end
end
