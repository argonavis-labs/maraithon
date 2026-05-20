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
  alias Maraithon.ConnectedAccounts
  alias Maraithon.Repo
  alias Maraithon.TelegramAssistant
  alias Maraithon.TelegramAssistant.{Context, PushBroker, PushReceipt, TodoActions}
  alias Maraithon.TelegramConversations.Conversation
  alias Maraithon.Todos

  @recent_push_limit 8
  @default_due_batch_size 25

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

    AssistantHarness.proactive_plan(payload, opts)
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

    case plan_check_in(user_id, Keyword.put(opts, :chat_id, chat_id)) do
      {:ok, %{"decision" => "send_now"} = plan} ->
        deliver_plan(user_id, chat_id, plan, opts)

      {:ok, %{"decision" => "hold"} = plan} ->
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

  defp deliver_plan_now(user_id, chat_id, plan, trigger, dedupe_key) do
    candidate = %{
      user_id: user_id,
      chat_id: chat_id,
      origin_type: "assistant_digest",
      origin_id: Map.get(trigger, "id"),
      dedupe_key: dedupe_key,
      title: "Maraithon check-in",
      body: Map.fetch!(plan, "assistant_message"),
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
      body: Map.fetch!(plan, "assistant_message"),
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

    %{
      "id" =>
        Keyword.get(opts, :trigger_id) ||
          "#{trigger_type}:#{user_id}:#{Date.to_iso8601(DateTime.to_date(now))}",
      "type" => trigger_type,
      "user_id" => user_id,
      "chat_id" => chat_id,
      "now" => DateTime.to_iso8601(DateTime.truncate(now, :second))
    }
  end

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
