defmodule Maraithon.InsightNotifications.Actions do
  @moduledoc """
  Telegram-native action proposals and execution for actionable insights.
  """

  import Ecto.Query

  alias Maraithon.Connectors.Telegram
  alias Maraithon.Drafts
  alias Maraithon.InsightNotifications.Delivery
  alias Maraithon.Insights
  alias Maraithon.Insights.Insight
  alias Maraithon.LLM
  alias Maraithon.Memory.UserVoice
  alias Maraithon.OperatorMemory
  alias Maraithon.PreferenceMemory
  alias Maraithon.Repo
  alias Maraithon.SourceLabels
  alias Maraithon.TelegramAssistant.ActionFailureCopy
  alias Maraithon.Todos
  alias Maraithon.Todos.UserFacingCopy
  alias Maraithon.Tools
  alias Maraithon.UserMemory

  require Logger

  @callback_prefix "insact"
  @max_preview_length 900
  @chief_message_max_length 700
  @section_text_max_length 180
  @legacy_notification_fragments [
    "I think this needs your attention.",
    "What I'd send",
    "Fast actions",
    "I would do this next:",
    "Since the last check:",
    "Tap Draft",
    "appears to be waiting",
    "still looks open",
    "thread still looks open",
    "still looks unclosed",
    "I found no later reply"
  ]

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
    action_state_text = render_action_state(action_state, insight) |> String.trim()

    [
      verified_chief_message(insight, metadata),
      action_state_text
    ]
    |> Enum.reject(&blank?/1)
    |> Enum.join("\n\n")
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
         |> Map.put("subject", Drafts.sanitize_text(subject))
         |> Map.put("body", Drafts.sanitize_text(body))}

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
        {:ok, Map.put(fallback, "text", Drafts.sanitize_text(text))}

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

  defp render_action_state(nil, _insight), do: ""

  defp render_action_state(%{"status" => "drafted"} = state, _insight) do
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

  defp render_action_state(%{"status" => "executed"} = state, insight) do
    kind = read_string(state, "kind", read_string(read_map(state, "spec"), "kind"))

    title_line = completed_item_line(insight)

    {heading, details} =
      case kind do
        "gmail_reply" ->
          {"Sent", "Sent via Gmail."}

        "slack_reply" ->
          {"Sent", "Sent in Slack."}

        "manual_complete" ->
          {"Marked Done", "Marked complete from Telegram."}

        "manual_ack" ->
          {"Acknowledged", "Acknowledged from Telegram."}

        _ ->
          {"Completed", "Action completed."}
      end

    "\n\n<b>#{heading}</b>\n#{details}#{title_line}"
  end

  defp render_action_state(%{"status" => "snoozed"} = state, _insight) do
    until_text = read_string(state, "until")
    "\n\n<b>Snoozed</b>\nUntil: #{safe(until_text)}"
  end

  defp render_action_state(%{"status" => "dismissed"}, _insight), do: "\n\n<b>Dismissed</b>"
  defp render_action_state(%{"status" => "cancelled"}, _insight), do: ""
  defp render_action_state(_, _insight), do: ""

  defp completed_item_line(%Insight{} = insight) do
    title = insight.title

    if present?(title) do
      "\nItem: #{safe(truncate(title, @section_text_max_length))}"
    else
      ""
    end
  end

  defp completed_item_line(_insight), do: ""

  defp action_state(%Delivery{} = delivery) do
    case delivery.metadata do
      %{"telegram_action" => %{} = state} -> state
      _ -> nil
    end
  end

  defp verified_chief_message(%Insight{} = insight, metadata) do
    candidates = [
      fn -> chief_message(insight, metadata) end,
      fn -> fallback_chief_message(insight, metadata) end
    ]

    Enum.reduce_while(candidates, nil, fn candidate_fun, _last_error ->
      message = candidate_fun.()

      case verify_chief_message(message) do
        :ok ->
          {:halt, message}

        {:error, issues} ->
          {:cont, {:error, issues}}
      end
    end)
    |> case do
      message when is_binary(message) ->
        message

      {:error, issues} ->
        Logger.warning("Telegram insight notification failed chief-of-staff verification",
          insight_id: insight.id,
          issues: issues
        )

        fallback_chief_message(insight, metadata)
        |> truncate(@chief_message_max_length)
    end
  end

  defp chief_message(%Insight{} = insight, metadata) do
    insight_sections(insight, metadata)
    |> Enum.map(fn {label, text} -> message_section(label, text) end)
    |> Enum.reject(&blank?/1)
    |> Enum.join("\n\n")
  end

  defp fallback_chief_message(%Insight{} = insight, metadata) do
    insight_sections(insight, metadata)
    |> Enum.map(fn {label, text} -> message_section(label, text, 120) end)
    |> Enum.reject(&blank?/1)
    |> Enum.join("\n\n")
  end

  defp insight_sections(%Insight{} = insight, metadata) do
    label = if monitor_insight?(insight), do: "Watching", else: "Open work"

    polished =
      UserFacingCopy.polish_attrs(%{
        "title" => todo_text(insight, metadata),
        "summary" => context_text(insight, metadata),
        "metadata" => metadata || %{}
      })

    [
      {label, Map.get(polished, "title")},
      {"Context", Map.get(polished, "summary")},
      {"Person", person_text(insight, metadata) |> UserFacingCopy.polish_text()},
      {"Why important", why_important_text(insight, metadata) |> UserFacingCopy.polish_text()},
      {"Next", next_text(insight, metadata) |> UserFacingCopy.polish_text()}
    ]
  end

  defp verify_chief_message(message) when is_binary(message) do
    required_sections = ["Context", "Person", "Why important", "Next"]

    issues =
      []
      |> maybe_append("too_long", String.length(message) > @chief_message_max_length)
      |> maybe_append(
        "missing_open_work_or_watching",
        not (String.contains?(message, "<b>Open work</b>") or
               String.contains?(message, "<b>Watching</b>"))
      )
      |> then(fn issues ->
        Enum.reduce(required_sections, issues, fn section, acc ->
          maybe_append(
            acc,
            "missing_#{section}",
            not String.contains?(message, "<b>#{section}</b>")
          )
        end)
      end)
      |> maybe_append(
        "legacy_copy",
        Enum.any?(@legacy_notification_fragments, &String.contains?(message, &1))
      )

    if issues == [], do: :ok, else: {:error, issues}
  end

  defp message_section(label, text, max_length \\ @section_text_max_length)
  defp message_section(_label, text, _max_length) when not is_binary(text), do: nil

  defp message_section(label, text, max_length) do
    text =
      text
      |> compact_sentence()
      |> truncate(max_length)
      |> ensure_sentence()

    if blank?(text), do: nil, else: "<b>#{safe(label)}</b>\n#{safe(text)}"
  end

  defp todo_text(%Insight{} = insight, metadata) do
    person = person_name(metadata)
    subject = read_string(metadata, "subject")
    commitment = record_value(metadata, "commitment")

    cond do
      present?(commitment) ->
        commitment

      String.match?(to_string(insight.title), ~r/^reply owed:/i) ->
        reply_todo_text(person, subject || insight.title)

      present?(insight.title) ->
        insight.title

      true ->
        insight.recommended_action
    end
  end

  defp reply_todo_text(person, subject) do
    subject = clean_subject(subject)

    cond do
      present?(person) and present?(subject) -> "Reply to #{person} about #{subject}"
      present?(person) -> "Reply to #{person}"
      present?(subject) -> "Reply on #{subject}"
      true -> "Reply to the thread"
    end
  end

  defp context_text(%Insight{} = insight, metadata) do
    subject = subject_text(metadata)
    person = person_name(metadata)

    context =
      read_string(metadata, "context_brief") ||
        metadata |> read_map("attention") |> read_string("change_summary") ||
        insight.summary

    context =
      cond do
        present?(subject) and blank?(context) ->
          subject_thread_sentence(subject)

        present?(subject) and generic_followup_context?(context) ->
          "#{subject_thread_sentence(subject)} #{waiting_context_sentence(person)}"

        true ->
          context
      end

    [context, due_sentence(insight)]
    |> Enum.reject(&blank?/1)
    |> Enum.join(" ")
  end

  defp person_text(%Insight{} = insight, metadata) do
    person = person_name(metadata) || "Person not clearly named"
    identity = person_identity_text(metadata)
    source = source_label(insight, metadata)

    [person, identity, source]
    |> Enum.reject(&blank?/1)
    |> case do
      [] -> nil
      [person] -> person
      [person | details] -> "#{person} — #{Enum.join(details, " · ")}"
    end
  end

  defp why_important_text(%Insight{} = insight, metadata) do
    why_now = read_string(metadata, "why_now")
    context = conversation_context(metadata)

    cond do
      present?(why_now) ->
        why_now

      monitor_insight?(insight) ->
        "The thread matters, but the next move may not be yours unless it stalls or asks back."

      present?(read_string(context, "open_loop_reason")) ->
        read_string(context, "open_loop_reason")

      match?(%DateTime{}, insight.due_at) ->
        "The deadline is active and no completion signal is recorded."

      insight.category in ["reply_urgent", "reply_owed", "commitment_unresolved"] ->
        "A named person is waiting on the next step, with no recorded closure signal."

      true ->
        "This is a high-signal open loop worth closing."
    end
  end

  defp next_text(%Insight{} = insight, metadata) do
    explicit =
      record_value(metadata, "next_action") ||
        read_string(metadata, "next_action") ||
        insight.recommended_action

    suggestions = suggested_next_actions_text(metadata)

    cond do
      present?(explicit) and generic_next_action?(explicit) and present?(suggestions) ->
        suggestions

      present?(explicit) and generic_next_action?(explicit) ->
        inferred_next_action(insight, metadata)

      present?(explicit) ->
        explicit

      present?(suggestions) ->
        suggestions

      monitor_insight?(insight) ->
        "Watch for a blocker, direct ask, or stall."

      true ->
        inferred_next_action(insight, metadata)
    end
    |> proactive_next_step_text(insight, metadata)
  end

  defp person_name(metadata) do
    record_value(metadata, "person") ||
      read_string(metadata, "person") ||
      first_email_name(read_string(metadata, "from")) ||
      first_email_name(read_string(metadata, "to"))
  end

  defp due_sentence(%Insight{due_at: %DateTime{} = due_at}) do
    "Due #{Calendar.strftime(due_at, "%b %d, %H:%M UTC")}."
  end

  defp due_sentence(%Insight{}), do: nil

  defp clean_subject(subject) when is_binary(subject) do
    subject
    |> String.trim()
    |> String.replace(~r/^reply owed:\s*/i, "")
    |> String.replace(~r/^(re|fw|fwd):\s*/i, "")
    |> String.trim()
  end

  defp clean_subject(_subject), do: nil

  defp subject_text(metadata) when is_map(metadata) do
    clean_subject(
      read_string(metadata, "subject") ||
        record_value(metadata, "subject") ||
        read_string(metadata, "thread_subject")
    )
  end

  defp subject_text(_metadata), do: nil

  defp subject_thread_sentence(subject) when is_binary(subject) do
    "Thread: #{subject}."
  end

  defp waiting_context_sentence(person) when is_binary(person) do
    "#{person} is tied to this open thread; no later reply or delivery is recorded."
  end

  defp waiting_context_sentence(_person) do
    "No later reply or delivery is recorded."
  end

  defp generic_followup_context?(context) when is_binary(context) do
    context = String.downcase(context)

    String.contains?(context, [
      "no later reply",
      "no sent follow-up",
      "no follow-up",
      "no later follow-through",
      "no follow-through"
    ])
  end

  defp generic_followup_context?(_context), do: false

  defp person_identity_text(metadata) when is_map(metadata) do
    record = read_map(metadata, "record")
    person = person_name(metadata)

    identity =
      [
        first_present([
          read_string(record, "company"),
          read_string(record, "organization"),
          read_string(record, "org"),
          read_string(metadata, "company"),
          read_string(metadata, "organization"),
          read_string(metadata, "org")
        ]),
        first_present([
          read_string(record, "relationship_context"),
          read_string(metadata, "relationship_context"),
          read_string(record, "relationship"),
          read_string(metadata, "relationship")
        ]),
        first_present([
          read_string(record, "project"),
          read_string(record, "project_name"),
          read_string(metadata, "project"),
          read_string(metadata, "project_name")
        ]),
        person_map_identity(metadata)
      ]
      |> Enum.reject(&blank?/1)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(person && String.downcase(&1) == String.downcase(person)))
      |> Enum.uniq()
      |> Enum.take(2)
      |> Enum.join("; ")

    cond do
      present?(identity) ->
        identity

      subject = subject_text(metadata) ->
        "contact on #{subject} thread"

      email_domain = person_email_domain(metadata) ->
        "contact from #{email_domain}"

      true ->
        nil
    end
  end

  defp person_identity_text(_metadata), do: nil

  defp person_map_identity(metadata) do
    metadata
    |> first_person_map()
    |> case do
      %{} = person ->
        first_present([
          read_string(person, "relationship_context"),
          read_string(person, "relationship"),
          read_string(person, "company"),
          read_string(person, "organization"),
          read_string(person, "project")
        ])

      _ ->
        nil
    end
  end

  defp first_person_map(metadata) do
    case fetch(metadata, "people") do
      people when is_list(people) ->
        Enum.find(people, &is_map/1)

      %{} = person ->
        person

      _ ->
        case fetch(metadata, "crm_people") do
          people when is_list(people) -> Enum.find(people, &is_map/1)
          %{} = person -> person
          _ -> nil
        end
    end
  end

  defp person_email_domain(metadata) do
    [read_string(metadata, "from"), read_string(metadata, "to")]
    |> Enum.find_value(fn value ->
      case Regex.run(~r/@([A-Za-z0-9.-]+\.[A-Za-z]{2,})/, to_string(value)) do
        [_, domain] -> domain
        _ -> nil
      end
    end)
  end

  defp suggested_next_actions_text(metadata) when is_map(metadata) do
    points =
      read_string_list(metadata, "suggested_next_actions") ++
        read_string_list(metadata, "suggested_reply_points") ++
        record_value_list(metadata, "suggested_next_actions") ++
        record_value_list(metadata, "suggested_reply_points")

    points =
      points
      |> Enum.map(&compact_sentence/1)
      |> Enum.reject(&blank?/1)
      |> Enum.reject(&generic_suggestion_point?/1)
      |> Enum.uniq()
      |> Enum.take(3)

    case points do
      [] -> nil
      points -> "Suggested: #{Enum.join(points, "; ")}"
    end
  end

  defp suggested_next_actions_text(_metadata), do: nil

  defp generic_suggestion_point?(point) when is_binary(point) do
    point = String.downcase(point)

    String.match?(point, ~r/^acknowledge\s+[a-z]/) or
      String.contains?(point, [
        "answer the ask",
        "answer the specific ask",
        "name the owner",
        "concrete timing commitment",
        "give timing only if",
        "owner, next step",
        "owner / next step",
        "owner, eta",
        "exact artifact",
        "current status"
      ])
  end

  defp generic_suggestion_point?(_point), do: false

  defp generic_next_action?(text) when is_binary(text) do
    text = String.downcase(text)

    String.contains?(text, [
      "owner, eta",
      "owner / next step / eta",
      "owner, next step, and eta",
      "owner, current status",
      "exact artifact",
      "artifact or update",
      "promised update, current status, and timing you can stand behind",
      "reply with a clear owner and timing",
      "concrete next step, owner",
      "reply now with owner"
    ])
  end

  defp generic_next_action?(_text), do: false

  defp inferred_next_action(%Insight{} = insight, metadata) do
    person = person_name(metadata) || "them"
    subject = subject_text(metadata)
    commitment = record_value(metadata, "commitment")

    cond do
      present?(subject) ->
        "Suggested: open the #{subject} thread, confirm what #{person} is waiting on, then send the concrete update or mark it not important if it no longer matters."

      present?(commitment) ->
        "Suggested: verify whether the promised item is ready; if it is, send it, otherwise reply with the current status and realistic timing."

      insight.source == "slack" ->
        "Suggested: open the thread, answer the direct ask, and name the next step or owner only if the conversation needs one."

      true ->
        "Suggested: open the source, confirm the real ask, then reply with the concrete next step or dismiss it if it is no longer important."
    end
  end

  defp proactive_next_step_text(base_text, %Insight{} = insight, metadata)
       when is_binary(base_text) do
    case primary_action(insight) do
      %{label: label} ->
        action_intro =
          "Suggested: tap #{label} to draft for approval before #{delivery_verb(insight)}."

        action_detail = proactive_action_detail(base_text, insight, metadata)

        [action_intro, action_detail]
        |> Enum.reject(&blank?/1)
        |> Enum.join(" ")

      _ ->
        base_text
    end
  end

  defp proactive_next_step_text(base_text, _insight, _metadata), do: base_text

  defp proactive_action_detail(base_text, %Insight{} = insight, metadata) do
    person = person_name(metadata) || "them"
    subject = subject_text(metadata)

    cond do
      present?(subject) and inferred_next_action_text?(base_text) ->
        "Then open the #{subject} thread to confirm what #{person} is waiting on; close if done."

      present?(base_text) ->
        "Next: #{strip_suggested_prefix(base_text)}"

      true ->
        case insight.source do
          "slack" ->
            "Next: answer the Slack thread with the specific update, next step, and timing the evidence supports."

          _ ->
            "Next: reply with the specific update, next step, and timing the evidence supports."
        end
    end
  end

  defp inferred_next_action_text?(text) when is_binary(text) do
    text = String.downcase(text)

    String.contains?(text, [
      "confirm what",
      "confirm the real ask",
      "mark it not important",
      "if it no longer matters"
    ])
  end

  defp inferred_next_action_text?(_text), do: false

  defp strip_suggested_prefix(text) when is_binary(text) do
    text
    |> String.replace(~r/^suggested:\s*/i, "")
    |> compact_sentence()
  end

  defp delivery_verb(%Insight{source: "slack"}), do: "posting"
  defp delivery_verb(_insight), do: "sending"

  defp first_present(values) do
    Enum.find(values, &present?/1)
  end

  defp compact_sentence(value) when is_binary(value) do
    value
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  defp compact_sentence(_value), do: ""

  defp ensure_sentence(value) when is_binary(value) do
    if value == "" or String.match?(value, ~r/[.!?]$/), do: value, else: value <> "."
  end

  defp primary_action(%Insight{} = insight) do
    if ackable_insight?(insight) or monitor_insight?(insight) do
      nil
    else
      case insight.source do
        "gmail" ->
          if draft_action_available?(insight),
            do: %{label: "Draft Email", callback_action: "draft"},
            else: nil

        "slack" ->
          if draft_action_available?(insight),
            do: %{label: "Draft Slack", callback_action: "draft"},
            else: nil

        _ ->
          nil
      end
    end
  end

  defp draft_action_available?(%Insight{source: "gmail"} = insight) do
    metadata = insight.metadata || %{}
    present?(gmail_target_address(insight, metadata))
  end

  defp draft_action_available?(%Insight{source: "slack"} = insight) do
    metadata = insight.metadata || %{}
    present?(read_string(metadata, "team_id")) and present?(read_string(metadata, "channel_id"))
  end

  defp draft_action_available?(_insight), do: false

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
    Write a concise email reply in the operator's first-person voice.

    Return ONLY valid JSON:
    {"subject":"...","body":"..."}

    Constraints:
    - Write in the operator's first-person voice, not as Maraithon or an assistant.
    - Be concrete, direct, calm, and brief.
    - Avoid corporate filler, over-apologizing, and vague "circling back" phrasing.
    - Do not use em dashes. Use commas, periods, colons, or parentheses.
    - Do not include AI-ish filler such as "I hope this finds you well", "circling back", "just wanted to", or assistant sign-offs.
    - Include only the next step, owner, and ETA that the source evidence supports.
    - Do not claim attachments, delivery, or completed work unless explicitly proven.
    - If the promised artifact is not clearly available, send an honest progress update plus a firm ETA.
    - Use draft_plan and suggested_reply_points as drafting instructions, not text to quote.
    - If operator_needs are present, ask for or name the missing detail instead of inventing it.
    - Close the loop in one message.
    - Follow durable operator style and action preferences when they are relevant.

    Insight JSON:
    #{Jason.encode!(draft_prompt_payload(spec, insight))}

    Operator voice guidance JSON:
    #{Jason.encode!(voice_guidance)}

    Draft memory JSON:
    #{Jason.encode!(memory)}
    """
  end

  defp slack_prompt(spec, insight) do
    memory = draft_memory_context(insight.user_id)
    voice_guidance = operator_voice_guidance(insight.user_id)

    """
    Write a concise Slack reply in the operator's first-person voice for an unresolved follow-through item.

    Return ONLY valid JSON:
    {"text":"..."}

    Constraints:
    - Write in the operator's first-person voice, not as Maraithon or an assistant.
    - Be direct, short, calm, and useful.
    - Avoid corporate filler, over-apologizing, and vague status language.
    - Do not use em dashes. Use commas, periods, colons, or parentheses.
    - Do not include AI-ish filler such as "I hope this finds you well", "circling back", "just wanted to", or assistant sign-offs.
    - Include owner / next step / ETA when appropriate.
    - Do not claim work is already done unless proven.
    - Use draft_plan and suggested_reply_points as drafting instructions, not text to quote.
    - If operator_needs are present, ask for or name the missing detail instead of inventing it.
    - Follow durable operator style and action preferences when they are relevant.

    Insight JSON:
    #{Jason.encode!(draft_prompt_payload(spec, insight))}

    Operator voice guidance JSON:
    #{Jason.encode!(voice_guidance)}

    Draft memory JSON:
    #{Jason.encode!(memory)}
    """
  end

  defp draft_memory_context(user_id) when is_binary(user_id) do
    %{
      preference_memory: PreferenceMemory.prompt_context(user_id),
      operator_summaries: OperatorMemory.summaries_for_prompt(user_id),
      user_memory_profile: UserMemory.prompt_context(user_id),
      email_voice: UserVoice.prompt_context(user_id, "gmail"),
      slack_voice: UserVoice.prompt_context(user_id, "slack")
    }
  end

  defp draft_memory_context(_user_id) do
    %{
      preference_memory: PreferenceMemory.prompt_context(nil),
      operator_summaries: [],
      user_memory_profile: UserMemory.prompt_context(nil),
      email_voice: UserVoice.prompt_context(nil, "gmail"),
      slack_voice: UserVoice.prompt_context(nil, "slack")
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
      "I'll confirm the actual ask from the thread, send the next step I can stand behind, and only commit to timing the evidence supports."
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

  defp callback_error_text("google_account_reauth_required"),
    do: "Reconnect Google before using this action"

  defp callback_error_text("slack_workspace_reauth_required"),
    do: "Reconnect Slack before using this action"

  defp callback_error_text("google_account_not_connected"), do: "Connect Google first"
  defp callback_error_text("slack_workspace_not_connected"), do: "Connect Slack first"
  defp callback_error_text(reason), do: ActionFailureCopy.insight_action(reason)

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

    source = source_display(insight.source)

    cond do
      present?(account) -> "#{source} · #{account}"
      true -> source
    end
  end

  defp source_display(source) when is_binary(source),
    do: SourceLabels.label(source, fallback: "connected context")

  defp source_display(_source), do: "connected context"

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
          "Acknowledge the thread is moving, confirm whether you still own the remaining follow-through, and avoid implying nobody responded."

        insight.source == "gmail" and read_string(record, "commitment") != nil ->
          "Reply in-thread in your voice with the actual promise, current status, and timing you can safely stand behind."

        insight.source == "slack" ->
          "Reply in the Slack thread in your voice with the shortest useful status, next step, and evidence-backed timing."

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
      "write_as" => "operator in first person",
      "style_rules" => [
        "short and direct",
        "specific next step over general reassurance",
        "low-apology unless the operator clearly caused the delay",
        "no assistant or Maraithon framing",
        "do not invent facts, attachments, completion, or availability",
        "use a concrete ETA only when evidence or the operator supplied one"
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

  defp speaker_name(user_id) when is_binary(user_id) do
    name =
      user_id
      |> String.split("@", parts: 2)
      |> List.first()
      |> String.split(~r/[._-]+/)
      |> Enum.reject(&(&1 == ""))
      |> Enum.map(&String.capitalize/1)
      |> Enum.join(" ")

    case name do
      "" -> "the operator"
      name -> name
    end
  end

  defp speaker_name(_), do: "the operator"

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
