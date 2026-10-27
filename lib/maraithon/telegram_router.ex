defmodule Maraithon.TelegramRouter do
  @moduledoc """
  Orchestrates Telegram freeform chat, reply-thread learning, and action requests.
  """

  import Ecto.Query

  alias Maraithon.ConnectedAccounts
  alias Maraithon.InsightNotifications.Actions
  alias Maraithon.InsightNotifications.Delivery
  alias Maraithon.Insights.Detail
  alias Maraithon.PreferenceMemory
  alias Maraithon.Repo
  alias Maraithon.TelegramAssistant
  alias Maraithon.TelegramAssistant.ActionFailureCopy
  alias Maraithon.TelegramAssistant.PreferenceConfirmationCopy
  alias Maraithon.TelegramConversations
  alias Maraithon.TelegramInterpreter
  alias Maraithon.TelegramResponder
  alias Maraithon.Todos.UserFacingCopy
  alias MaraithonWeb.LocalTime

  require Logger

  @clarification_limit 3
  @general_chat_window_seconds 5 * 60
  @general_chat_rate_limit 20

  def handle_message(data) when is_map(data) do
    with chat_id when is_binary(chat_id) <- read_id_string(data, "chat_id"),
         text when is_binary(text) <- read_string(data, "text"),
         %{user_id: user_id} <-
           ConnectedAccounts.get_connected_by_external_account("telegram", chat_id) do
      reply_to_message_id =
        data
        |> fetch("reply_to")
        |> read_nested_id_string("message_id")

      source_message_id = read_id_string(data, "message_id")
      linked_delivery = linked_delivery(chat_id, reply_to_message_id)
      linked_insight = linked_delivery && linked_delivery.insight

      if general_chat_rate_limited?(chat_id, reply_to_message_id, linked_delivery) do
        send_ephemeral_reply(
          chat_id,
          source_message_id,
          "Still catching up with the last few messages. Reply to the exact item to act on, or wait a moment before sending more."
        )
      else
        {:ok, conversation} =
          TelegramConversations.start_or_continue(user_id, chat_id, %{
            "reply_to_message_id" => reply_to_message_id,
            "root_message_id" => source_message_id || reply_to_message_id,
            "linked_delivery_id" => linked_delivery && linked_delivery.id,
            "linked_insight_id" => linked_insight && linked_insight.id,
            # A stale, abandoned confirmation prompt must not capture an
            # unrelated later message. Only a recognizable yes/no answer is
            # allowed to continue it; anything else starts a fresh
            # conversation instead of inheriting the stale thread's context.
            "confirmation_reply" => affirmative?(text) or negative?(text),
            # Same bleed risk for a pending clarifying question: within the
            # freshness window, only a message that actually looks like an
            # answer continues that thread. Anything that looks like a fresh,
            # unrelated ask (slash command, long multi-sentence message)
            # starts a new conversation instead.
            "clarification_reply" => clarification_reply?(text)
          })

        {:ok, {_conversation, user_turn}} =
          TelegramConversations.append_turn(conversation, %{
            "role" => "user",
            "telegram_message_id" => source_message_id,
            "reply_to_message_id" => reply_to_message_id,
            "text" => text,
            "structured_data" => turn_structured_data(data)
          })

        cond do
          awaiting_confirmation?(conversation) and affirmative?(text) ->
            case TelegramAssistant.handle_text_confirmation(
                   conversation,
                   user_turn,
                   chat_id,
                   source_message_id,
                   :confirm,
                   durable: durable_processing?(data)
                 ) do
              :ok ->
                :ok

              {:noop, _reason} = noop ->
                noop

              {:fallback, _reason} ->
                confirm_pending_rules(conversation, user_turn, chat_id, source_message_id)

              {:error, _reason} = error ->
                error

              other ->
                {:error, {:invalid_telegram_confirmation_result, other}}
            end

          awaiting_confirmation?(conversation) and negative?(text) ->
            case TelegramAssistant.handle_text_confirmation(
                   conversation,
                   user_turn,
                   chat_id,
                   source_message_id,
                   :reject,
                   durable: durable_processing?(data)
                 ) do
              :ok ->
                :ok

              {:noop, _reason} = noop ->
                noop

              {:fallback, _reason} ->
                reject_pending_rules(conversation, user_turn, chat_id, source_message_id)

              {:error, _reason} = error ->
                error

              other ->
                {:error, {:invalid_telegram_confirmation_result, other}}
            end

          true ->
            case TelegramAssistant.handle_inbound(%{
                   user_id: user_id,
                   chat_id: chat_id,
                   text: text,
                   source_message_id: source_message_id,
                   reply_to_message_id: reply_to_message_id,
                   conversation: conversation,
                   user_turn: user_turn,
                   linked_delivery: linked_delivery,
                   linked_insight: linked_insight,
                   durable_processing: durable_processing?(data)
                 }) do
              :ok ->
                :ok

              {:fallback, _reason} ->
                interpret_and_respond(
                  user_id,
                  chat_id,
                  text,
                  source_message_id,
                  conversation,
                  user_turn,
                  linked_delivery,
                  linked_insight
                )

              {:error, _reason} = error ->
                error

              other ->
                {:error, {:invalid_telegram_assistant_result, other}}
            end
        end
      end
    else
      _unlinked_or_invalid ->
        {:noop, :unlinked_or_unroutable}
    end
  end

  def handle_edited_message(data) when is_map(data) do
    with chat_id when is_binary(chat_id) <- read_id_string(data, "chat_id"),
         message_id when is_binary(message_id) <- read_id_string(data, "message_id"),
         text when is_binary(text) <- read_string(data, "text") do
      case TelegramConversations.update_turn_text(chat_id, message_id, text) do
        {:ok, _turn} -> :ok
        {:error, :not_found} -> {:noop, :turn_not_found}
        {:error, reason} -> {:error, {:telegram_edit_failed, reason}}
        other -> {:error, {:invalid_telegram_edit_result, other}}
      end
    else
      _invalid_edit -> {:error, :invalid_telegram_edit}
    end
  end

  def handle_callback_query(data) when is_map(data) do
    case TelegramAssistant.handle_callback_query(data) do
      :ok ->
        :ok

      {:noop, _reason} = noop ->
        noop

      {:error, _reason} = error ->
        error

      :ignored ->
        callback_data = read_string(data, "data", "")
        callback_id = read_string(data, "callback_id")
        chat_id = read_id_string(data, "chat_id")
        message_id = read_id_string(data, "message_id")

        case TelegramResponder.parse_confirmation_callback(callback_data) do
          {:ok, conversation_id, "confirm"} ->
            handle_confirmation_callback(
              conversation_id,
              :confirm,
              chat_id,
              message_id,
              callback_id
            )

          {:ok, conversation_id, "reject"} ->
            handle_confirmation_callback(
              conversation_id,
              :reject,
              chat_id,
              message_id,
              callback_id
            )

          {:error, :invalid_callback} ->
            {:noop, :unsupported_callback}
        end

      other ->
        {:error, {:invalid_telegram_callback_result, other}}
    end
  end

  defp interpret_and_respond(
         user_id,
         chat_id,
         text,
         source_message_id,
         conversation,
         user_turn,
         linked_delivery,
         linked_insight
       ) do
    recent_turns = TelegramConversations.recent_turns(conversation, limit: 8)

    case TelegramInterpreter.interpret(user_id, %{
           text: text,
           conversation: conversation,
           recent_turns: recent_turns,
           delivery: linked_delivery,
           insight: linked_insight
         }) do
      {:ok, interpretation} ->
        conversation = maybe_clear_clarification(conversation, interpretation)

        case route_interpretation(
               user_id,
               chat_id,
               source_message_id,
               conversation,
               user_turn,
               linked_delivery,
               linked_insight,
               interpretation
             ) do
          {:ok, reply_text, reply_opts} ->
            send_assistant_turn(
              conversation,
              chat_id,
              source_message_id,
              reply_text,
              interpretation,
              reply_opts
            )

          :ok ->
            :ok

          {:noop, _reason} = noop ->
            noop

          {:error, _reason} = error ->
            error

          other ->
            {:error, {:invalid_telegram_route_result, other}}
        end

      {:error, reason} ->
        send_model_unavailable_turn(
          conversation,
          chat_id,
          source_message_id,
          reason
        )
    end
  end

  defp route_interpretation(
         _user_id,
         _chat_id,
         _source_message_id,
         conversation,
         _user_turn,
         _delivery,
         _insight,
         %{"needs_clarification" => true} = interpretation
       ) do
    ask_clarifying_question(conversation, interpretation)
  end

  defp route_interpretation(
         _user_id,
         _chat_id,
         _source_message_id,
         _conversation,
         _user_turn,
         %Delivery{} = delivery,
         insight,
         %{"intent" => "question_about_insight"} = interpretation
       ) do
    {:ok, explain_insight(delivery, insight, interpretation), []}
  end

  defp route_interpretation(
         user_id,
         _chat_id,
         _source_message_id,
         conversation,
         user_turn,
         _delivery,
         _insight,
         %{"intent" => "preference_reject"}
       ) do
    pending = pending_rule_ids(conversation)

    if pending == [] do
      {:ok, PreferenceConfirmationCopy.no_pending_text(), []}
    else
      {:ok, _} =
        PreferenceMemory.reject_rules(user_id, pending,
          conversation_id: conversation.id,
          source_turn_id: user_turn.id
        )

      _ = TelegramConversations.close(conversation, %{"metadata" => %{"pending_rule_ids" => []}})
      {:ok, PreferenceConfirmationCopy.local_only_text(), []}
    end
  end

  defp route_interpretation(
         user_id,
         _chat_id,
         _source_message_id,
         conversation,
         user_turn,
         _delivery,
         _insight,
         %{"candidate_rules" => rules}
       )
       when is_list(rules) and rules != [] do
    {:ok, saved} =
      PreferenceMemory.save_interpreted_rules(
        user_id,
        rules,
        "telegram_inferred",
        conversation_id: conversation.id,
        source_turn_id: user_turn.id
      )

    active = Enum.filter(saved, &(Map.get(&1, "status") == "active"))
    pending = Enum.filter(saved, &(Map.get(&1, "status") == "pending_confirmation"))

    cond do
      pending != [] ->
        {:ok, _conversation} =
          TelegramConversations.mark_awaiting_confirmation(conversation, %{
            "metadata" => %{"pending_rule_ids" => Enum.map(pending, &Map.get(&1, "rule_id"))}
          })

        text = PreferenceConfirmationCopy.text(pending)

        {:ok, text, [reply_markup: TelegramResponder.confirmation_markup(conversation.id)]}

      active != [] ->
        {:ok, PreferenceConfirmationCopy.saved_text(active), []}

      true ->
        {:ok, PreferenceConfirmationCopy.local_only_text(), []}
    end
  end

  defp route_interpretation(
         _user_id,
         _chat_id,
         _source_message_id,
         _conversation,
         _user_turn,
         %Delivery{} = delivery,
         _insight,
         %{"candidate_action" => %{"action" => action}}
       )
       when action in [
              "draft",
              "redraft",
              "cancel",
              "done",
              "dismiss",
              "snooze",
              "explain",
              "send",
              "status",
              "create_task"
            ] do
    case action do
      "explain" ->
        {:ok, explain_insight(delivery, delivery.insight, %{"assistant_reply" => nil}), []}

      "status" ->
        {:ok, Actions.render_message(delivery), []}

      "send" ->
        with {:ok, updated_delivery, _notice} <- ensure_draft_then_send(delivery) do
          {:ok, Actions.render_message(updated_delivery), []}
        else
          {:error, reason} -> {:ok, action_failure_text(reason), []}
        end

      "redraft" ->
        with {:ok, updated_delivery, _notice} <- Actions.perform_action(delivery, "regenerate") do
          {:ok, Actions.render_message(updated_delivery), []}
        else
          {:error, reason} -> {:ok, action_failure_text(reason), []}
        end

      "create_task" ->
        with {:ok, result} <- create_linear_task(delivery) do
          {:ok, render_task_created(result), []}
        else
          {:error, reason} -> {:ok, action_failure_text(reason), []}
        end

      other ->
        with {:ok, updated_delivery, _notice} <- Actions.perform_action(delivery, other) do
          {:ok, Actions.render_message(updated_delivery), []}
        else
          {:error, reason} -> {:ok, action_failure_text(reason), []}
        end
    end
  end

  defp route_interpretation(
         _user_id,
         _chat_id,
         _source_message_id,
         _conversation,
         _user_turn,
         _delivery,
         _insight,
         interpretation
       ) do
    reply =
      Map.get(interpretation, "assistant_reply") ||
        Map.get(interpretation, "clarifying_question") ||
        TelegramInterpreter.default_assistant_reply()

    {:ok, UserFacingCopy.polish_text(reply), []}
  end

  defp confirm_pending_rules(conversation, user_turn, chat_id, source_message_id) do
    pending = pending_rule_ids(conversation)

    {:ok, confirmed} =
      PreferenceMemory.confirm_rules(conversation.user_id, pending,
        conversation_id: conversation.id,
        source_turn_id: user_turn.id
      )

    _ = TelegramConversations.close(conversation, %{"metadata" => %{"pending_rule_ids" => []}})

    send_assistant_turn(
      conversation,
      chat_id,
      source_message_id,
      PreferenceConfirmationCopy.saved_text(confirmed),
      %{"intent" => "preference_create", "confidence" => 1.0},
      []
    )
  end

  defp reject_pending_rules(conversation, user_turn, chat_id, source_message_id) do
    pending = pending_rule_ids(conversation)

    {:ok, _} =
      PreferenceMemory.reject_rules(conversation.user_id, pending,
        conversation_id: conversation.id,
        source_turn_id: user_turn.id
      )

    _ = TelegramConversations.close(conversation, %{"metadata" => %{"pending_rule_ids" => []}})

    send_assistant_turn(
      conversation,
      chat_id,
      source_message_id,
      PreferenceConfirmationCopy.local_only_text(),
      %{"intent" => "preference_reject", "confidence" => 1.0},
      []
    )
  end

  defp handle_confirmation_callback(conversation_id, decision, chat_id, message_id, callback_id) do
    case Repo.get(TelegramConversations.Conversation, conversation_id) do
      nil ->
        with :ok <- delivered_callback_answer(callback_id, "Conversation not found") do
          {:noop, :conversation_not_found}
        end

      conversation ->
        handle_confirmation_decision(
          conversation,
          decision,
          chat_id,
          message_id,
          callback_id
        )
    end
  end

  defp handle_confirmation_decision(conversation, :confirm, chat_id, message_id, callback_id) do
    pending = pending_rule_ids(conversation)

    with {:ok, confirmed} <-
           PreferenceMemory.confirm_rules(conversation.user_id, pending,
             conversation_id: conversation.id
           ),
         {:ok, _closed} <-
           TelegramConversations.close(conversation, %{
             "metadata" => %{"pending_rule_ids" => []}
           }),
         :ok <- delivered_callback_answer(callback_id, "Preference remembered") do
      send_assistant_turn(
        conversation,
        chat_id,
        message_id,
        PreferenceConfirmationCopy.saved_text(confirmed),
        %{"intent" => "preference_create", "confidence" => 1.0},
        []
      )
    else
      {:error, _reason} = error -> error
      other -> {:error, {:invalid_confirmation_result, other}}
    end
  end

  defp handle_confirmation_decision(conversation, :reject, chat_id, message_id, callback_id) do
    pending = pending_rule_ids(conversation)

    with {:ok, _rejected} <-
           PreferenceMemory.reject_rules(conversation.user_id, pending,
             conversation_id: conversation.id
           ),
         {:ok, _closed} <-
           TelegramConversations.close(conversation, %{
             "metadata" => %{"pending_rule_ids" => []}
           }),
         :ok <- delivered_callback_answer(callback_id, "Kept in this conversation") do
      send_assistant_turn(
        conversation,
        chat_id,
        message_id,
        PreferenceConfirmationCopy.local_only_text(),
        %{"intent" => "preference_reject", "confidence" => 1.0},
        []
      )
    else
      {:error, _reason} = error -> error
      other -> {:error, {:invalid_confirmation_result, other}}
    end
  end

  defp delivered_callback_answer(callback_id, text) do
    case TelegramResponder.answer_callback(callback_id, text) do
      {:ok, _result} -> :ok
      {:error, reason} -> {:error, {:telegram_callback_answer_failed, reason}}
      other -> {:error, {:invalid_telegram_callback_answer_result, other}}
    end
  end

  defp send_assistant_turn(
         conversation,
         chat_id,
         reply_to_message_id,
         text,
         interpretation,
         reply_opts
       ) do
    text = UserFacingCopy.polish_text(text)

    case TelegramResponder.reply(chat_id, reply_to_message_id, text, reply_opts) do
      {:ok, result} ->
        {:ok, _} =
          TelegramConversations.append_turn(conversation, %{
            "role" => "assistant",
            "telegram_message_id" => normalize_id(Map.get(result, "message_id")),
            "reply_to_message_id" => reply_to_message_id,
            "text" => text,
            "intent" => Map.get(interpretation, "intent"),
            "confidence" => Map.get(interpretation, "confidence"),
            "structured_data" => interpretation
          })

        :ok

      {:error, reason} ->
        Logger.warning("Failed Telegram assistant reply", reason: inspect(reason))
        {:error, {:telegram_send_failed, reason}}
    end
  end

  defp send_model_unavailable_turn(conversation, chat_id, reply_to_message_id, reason) do
    text =
      "Message saved. Maraithon did not find a checked answer in connected sources, so it did not guess."

    send_assistant_turn(
      conversation,
      chat_id,
      reply_to_message_id,
      text,
      %{
        "intent" => "model_error",
        "confidence" => 0.0,
        "error" => inspect(reason),
        "semantic_fallback_used" => false
      },
      []
    )
  end

  defp linked_delivery(chat_id, reply_to_message_id) when is_binary(reply_to_message_id) do
    case TelegramConversations.find_by_reply(chat_id, reply_to_message_id) do
      %{linked_delivery: %Delivery{} = delivery} ->
        Repo.preload(delivery, :insight)

      %{linked_delivery_id: delivery_id} when is_binary(delivery_id) ->
        delivery_id
        |> Actions.fetch_delivery_for_chat(chat_id)
        |> case do
          {:ok, delivery} -> delivery
          _ -> nil
        end

      _ ->
        case Actions.find_delivery_by_provider_message(chat_id, reply_to_message_id) do
          {:ok, delivery} -> delivery
          _ -> nil
        end
    end
  end

  defp linked_delivery(_chat_id, _reply_to_message_id), do: nil

  defp pending_rule_ids(%{metadata: %{"pending_rule_ids" => ids}, user_id: user_id})
       when is_list(ids) do
    case Enum.filter(ids, &is_binary/1) do
      [] -> pending_rule_ids(user_id)
      scoped_ids -> scoped_ids
    end
  end

  defp pending_rule_ids(%{user_id: user_id}), do: pending_rule_ids(user_id)

  defp pending_rule_ids(user_id) when is_binary(user_id) do
    PreferenceMemory.pending_rules(user_id)
    |> Enum.map(&Map.get(&1, "rule_id"))
    |> Enum.filter(&is_binary/1)
  end

  defp pending_rule_ids(_), do: []

  defp awaiting_confirmation?(conversation), do: conversation.status == "awaiting_confirmation"

  defp affirmative?(text) when is_binary(text) do
    String.downcase(String.trim(text)) in ["yes", "y", "remember that", "save it", "do that"]
  end

  defp negative?(text) when is_binary(text) do
    String.downcase(String.trim(text)) in [
      "no",
      "n",
      "just this one",
      "don't save that",
      "do not save"
    ]
  end

  # A clarifying question doesn't have a fixed yes/no vocabulary — any short
  # direct reply ("General rule, not just this thread") is a valid answer.
  # So, unlike `affirmative?/1` / `negative?/1`, this deliberately does not
  # try to match an allowlist of phrasings. Instead it only rejects text that
  # looks like a fresh, unrelated ask in form: a slash command, or a long
  # multi-sentence message (the shape of someone starting a new request, not
  # answering a short question). Everything else is treated as an answer, so
  # a genuine direct reply keeps continuing the clarification thread.
  defp clarification_reply?(text) when is_binary(text) do
    trimmed = String.trim(text)

    cond do
      trimmed == "" -> false
      String.starts_with?(trimmed, "/") -> false
      looks_like_fresh_ask?(trimmed) -> false
      true -> true
    end
  end

  defp looks_like_fresh_ask?(text) do
    sentence_count =
      text
      |> String.split(~r/[.!?]+/, trim: true)
      |> length()

    word_count =
      text
      |> String.split(~r/\s+/, trim: true)
      |> length()

    sentence_count > 1 and word_count > 12
  end

  defp ensure_draft_then_send(delivery) do
    case Actions.action_state_for_delivery(delivery) do
      %{"status" => "drafted"} ->
        Actions.perform_action(delivery, "send")

      _ ->
        with {:ok, drafted_delivery, _notice} <- Actions.perform_action(delivery, "draft") do
          {:ok, drafted_delivery, "Draft ready for approval"}
        end
    end
  end

  defp general_chat_rate_limited?(chat_id, reply_to_message_id, linked_delivery)
       when is_binary(chat_id) do
    is_nil(reply_to_message_id) and is_nil(linked_delivery) and
      TelegramConversations.recent_user_turn_count(chat_id, @general_chat_window_seconds) >=
        @general_chat_rate_limit
  end

  defp general_chat_rate_limited?(_chat_id, _reply_to_message_id, _linked_delivery), do: false

  defp maybe_clear_clarification(conversation, %{"needs_clarification" => true}), do: conversation

  defp maybe_clear_clarification(%{metadata: metadata} = conversation, interpretation) do
    if Map.get(metadata || %{}, "pending_clarification") == true and
         Map.get(interpretation, "intent") != "unknown" do
      case TelegramConversations.update_metadata(conversation, %{
             "pending_clarification" => false,
             "last_clarifying_question" => nil
           }) do
        {:ok, updated_conversation} -> updated_conversation
        _ -> conversation
      end
    else
      conversation
    end
  end

  defp ask_clarifying_question(conversation, interpretation) do
    depth = clarification_depth(conversation) + 1

    if depth > @clarification_limit do
      {:ok,
       "I still can’t safely infer the right action. Reply to the exact item you mean, or tell me the precise rule or action you want.",
       []}
    else
      question =
        Map.get(interpretation, "clarifying_question") ||
          Map.get(interpretation, "assistant_reply") ||
          TelegramInterpreter.default_assistant_reply()

      question = UserFacingCopy.polish_text(question)

      _ =
        TelegramConversations.update_metadata(conversation, %{
          "pending_clarification" => true,
          "clarification_depth" => depth,
          "last_clarifying_question" => question
        })

      {:ok, question, []}
    end
  end

  defp clarification_depth(%{metadata: %{"clarification_depth" => value}})
       when is_integer(value) and value >= 0,
       do: value

  defp clarification_depth(_conversation), do: 0

  defp explain_insight(%Delivery{} = delivery, insight, interpretation) do
    insight = insight || delivery.insight

    detail =
      insight
      |> insight_deliveries(delivery)
      |> then(
        &Detail.build(insight, &1,
          timezone_info: LocalTime.timezone_info_for_user(delivery.user_id)
        )
      )

    Detail.summary_text(detail, insight, extra_reply: Map.get(interpretation, "assistant_reply"))
  end

  defp insight_deliveries(%{id: insight_id}, %Delivery{user_id: user_id})
       when is_binary(insight_id) and is_binary(user_id) do
    Delivery
    |> where([d], d.insight_id == ^insight_id and d.user_id == ^user_id)
    |> order_by([d], desc_nulls_last: d.sent_at, desc: d.inserted_at)
    |> Repo.all()
  end

  defp create_linear_task(%Delivery{} = delivery) do
    case ConnectedAccounts.get(delivery.user_id, "linear") do
      %{metadata: metadata} ->
        team_id =
          get_in(metadata || %{}, ["default_team_id"]) || get_in(metadata || %{}, ["team_id"])

        if is_binary(team_id) and String.trim(team_id) != "" do
          Maraithon.Tools.execute(
            "linear_create_issue",
            %{
              "user_id" => delivery.user_id,
              "team_id" => team_id,
              "title" => delivery.insight.title,
              "description" =>
                Enum.join(
                  [
                    delivery.insight.summary,
                    "",
                    "Next move:",
                    delivery.insight.recommended_action
                  ],
                  "\n"
                )
            },
            %{surface: "telegram", user_id: delivery.user_id, confirmed?: true}
          )
        else
          {:error, "linear_default_team_missing"}
        end

      _ ->
        {:error, "linear_not_connected"}
    end
  end

  defp render_task_created(%{"issue" => %{"identifier" => identifier, "url" => url}})
       when is_binary(identifier) and is_binary(url) do
    "Created Linear task #{identifier}: #{url}"
  end

  defp render_task_created(%{"issue" => %{"identifier" => identifier}})
       when is_binary(identifier),
       do: "Created Linear task #{identifier}."

  defp render_task_created(_result), do: "Created a Linear task."

  defp action_failure_text(reason), do: ActionFailureCopy.insight_action(reason)

  defp send_ephemeral_reply(chat_id, reply_to_message_id, text) do
    case TelegramResponder.reply(chat_id, reply_to_message_id, text) do
      {:ok, _result} -> :ok
      {:error, reason} -> {:error, {:telegram_send_failed, reason}}
      other -> {:error, {:invalid_telegram_send_result, other}}
    end
  end

  # R4: tag the turn as voice-originated without prepending any visible text
  # to the user's message. `input_mode` is set by
  # `Maraithon.TelegramAssistant.VoiceCapture` on the inbound data once a
  # voice/audio message has been transcribed into `text`.
  defp turn_structured_data(data) do
    case read_string(data, "input_mode") do
      nil -> %{}
      mode -> %{"input_mode" => mode}
    end
  end

  defp read_string(map, key, default \\ nil) when is_map(map) and is_binary(key) do
    case fetch(map, key) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> default
          trimmed -> trimmed
        end

      _ ->
        default
    end
  end

  defp read_id_string(map, key) when is_map(map) and is_binary(key) do
    fetch(map, key) |> normalize_id()
  end

  defp read_nested_id_string(%{} = map, key) when is_binary(key), do: read_id_string(map, key)
  defp read_nested_id_string(_, _key), do: nil

  defp normalize_id(nil), do: nil
  defp normalize_id(value) when is_integer(value), do: Integer.to_string(value)
  defp normalize_id(value) when is_binary(value), do: value
  defp normalize_id(value), do: to_string(value)

  defp durable_processing?(data) when is_map(data),
    do: Map.get(data, :durable_processing, false) == true

  defp fetch(map, key) do
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
end
