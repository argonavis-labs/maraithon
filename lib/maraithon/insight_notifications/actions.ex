defmodule Maraithon.InsightNotifications.Actions do
  @moduledoc """
  Telegram-native action proposals and execution for actionable insights.
  """

  import Ecto.Query

  alias Maraithon.Connectors.Telegram
  alias Maraithon.InsightNotifications.Delivery
  alias Maraithon.Insights
  alias Maraithon.Insights.Insight
  alias Maraithon.LLM
  alias Maraithon.OperatorMemory
  alias Maraithon.PreferenceMemory
  alias Maraithon.Repo
  alias Maraithon.Todos
  alias Maraithon.Tools
  alias Maraithon.UserMemory

  require Logger

  @callback_prefix "insact"
  @max_preview_length 900

  def telegram_payload(%Delivery{} = delivery) do
    delivery = ensure_insight_preloaded(delivery)

    %{
      text: render_message(delivery),
      reply_markup: build_reply_markup(delivery)
    }
  end

  def fetch_delivery_for_chat(delivery_id, chat_id) do
    fetch_delivery(delivery_id, chat_id)
  end

  def find_delivery_by_provider_message(chat_id, provider_message_id)
      when is_binary(chat_id) and is_binary(provider_message_id) do
    delivery =
      Delivery
      |> where([d], d.channel == "telegram" and d.destination == ^chat_id)
      |> where([d], d.provider_message_id == ^provider_message_id)
      |> preload(:insight)
      |> Repo.one()

    case delivery do
      %Delivery{} = delivery -> {:ok, delivery}
      nil -> {:error, :delivery_not_found}
    end
  end

  def find_delivery_by_provider_message(_chat_id, _provider_message_id),
    do: {:error, :delivery_not_found}

  def perform_action(%Delivery{} = delivery, action) when is_binary(action) do
    delivery = ensure_insight_preloaded(delivery)
    dispatch_action(action, delivery)
  end

  def action_state_for_delivery(%Delivery{} = delivery), do: action_state(delivery)

  def handle_callback(data) when is_map(data) do
    callback = read_string(data, "data")
    callback_id = read_string(data, "callback_id")
    chat_id = read_id_string(data, "chat_id")
    message_id = read_string(data, "message_id", read_integer(data, "message_id"))

    with {:ok, delivery_id, action} <- parse_callback(callback),
         {:ok, delivery} <- fetch_delivery(delivery_id, chat_id),
         {:ok, delivery, notice} <- dispatch_action(action, delivery),
         :ok <- refresh_telegram_message(delivery, chat_id, message_id) do
      answer_callback(callback_id, notice)
      :ok
    else
      {:error, :unsupported_callback} ->
        {:error, :unsupported_callback}

      {:error, reason} ->
        answer_callback(callback_id, callback_error_text(reason))
        :ok
    end
  end

  def handle_callback(_), do: {:error, :unsupported_callback}

  def render_message(%Delivery{} = delivery) do
    delivery = ensure_insight_preloaded(delivery)
    insight = delivery.insight
    metadata = insight.metadata || %{}
    action_state = action_state(delivery)
    change_summary = metadata |> read_map("attention") |> read_string("change_summary")

    action_state_text = render_action_state(action_state)
    header = if monitor_insight?(insight), do: "Watching this", else: "This requires action"
    action_label = if monitor_insight?(insight), do: "Watch for", else: "Suggested reply"
    reply_text = suggested_reply(insight, metadata)
    details_text = details_text(insight, metadata)
    action_text = action_list_text(insight, metadata)

    change_summary_text =
      case change_summary do
        nil -> ""
        value -> "\n\n<b>What changed:</b> #{safe(value)}"
      end

    """
    <b>#{header}</b>
    <b>#{safe(insight.title)}</b>

    <b>What it is:</b> #{safe(insight.summary)}
    #{details_text}#{change_summary_text}

    <b>#{action_label}:</b>
    #{safe(reply_text)}

    <b>Actions:</b>
    #{action_text}#{action_state_text}
    """
    |> String.trim()
  end

  def build_reply_markup(%Delivery{} = delivery) do
    callback_helpful = "insfb:#{delivery.id}:h"
    callback_not_helpful = "insfb:#{delivery.id}:n"

    rows =
      delivery
      |> action_rows()
      |> Kernel.++([
        [
          %{"text" => "Helpful", "callback_data" => callback_helpful},
          %{"text" => "Not Helpful", "callback_data" => callback_not_helpful}
        ]
      ])

    %{"inline_keyboard" => rows}
  end

  defp action_rows(%Delivery{} = delivery) do
    case action_state(delivery) do
      %{"status" => "drafted"} ->
        [
          [
            %{"text" => "Send Now", "callback_data" => callback_data(delivery.id, "send")},
            %{"text" => "Regenerate", "callback_data" => callback_data(delivery.id, "regenerate")}
          ],
          [
            %{"text" => "Cancel", "callback_data" => callback_data(delivery.id, "cancel")}
          ]
        ]

      %{"status" => "executed"} ->
        []

      %{"status" => "dismissed"} ->
        []

      %{"status" => "snoozed"} ->
        []

      _ ->
        base_rows =
          if monitor_insight?(delivery.insight) do
            []
          else
            completion_button =
              if ackable_insight?(delivery.insight) do
                %{"text" => "Ack", "callback_data" => callback_data(delivery.id, "ack")}
              else
                %{"text" => "Mark Done", "callback_data" => callback_data(delivery.id, "done")}
              end

            case primary_action(delivery.insight) do
              nil ->
                [
                  [completion_button]
                ]

              %{label: label, callback_action: callback_action} ->
                [
                  [
                    %{
                      "text" => label,
                      "callback_data" => callback_data(delivery.id, callback_action)
                    },
                    completion_button
                  ]
                ]
            end
          end

        base_rows ++
          [
            [
              %{"text" => "Snooze 4h", "callback_data" => callback_data(delivery.id, "snooze")},
              %{"text" => "Dismiss", "callback_data" => callback_data(delivery.id, "dismiss")}
            ]
          ]
    end
  end

  defp dispatch_action("draft", %Delivery{} = delivery), do: draft_action(delivery)
  defp dispatch_action("regenerate", %Delivery{} = delivery), do: draft_action(delivery)
  defp dispatch_action("send", %Delivery{} = delivery), do: execute_action(delivery)
  defp dispatch_action("cancel", %Delivery{} = delivery), do: cancel_action(delivery)
  defp dispatch_action("ack", %Delivery{} = delivery), do: acknowledge_insight(delivery)
  defp dispatch_action("done", %Delivery{} = delivery), do: mark_done(delivery)
  defp dispatch_action("dismiss", %Delivery{} = delivery), do: dismiss_insight(delivery)
  defp dispatch_action("snooze", %Delivery{} = delivery), do: snooze_insight(delivery)
  defp dispatch_action(_action, _delivery), do: {:error, :unsupported_action}

  defp draft_action(%Delivery{} = delivery) do
    insight = delivery.insight

    with {:ok, action_spec} <- build_action_spec(insight),
         {:ok, draft} <- generate_draft(action_spec, insight),
         {:ok, delivery} <- put_action_state(delivery, %{"status" => "drafted", "spec" => draft}) do
      {:ok, delivery, "#{read_string(action_spec, "notice_label", "Action")} draft ready"}
    end
  end

  defp execute_action(%Delivery{} = delivery) do
    with %{"status" => "drafted", "spec" => spec} <- action_state(delivery),
         {:ok, result} <- run_action(spec, delivery.insight),
         {:ok, delivery} <-
           put_action_state(delivery, %{
             "status" => "executed",
             "spec" => spec,
             "result" => stringify_map_keys(result),
             "executed_at" =>
               DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
           }),
         {:ok, _insight} <- acknowledge_with_result(delivery.insight, spec, result) do
      {:ok, delivery, execution_notice(spec)}
    else
      nil ->
        {:error, :draft_not_ready}

      %{} ->
        {:error, :draft_not_ready}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp cancel_action(%Delivery{} = delivery) do
    with {:ok, delivery} <- put_action_state(delivery, %{"status" => "cancelled"}) do
      {:ok, delivery, "Draft cleared"}
    end
  end

  defp mark_done(%Delivery{} = delivery) do
    with {:ok, delivery} <-
           put_action_state(delivery, %{"status" => "executed", "kind" => "manual_complete"}),
         {:ok, _insight} <-
           acknowledge_with_result(
             delivery.insight,
             %{"kind" => "manual_complete"},
             %{"status" => "marked_complete_in_telegram"}
           ) do
      {:ok, delivery, "Marked complete"}
    end
  end

  defp acknowledge_insight(%Delivery{} = delivery) do
    with {:ok, _insight} <- Insights.acknowledge(delivery.user_id, delivery.insight_id),
         {:ok, delivery} <-
           put_action_state(delivery, %{"status" => "executed", "kind" => "manual_ack"}) do
      {:ok, delivery, "Acknowledged"}
    end
  end

  defp dismiss_insight(%Delivery{} = delivery) do
    with {:ok, _insight} <- Insights.dismiss(delivery.user_id, delivery.insight_id),
         {:ok, delivery} <- put_action_state(delivery, %{"status" => "dismissed"}) do
      {:ok, delivery, "Insight dismissed"}
    end
  end

  defp snooze_insight(%Delivery{} = delivery) do
    snooze_until = DateTime.add(DateTime.utc_now(), 4, :hour)

    with {:ok, _insight} <- Insights.snooze(delivery.user_id, delivery.insight_id, snooze_until),
         {:ok, delivery} <-
           put_action_state(delivery, %{
             "status" => "snoozed",
             "until" => DateTime.to_iso8601(snooze_until)
           }) do
      {:ok, delivery, "Snoozed for 4 hours"}
    end
  end

  defp build_action_spec(%Insight{} = insight) do
    metadata = insight.metadata || %{}

    cond do
      insight.source == "gmail" ->
        to = gmail_target_address(insight, metadata)

        if blank?(to) do
          {:error, :action_not_available}
        else
          {:ok,
           %{
             "kind" => "gmail_reply",
             "notice_label" => "Email",
             "account" => read_string(metadata, "account"),
             "to" => to,
             "subject" =>
               normalize_reply_subject(read_string(metadata, "subject", insight.title)),
             "thread_id" => read_string(metadata, "thread_id"),
             "reply_to_message_id" => insight.source_id,
             "person" => record_value(metadata, "person"),
             "context" => build_context(insight, metadata),
             "operator_needs" => operator_needs(insight, metadata),
             "suggested_reply_points" => read_string_list(metadata, "suggested_reply_points"),
             "draft_plan" => draft_plan(insight, metadata),
             "voice_guidance" => operator_voice_guidance(insight.user_id)
           }}
        end

      insight.source == "slack" ->
        team_id = read_string(metadata, "team_id")
        channel_id = read_string(metadata, "channel_id")
        thread_ts = read_string(metadata, "thread_ts") || slack_source_ts(insight.source_id)

        if blank?(team_id) or blank?(channel_id) do
          {:error, :action_not_available}
        else
          {:ok,
           %{
             "kind" => "slack_reply",
             "notice_label" => "Slack",
             "team_id" => team_id,
             "channel" => channel_id,
             "thread_ts" => thread_ts,
             "person" => record_value(metadata, "person"),
             "context" => build_context(insight, metadata),
             "operator_needs" => operator_needs(insight, metadata),
             "suggested_reply_points" => read_string_list(metadata, "suggested_reply_points"),
             "draft_plan" => draft_plan(insight, metadata),
             "voice_guidance" => operator_voice_guidance(insight.user_id)
           }}
        end

      true ->
        {:error, :action_not_available}
    end
  end

  defp generate_draft(%{"kind" => "gmail_reply"} = spec, %Insight{} = insight) do
    fallback = %{
      "kind" => "gmail_reply",
      "account" => spec["account"],
      "to" => spec["to"],
      "subject" => spec["subject"],
      "body" => fallback_email_body(spec, insight),
      "thread_id" => spec["thread_id"],
      "reply_to_message_id" => spec["reply_to_message_id"]
    }

    prompt = email_prompt(spec, insight)

    case llm_json(prompt) do
      {:ok, %{"subject" => subject, "body" => body}}
      when is_binary(subject) and is_binary(body) ->
        {:ok,
         fallback
         |> Map.put("subject", String.trim(subject))
         |> Map.put("body", String.trim(body))}

      _ ->
        {:ok, fallback}
    end
  end

  defp generate_draft(%{"kind" => "slack_reply"} = spec, %Insight{} = insight) do
    fallback = %{
      "kind" => "slack_reply",
      "team_id" => spec["team_id"],
      "channel" => spec["channel"],
      "thread_ts" => spec["thread_ts"],
      "text" => fallback_slack_text(spec, insight)
    }

    prompt = slack_prompt(spec, insight)

    case llm_json(prompt) do
      {:ok, %{"text" => text}} when is_binary(text) ->
        {:ok, Map.put(fallback, "text", String.trim(text))}

      _ ->
        {:ok, fallback}
    end
  end

  defp run_action(%{"kind" => "gmail_reply"} = spec, %Insight{} = insight) do
    args = %{
      "user_id" => insight.user_id,
      "account" => read_string(spec, "account"),
      "to" => read_string(spec, "to"),
      "subject" => read_string(spec, "subject"),
      "body" => read_string(spec, "body"),
      "thread_id" => read_string(spec, "thread_id"),
      "reply_to_message_id" => read_string(spec, "reply_to_message_id")
    }

    Tools.execute("gmail_send_message", compact_map(args))
  end

  defp run_action(%{"kind" => "slack_reply"} = spec, %Insight{} = insight) do
    args = %{
      "user_id" => insight.user_id,
      "team_id" => read_string(spec, "team_id"),
      "channel" => read_string(spec, "channel"),
      "text" => read_string(spec, "text"),
      "thread_ts" => read_string(spec, "thread_ts")
    }

    Tools.execute("slack_post_message", compact_map(args))
  end

  defp run_action(_spec, _insight), do: {:error, :action_not_available}

  defp acknowledge_with_result(%Insight{} = insight, spec, result) do
    merged_metadata =
      (insight.metadata || %{})
      |> Map.put(
        "telegram_resolution",
        compact_map(%{
          "kind" => read_string(spec, "kind"),
          "completed_at" =>
            DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
          "result" => stringify_map_keys(result)
        })
      )

    insight
    |> Ecto.Changeset.change(
      status: "acknowledged",
      snoozed_until: nil,
      metadata: merged_metadata
    )
    |> Repo.update()
    |> case do
      {:ok, updated} ->
        case Todos.sync_from_insight(updated) do
          {:ok, _todo} -> {:ok, updated}
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp put_action_state(%Delivery{} = delivery, action_state) when is_map(action_state) do
    metadata =
      delivery.metadata || %{}

    updated =
      delivery
      |> Ecto.Changeset.change(
        metadata: Map.put(metadata, "telegram_action", stringify_map_keys(action_state))
      )
      |> Repo.update()

    case updated do
      {:ok, delivery} -> {:ok, Repo.preload(delivery, :insight)}
      error -> error
    end
  end

  defp fetch_delivery(delivery_id, chat_id) when is_binary(delivery_id) do
    delivery =
      Delivery
      |> where([d], d.id == ^delivery_id)
      |> preload([:insight])
      |> Repo.one()

    cond do
      is_nil(delivery) ->
        {:error, :delivery_not_found}

      to_string(delivery.destination) != to_string(chat_id) ->
        {:error, :unauthorized_chat}

      true ->
        {:ok, delivery}
    end
  end

  defp fetch_delivery(_delivery_id, _chat_id), do: {:error, :delivery_not_found}

  defp refresh_telegram_message(%Delivery{} = delivery, chat_id, message_id) do
    payload = telegram_payload(delivery)
    module = telegram_module()

    cond do
      function_exported?(module, :edit_message_text, 4) and present?(message_id) ->
        case module.edit_message_text(chat_id, message_id, payload.text,
               parse_mode: "HTML",
               reply_markup: payload.reply_markup
             ) do
          {:ok, _} -> :ok
          {:error, reason} -> {:error, {:telegram_edit_failed, reason}}
        end

      function_exported?(module, :send_message, 3) ->
        case module.send_message(chat_id, payload.text,
               parse_mode: "HTML",
               reply_markup: payload.reply_markup
             ) do
          {:ok, _} -> :ok
          {:error, reason} -> {:error, {:telegram_send_failed, reason}}
        end

      true ->
        {:error, :telegram_module_missing}
    end
  end

  defp render_action_state(nil), do: ""

  defp render_action_state(%{"status" => "drafted"} = state) do
    spec = read_map(state, "spec")

    case read_string(spec, "kind") do
      "gmail_reply" ->
        body = read_string(spec, "body")
        subject = read_string(spec, "subject")

        "\n\n<b>Email draft ready</b>\n<b>Subject:</b> #{safe(subject)}\n<pre>#{safe(truncate(body, @max_preview_length))}</pre>"

      "slack_reply" ->
        text = read_string(spec, "text")
        "\n\n<b>Slack draft ready</b>\n<pre>#{safe(truncate(text, @max_preview_length))}</pre>"

      _ ->
        ""
    end
  end

  defp render_action_state(%{"status" => "executed"} = state) do
    result = read_map(state, "result")
    kind = read_string(state, "kind", read_string(read_map(state, "spec"), "kind"))
    executed_at = read_string(state, "executed_at")

    details =
      case kind do
        "gmail_reply" ->
          "Sent via Gmail (message #{safe(read_string(result, "message_id", "unknown"))})."

        "slack_reply" ->
          "Sent in Slack (ts #{safe(read_string(result, "ts", "unknown"))})."

        "manual_complete" ->
          "Marked complete from Telegram."

        "manual_ack" ->
          "Acknowledged from Telegram."

        _ ->
          "Completed."
      end

    executed_line =
      if present?(executed_at), do: "\nAt: #{safe(executed_at)}", else: ""

    "\n\n<b>Completed</b>\n#{details}#{executed_line}"
  end

  defp render_action_state(%{"status" => "snoozed"} = state) do
    until_text = read_string(state, "until")
    "\n\n<b>Snoozed</b>\nUntil: #{safe(until_text)}"
  end

  defp render_action_state(%{"status" => "dismissed"}), do: "\n\n<b>Dismissed</b>"
  defp render_action_state(%{"status" => "cancelled"}), do: ""
  defp render_action_state(_), do: ""

  defp action_state(%Delivery{} = delivery) do
    case delivery.metadata do
      %{"telegram_action" => %{} = state} -> state
      _ -> nil
    end
  end

  defp details_text(%Insight{} = insight, metadata) do
    [
      needed_detail(insight),
      due_detail(insight),
      source_detail(insight, metadata)
    ]
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> ""
      details -> "\n#{Enum.map_join(details, "\n", &safe/1)}"
    end
  end

  defp due_detail(%Insight{due_at: %DateTime{} = due_at}) do
    "Due: #{Calendar.strftime(due_at, "%Y-%m-%d %H:%M UTC")}"
  end

  defp due_detail(%Insight{}), do: nil

  defp needed_detail(%Insight{recommended_action: action}) when is_binary(action) do
    "Needed: #{action}"
  end

  defp needed_detail(%Insight{}), do: nil

  defp source_detail(%Insight{} = insight, metadata) do
    case source_label(insight, metadata) do
      nil -> nil
      value -> "Source: #{value}"
    end
  end

  defp suggested_reply(%Insight{} = insight, metadata) do
    explicit =
      read_string(metadata, "suggested_reply") ||
        read_string(metadata, "draft_reply")

    explicit ||
      if monitor_insight?(insight) do
        insight.recommended_action
      else
        suggested_action_reply(insight, metadata)
      end
  end

  defp suggested_action_reply(%Insight{} = insight, metadata) do
    person =
      record_value(metadata, "person") || first_email_name(read_string(metadata, "to")) || "there"

    points = read_string_list(metadata, "suggested_reply_points")

    cond do
      points != [] ->
        "#{email_greeting(person, nil)} #{Enum.join(points, " ")}"

      insight.source == "gmail" ->
        "#{email_greeting(person, nil)} I owe you the follow-up here. I’m confirming the current status now and will send either the promised update or a concrete ETA in this thread."

      insight.source == "slack" ->
        "I owe you the follow-up here. I’m checking the current status and will reply with either the update or a concrete ETA."

      true ->
        insight.recommended_action
    end
  end

  defp action_list_text(%Insight{} = insight, metadata) do
    insight
    |> action_items(metadata)
    |> Enum.map_join("\n", fn item -> "- #{safe(item)}" end)
  end

  defp action_items(%Insight{} = insight, metadata) do
    base =
      if monitor_insight?(insight) do
        [
          "Keep watching for a blocker, direct ask, or stall.",
          "Mark done if the loop is already closed.",
          "Dismiss if this is no longer relevant."
        ]
      else
        [
          draft_action_item(insight),
          ready_action_item(insight),
          eta_action_item(insight, metadata)
        ]
      end

    base
    |> Enum.reject(&blank?/1)
    |> Enum.uniq()
    |> Enum.take(3)
  end

  defp draft_action_item(%Insight{source: "gmail"}),
    do: "Tap Draft Email to generate the in-thread reply."

  defp draft_action_item(%Insight{source: "slack"}),
    do: "Tap Draft Slack to generate the thread reply."

  defp draft_action_item(%Insight{}), do: "Take the recommended action."

  defp ready_action_item(%Insight{source: "gmail"}),
    do: "If the artifact or update is ready, send it in the same email thread."

  defp ready_action_item(%Insight{source: "slack"}),
    do: "If the answer is ready, send it in the same Slack thread."

  defp ready_action_item(%Insight{}), do: nil

  defp eta_action_item(%Insight{} = insight, metadata) do
    due =
      case insight.due_at do
        %DateTime{} = due_at -> Calendar.strftime(due_at, "%Y-%m-%d %H:%M UTC")
        _ -> nil
      end

    if due do
      "If it is not ready, reply with the next concrete ETA before #{due}."
    else
      person = record_value(metadata, "person") || "the other person"
      "If it is not ready, give #{person} a specific ETA and next step."
    end
  end

  defp primary_action(%Insight{} = insight) do
    if ackable_insight?(insight) or monitor_insight?(insight) do
      nil
    else
      case insight.source do
        "gmail" -> %{label: "Draft Email", callback_action: "draft"}
        "slack" -> %{label: "Draft Slack", callback_action: "draft"}
        _ -> nil
      end
    end
  end

  defp ackable_insight?(%Insight{} = insight) do
    insight.category == "important_fyi" or
      read_boolean(insight.metadata || %{}, "ackable", false)
  end

  defp monitor_insight?(%Insight{} = insight), do: insight.attention_mode == "monitor"

  defp parse_callback(value) when is_binary(value) do
    case Regex.run(~r/^#{@callback_prefix}:([0-9a-f\-]{36}):([a-z_]+)$/i, value,
           capture: :all_but_first
         ) do
      [delivery_id, action] -> {:ok, delivery_id, String.downcase(action)}
      _ -> {:error, :unsupported_callback}
    end
  end

  defp parse_callback(_), do: {:error, :unsupported_callback}

  defp callback_data(delivery_id, action), do: "#{@callback_prefix}:#{delivery_id}:#{action}"

  defp llm_json(prompt) when is_binary(prompt) do
    params = %{
      "messages" => [%{"role" => "user", "content" => prompt}],
      "max_tokens" => 500,
      "temperature" => 0.2,
      "reasoning_effort" => "low"
    }

    with {:ok, response} <- LLM.complete(params),
         {:ok, parsed} <- decode_json(response.content) do
      {:ok, parsed}
    else
      {:error, reason} ->
        Logger.warning("Telegram insight draft generation failed", reason: inspect(reason))
        {:error, reason}
    end
  end

  defp decode_json(content) when is_binary(content) do
    trimmed =
      content
      |> String.trim()
      |> String.trim_leading("```json")
      |> String.trim_leading("```")
      |> String.trim_trailing("```")
      |> String.trim()

    case Jason.decode(trimmed) do
      {:ok, %{} = data} -> {:ok, data}
      _ -> {:error, :invalid_json}
    end
  end

  defp email_prompt(spec, insight) do
    memory = draft_memory_context(insight.user_id)
    voice_guidance = operator_voice_guidance(insight.user_id)

    """
    Write a concise email reply as Kent.

    Return ONLY valid JSON:
    {"subject":"...","body":"..."}

    Constraints:
    - Write in Kent's first-person voice, not as Maraithon or an assistant.
    - Be concrete, direct, calm, and brief.
    - Avoid corporate filler, over-apologizing, and vague "circling back" phrasing.
    - Include only the next step, owner, and ETA that the source evidence supports.
    - Do not claim attachments, delivery, or completed work unless explicitly proven.
    - If the promised artifact is not clearly available, send an honest progress update plus a firm ETA.
    - Use draft_plan and suggested_reply_points as drafting instructions, not text to quote.
    - If operator_needs are present, ask for or name the missing detail instead of inventing it.
    - Close the loop in one message.
    - Follow durable operator style and action preferences when they are relevant.

    Insight JSON:
    #{Jason.encode!(draft_prompt_payload(spec, insight))}

    Kent voice guidance JSON:
    #{Jason.encode!(voice_guidance)}

    Draft memory JSON:
    #{Jason.encode!(memory)}
    """
  end

  defp slack_prompt(spec, insight) do
    memory = draft_memory_context(insight.user_id)
    voice_guidance = operator_voice_guidance(insight.user_id)

    """
    Write a concise Slack reply as Kent for an unresolved follow-through item.

    Return ONLY valid JSON:
    {"text":"..."}

    Constraints:
    - Write in Kent's first-person voice, not as Maraithon or an assistant.
    - Be direct, short, calm, and useful.
    - Avoid corporate filler, over-apologizing, and vague status language.
    - Include owner / next step / ETA when appropriate.
    - Do not claim work is already done unless proven.
    - Use draft_plan and suggested_reply_points as drafting instructions, not text to quote.
    - If operator_needs are present, ask for or name the missing detail instead of inventing it.
    - Follow durable operator style and action preferences when they are relevant.

    Insight JSON:
    #{Jason.encode!(draft_prompt_payload(spec, insight))}

    Kent voice guidance JSON:
    #{Jason.encode!(voice_guidance)}

    Draft memory JSON:
    #{Jason.encode!(memory)}
    """
  end

  defp draft_memory_context(user_id) when is_binary(user_id) do
    %{
      preference_memory: PreferenceMemory.prompt_context(user_id),
      operator_summaries: OperatorMemory.summaries_for_prompt(user_id),
      user_memory_profile: UserMemory.prompt_context(user_id)
    }
  end

  defp draft_memory_context(_user_id) do
    %{
      preference_memory: PreferenceMemory.prompt_context(nil),
      operator_summaries: [],
      user_memory_profile: UserMemory.prompt_context(nil)
    }
  end

  defp fallback_email_body(spec, insight) do
    greeting = email_greeting(spec["person"], spec["to"])
    needs_line = fallback_needs_line(read_string_list(spec, "operator_needs"))

    reply_points_line =
      fallback_reply_points_line(read_string_list(spec, "suggested_reply_points"))

    """
    #{greeting}

    Thanks for the nudge. #{fallback_context_sentence(insight)}

    #{reply_points_line}
    #{needs_line}

    I don't want to leave this open. I'll send the remaining detail and a concrete ETA shortly.

    Best,
    #{sender_name(insight.user_id)}
    """
    |> String.trim()
  end

  defp fallback_slack_text(spec, insight) do
    reply_points = read_string_list(spec, "suggested_reply_points")

    [
      "On it.",
      fallback_context_sentence(insight),
      fallback_reply_points_sentence(reply_points),
      "I'll close the loop with owner, next step, and exact ETA shortly."
    ]
    |> Enum.reject(&blank?/1)
    |> Enum.join(" ")
  end

  defp execution_notice(%{"kind" => "gmail_reply"}), do: "Email sent"
  defp execution_notice(%{"kind" => "slack_reply"}), do: "Slack reply sent"
  defp execution_notice(_), do: "Action completed"

  defp callback_error_text(:action_not_available), do: "Action not available for this insight"
  defp callback_error_text(:draft_not_ready), do: "Generate a draft first"
  defp callback_error_text(:delivery_not_found), do: "Insight delivery not found"
  defp callback_error_text(:unauthorized_chat), do: "This action is not authorized in this chat"
  defp callback_error_text(:unsupported_action), do: "Unsupported action"

  defp callback_error_text({:telegram_edit_failed, _}),
    do: "Action ran, but Telegram refresh failed"

  defp callback_error_text("google_account_reauth_required"), do: "Reconnect Google in Maraithon"
  defp callback_error_text("slack_workspace_reauth_required"), do: "Reconnect Slack in Maraithon"
  defp callback_error_text("google_account_not_connected"), do: "Connect Google first"
  defp callback_error_text("slack_workspace_not_connected"), do: "Connect Slack first"
  defp callback_error_text(reason) when is_binary(reason), do: truncate(reason, 60)
  defp callback_error_text(_), do: "Action failed"

  defp answer_callback(nil, _text), do: :ok

  defp answer_callback(callback_id, text) do
    _ = telegram_module().answer_callback_query(callback_id, text: text)
    :ok
  end

  defp gmail_target_address(insight, metadata) do
    case insight.category do
      "reply_urgent" -> read_string(metadata, "from")
      _ -> read_string(metadata, "to") || read_string(metadata, "from")
    end
  end

  defp source_label(%Insight{} = insight, metadata) do
    account =
      read_string(metadata, "account") ||
        read_string(metadata, "team_id")

    cond do
      present?(account) -> "#{insight.source} · #{account}"
      true -> insight.source
    end
  end

  defp build_context(%Insight{}, metadata) do
    compact_map(%{
      "record" => read_map(metadata, "record"),
      "context_brief" => read_string(metadata, "context_brief"),
      "signals" => read_string_list(metadata, "signals"),
      "evidence" => record_value_list(metadata, "evidence"),
      "coverage_evidence" =>
        conversation_context(metadata) |> read_string_list("coverage_evidence"),
      "completion_evidence" =>
        conversation_context(metadata) |> read_string_list("completion_evidence"),
      "conversation_context" => conversation_context(metadata),
      "person" => record_value(metadata, "person"),
      "commitment" => record_value(metadata, "commitment"),
      "next_action" => record_value(metadata, "next_action"),
      "account" => read_string(metadata, "account"),
      "channel_name" => read_string(metadata, "channel_name"),
      "missing_inputs" => read_string_list(metadata, "missing_inputs"),
      "suggested_reply_points" => read_string_list(metadata, "suggested_reply_points"),
      "draft_plan" => read_string(metadata, "draft_plan")
    })
  end

  defp draft_prompt_payload(spec, %Insight{} = insight) do
    compact_map(%{
      "title" => insight.title,
      "summary" => insight.summary,
      "recommended_action" => insight.recommended_action,
      "source" => insight.source,
      "category" => insight.category,
      "priority" => insight.priority,
      "confidence" => insight.confidence,
      "attention_mode" => insight.attention_mode,
      "person" => spec["person"],
      "context" => spec["context"],
      "to" => spec["to"],
      "subject" => spec["subject"],
      "operator_needs" => read_string_list(spec, "operator_needs"),
      "suggested_reply_points" => read_string_list(spec, "suggested_reply_points"),
      "draft_plan" => read_string(spec, "draft_plan")
    })
  end

  defp operator_needs(%Insight{} = insight, metadata) do
    explicit = read_string_list(metadata, "missing_inputs")
    record = read_map(metadata, "record")
    context = conversation_context(metadata)

    inferred =
      []
      |> maybe_append(
        "ETA or delivery timing to give #{record_value(metadata, "person") || "them"}",
        eta_needed?(insight, metadata, record)
      )
      |> maybe_append(
        "Final owner if the thread is moving but ownership is unclear",
        read_string(context, "ownership_state") in ["shared_owner", "unknown"]
      )
      |> maybe_append(
        "Artifact or concrete answer if the source evidence does not prove it is ready",
        artifact_needed?(insight, metadata, record)
      )

    (explicit ++ inferred)
    |> Enum.uniq()
    |> Enum.take(3)
  end

  defp draft_plan(%Insight{} = insight, metadata) do
    explicit = read_string(metadata, "draft_plan")
    record = read_map(metadata, "record")
    context = conversation_context(metadata)

    explicit ||
      cond do
        read_string(context, "notification_posture") == "heads_up" ->
          "Acknowledge the thread is moving, confirm whether Kent still owns the final loop, and avoid implying nobody responded."

        insight.source == "gmail" and read_string(record, "commitment") != nil ->
          "Reply in-thread as Kent with the concrete next step, owner, and ETA."

        insight.source == "slack" ->
          "Reply in the Slack thread as Kent with the shortest useful status, owner, and ETA."

        true ->
          nil
      end
  end

  defp conversation_context(metadata) when is_map(metadata) do
    read_map(metadata, "conversation_context")
  end

  defp conversation_context(_metadata), do: %{}

  defp eta_needed?(%Insight{} = insight, metadata, record) do
    text =
      [
        insight.recommended_action,
        insight.summary,
        read_string(metadata, "why_now"),
        read_string(record, "next_action")
      ]
      |> Enum.reject(&blank?/1)
      |> Enum.join(" ")
      |> String.downcase()

    String.contains?(text, ["eta", "deadline", "today", "tomorrow", "when"]) and
      blank?(read_string(record, "deadline")) and
      is_nil(insight.due_at)
  end

  defp artifact_needed?(%Insight{} = insight, metadata, record) do
    text =
      [
        insight.title,
        insight.summary,
        insight.recommended_action,
        read_string(record, "commitment"),
        read_string(metadata, "context_brief")
      ]
      |> Enum.reject(&blank?/1)
      |> Enum.join(" ")
      |> String.downcase()

    String.contains?(text, ["send", "share", "deck", "doc", "artifact", "proposal", "answer"]) and
      read_string_list(record, "completion_evidence") == [] and
      read_string_list(metadata, "completion_evidence") == []
  end

  defp operator_voice_guidance(user_id) do
    %{
      "speaker" => speaker_name(user_id),
      "write_as" => "Kent in first person",
      "style_rules" => [
        "short and direct",
        "specific next step over general reassurance",
        "low-apology unless Kent clearly caused the delay",
        "no assistant or Maraithon framing",
        "do not invent facts, attachments, completion, or availability",
        "use a concrete ETA only when evidence or Kent supplied one"
      ]
    }
  end

  defp fallback_context_sentence(%Insight{} = insight), do: insight.summary

  defp fallback_reply_points_line([]), do: nil

  defp fallback_reply_points_line(points) when is_list(points) do
    "Useful reply points: #{Enum.join(points, " ")}"
  end

  defp fallback_reply_points_sentence([]), do: nil

  defp fallback_reply_points_sentence(points) when is_list(points) do
    points
    |> Enum.take(2)
    |> Enum.join(" ")
  end

  defp fallback_needs_line([]), do: "I am checking the final detail now."

  defp fallback_needs_line(needs) when is_list(needs) do
    "I am checking: #{Enum.join(needs, "; ")}."
  end

  defp slack_source_ts("slack:" <> rest) do
    rest
    |> String.split(":")
    |> List.last()
    |> normalize_blank()
  end

  defp slack_source_ts(_), do: nil

  defp email_greeting(person, to_field) do
    candidate =
      normalize_blank(person) ||
        normalize_blank(first_email_name(to_field)) ||
        "there"

    "Hi #{candidate},"
  end

  defp first_email_name(value) when is_binary(value) do
    value
    |> String.split(",", parts: 2)
    |> List.first()
    |> to_string()
    |> String.trim()
    |> case do
      "" ->
        nil

      raw ->
        raw
        |> String.replace(~r/<[^>]+>/, "")
        |> String.replace("\"", "")
        |> String.trim()
        |> case do
          "" ->
            nil

          cleaned ->
            cleaned
            |> String.split(~r/\s+/, trim: true)
            |> List.first()
        end
    end
  end

  defp first_email_name(_), do: nil

  defp normalize_reply_subject(subject) when is_binary(subject) do
    trimmed = String.trim(subject)

    cond do
      trimmed == "" -> "Quick follow-up"
      String.match?(trimmed, ~r/^re:/i) -> trimmed
      true -> "Re: #{trimmed}"
    end
  end

  defp normalize_reply_subject(_), do: "Quick follow-up"

  defp sender_name(user_id) do
    System.get_env("MARAITHON_DEFAULT_SENDER_NAME") ||
      Application.get_env(:maraithon, :insights, [])
      |> Keyword.get(:default_sender_name, speaker_name(user_id))
  end

  defp speaker_name("kent" <> _), do: "Kent"
  defp speaker_name(_), do: "Kent"

  defp ensure_insight_preloaded(%Delivery{insight: %Insight{}} = delivery), do: delivery
  defp ensure_insight_preloaded(%Delivery{} = delivery), do: Repo.preload(delivery, :insight)

  defp telegram_module do
    Application.get_env(:maraithon, :insights, [])
    |> Keyword.get(:telegram_module, Telegram)
  end

  defp compact_map(map) do
    Enum.reduce(map, %{}, fn
      {_key, nil}, acc -> acc
      {_key, ""}, acc -> acc
      {key, value}, acc -> Map.put(acc, key, value)
    end)
  end

  defp maybe_append(list, item, true) when is_binary(item), do: list ++ [item]
  defp maybe_append(list, _item, _condition), do: list

  defp stringify_map_keys(map) when is_map(map) do
    Enum.reduce(map, %{}, fn
      {key, value}, acc when is_map(value) ->
        Map.put(acc, to_string(key), stringify_map_keys(value))

      {key, value}, acc when is_list(value) ->
        Map.put(
          acc,
          to_string(key),
          Enum.map(value, fn
            item when is_map(item) -> stringify_map_keys(item)
            item -> item
          end)
        )

      {key, value}, acc ->
        Map.put(acc, to_string(key), value)
    end)
  end

  defp stringify_map_keys(other), do: other

  defp read_map(map, key) when is_map(map) and is_binary(key) do
    case fetch(map, key) do
      %{} = value -> value
      _ -> %{}
    end
  end

  defp read_string(map, key, default \\ nil) when is_map(map) and is_binary(key) do
    case fetch(map, key) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> default
          trimmed -> trimmed
        end

      value when is_integer(value) ->
        Integer.to_string(value)

      _ ->
        default
    end
  end

  defp read_integer(map, key) when is_map(map) and is_binary(key) do
    case fetch(map, key) do
      value when is_integer(value) ->
        value

      value when is_binary(value) ->
        case Integer.parse(String.trim(value)) do
          {parsed, ""} -> parsed
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp read_boolean(map, key, default) when is_map(map) and is_binary(key) do
    case fetch(map, key) do
      value when value in [true, false] ->
        value

      value when is_binary(value) ->
        case String.downcase(String.trim(value)) do
          "true" -> true
          "1" -> true
          "yes" -> true
          "false" -> false
          "0" -> false
          "no" -> false
          _ -> default
        end

      _ ->
        default
    end
  end

  defp read_id_string(map, key) when is_map(map) and is_binary(key) do
    read_string(map, key) || read_integer(map, key) |> normalize_id()
  end

  defp normalize_id(nil), do: nil
  defp normalize_id(value) when is_binary(value), do: value
  defp normalize_id(value) when is_integer(value), do: Integer.to_string(value)
  defp normalize_id(value), do: to_string(value)

  defp read_string_list(map, key) when is_map(map) and is_binary(key) do
    case fetch(map, key) do
      list when is_list(list) ->
        list
        |> Enum.filter(&is_binary/1)
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))

      value when is_binary(value) ->
        [String.trim(value)]

      _ ->
        []
    end
  end

  defp fetch(map, key) when is_map(map) and is_binary(key) do
    case Map.fetch(map, key) do
      {:ok, value} ->
        value

      :error ->
        Enum.find_value(map, fn
          {map_key, value} when is_atom(map_key) ->
            if Atom.to_string(map_key) == key, do: value

          _ ->
            nil
        end)
    end
  end

  defp record_value(metadata, key) do
    metadata
    |> read_map("record")
    |> read_string(key)
  end

  defp record_value_list(metadata, key) do
    metadata
    |> read_map("record")
    |> read_string_list(key)
  end

  defp safe(value) when is_binary(value) do
    value
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
  end

  defp safe(value), do: to_string(value || "")

  defp truncate(value, max) when is_binary(value) and is_integer(max) and max > 3 do
    if String.length(value) > max, do: String.slice(value, 0, max - 3) <> "...", else: value
  end

  defp truncate(value, _max), do: to_string(value || "")

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(value), do: not is_nil(value)

  defp blank?(value), do: not present?(value)

  defp normalize_blank(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_blank(_), do: nil
end
