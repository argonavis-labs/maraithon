defmodule Maraithon.TelegramAssistant.PushBroker do
  @moduledoc """
  Unified Telegram push broker for insights, briefs, and future agent pushes.
  """

  import Ecto.Query

  alias Maraithon.Briefs
  alias Maraithon.Briefs.Brief
  alias Maraithon.ConnectedAccounts
  alias Maraithon.InsightNotifications.Actions
  alias Maraithon.InsightNotifications.Delivery
  alias Maraithon.Repo
  alias Maraithon.TelegramAssistant
  alias Maraithon.TelegramConversations
  alias Maraithon.TelegramResponder

  @default_push_limit_per_hour 3

  def deliver_insight(%Delivery{} = delivery) do
    cond do
      not TelegramAssistant.unified_push_enabled?() ->
        {:fallback, :disabled}

      TelegramAssistant.proactive_delivery_planner_enabled?() ->
        enqueue_insight_candidate(delivery)

      true ->
        deliver_insight_now(delivery)
    end
  end

  defp deliver_insight_now(%Delivery{} = delivery) do
    delivery = Repo.preload(delivery, :insight)
    payload = Actions.telegram_payload(delivery)

    case deliver(%{
           user_id: delivery.user_id,
           chat_id: delivery.destination,
           origin_type: "insight",
           origin_id: delivery.id,
           linked_delivery_id: delivery.id,
           linked_insight_id: delivery.insight_id,
           dedupe_key: "insight_delivery:#{delivery.id}",
           title: delivery.insight && delivery.insight.title,
           body: payload.text,
           urgency: delivery.score || 0.0,
           interrupt_now: true,
           why_now: delivery.insight && delivery.insight.summary,
           telegram_opts: [parse_mode: "HTML", reply_markup: payload.reply_markup]
         }) do
      {:ok, %{decision: "sent_now", message_id: message_id}} ->
        delivery
        |> Ecto.Changeset.change(%{
          status: "sent",
          sent_at: DateTime.utc_now(),
          provider_message_id: message_id,
          metadata: Map.merge(delivery.metadata || %{}, %{"telegram_message_id" => message_id})
        })
        |> Repo.update()

        :ok

      {:ok, %{decision: decision}} when decision in ["suppressed", "merged", "queued_digest"] ->
        :ok

      {:error, reason} ->
        delivery
        |> Ecto.Changeset.change(%{status: "failed", error_message: inspect(reason)})
        |> Repo.update()

        {:error, reason}
    end
  end

  def deliver_brief(%Brief{} = brief) do
    cond do
      not TelegramAssistant.unified_push_enabled?() ->
        {:fallback, :disabled}

      TelegramAssistant.proactive_delivery_planner_enabled?() ->
        enqueue_brief_candidate(brief)

      true ->
        deliver_brief_now(brief)
    end
  end

  defp deliver_brief_now(%Brief{} = brief) do
    todos = Briefs.todo_digest_todos(brief)

    if todos != [] do
      deliver_todo_digest_brief(brief, todos)
    else
      deliver_standard_brief(brief)
    end
  end

  def deliver(candidate) when is_map(candidate) do
    if TelegramAssistant.unified_push_enabled?() do
      candidate = normalize_candidate(candidate)

      cond do
        is_nil(candidate.chat_id) ->
          {:error, :missing_chat_id}

        TelegramAssistant.push_receipt_for(candidate.user_id, candidate.dedupe_key) ->
          {:ok, %{decision: "suppressed", reason: "duplicate"}}

        suppress_for_rate_limit?(candidate) ->
          {:ok, _receipt} =
            TelegramAssistant.record_push_receipt(%{
              user_id: candidate.user_id,
              dedupe_key: candidate.dedupe_key,
              origin_type: candidate.origin_type,
              origin_id: candidate.origin_id,
              decision: "suppressed"
            })

          {:ok, %{decision: "suppressed", reason: "rate_limit"}}

        true ->
          send_candidate(candidate)
      end
    else
      {:fallback, :disabled}
    end
  end

  def interruption_budget(user_id, opts \\ [])

  def interruption_budget(user_id, opts) when is_binary(user_id) and is_list(opts) do
    limit =
      opts
      |> Keyword.get(:limit, push_limit_per_hour())
      |> positive_integer(push_limit_per_hour())

    sent_last_hour = recent_sent_push_count(user_id)
    now = Keyword.get(opts, :now, DateTime.utc_now())

    %{
      "max_immediate_per_hour" => limit,
      "sent_last_hour" => sent_last_hour,
      "remaining_immediate" => max(limit - sent_last_hour, 0),
      "quiet_hours" => quiet_hours?(now),
      "quiet_hours_start_local" => quiet_hours_start_local(),
      "quiet_hours_end_local" => quiet_hours_end_local()
    }
  end

  def interruption_budget(_user_id, _opts) do
    %{
      "max_immediate_per_hour" => push_limit_per_hour(),
      "sent_last_hour" => 0,
      "remaining_immediate" => push_limit_per_hour(),
      "quiet_hours" => false,
      "quiet_hours_start_local" => quiet_hours_start_local(),
      "quiet_hours_end_local" => quiet_hours_end_local()
    }
  end

  defp send_candidate(candidate) do
    case TelegramResponder.send(candidate.chat_id, candidate.body, candidate.telegram_opts) do
      {:ok, result} ->
        message_id = normalize_id(Map.get(result, "message_id"))

        with {:ok, conversation} <-
               TelegramConversations.start_or_continue(candidate.user_id, candidate.chat_id, %{
                 "root_message_id" => message_id,
                 "linked_delivery_id" => candidate.linked_delivery_id,
                 "linked_insight_id" => candidate.linked_insight_id,
                 "metadata" =>
                   %{
                     "mode" => "push_thread",
                     "last_push_origin" => %{
                       "origin_type" => candidate.origin_type,
                       "origin_id" => candidate.origin_id
                     }
                   }
                   |> Map.merge(candidate.conversation_metadata)
               }),
             {:ok, {_conversation, turn}} <-
               TelegramConversations.append_turn(conversation, %{
                 "role" => "assistant",
                 "telegram_message_id" => message_id,
                 "text" => candidate.body,
                 "turn_kind" => "assistant_push",
                 "origin_type" => candidate.origin_type,
                 "origin_id" => candidate.origin_id,
                 "structured_data" =>
                   %{
                     "title" => candidate.title,
                     "why_now" => candidate.why_now,
                     "urgency" => candidate.urgency
                   }
                   |> Map.merge(candidate.structured_data)
               }),
             {:ok, _receipt} <-
               TelegramAssistant.record_push_receipt(%{
                 user_id: candidate.user_id,
                 dedupe_key: candidate.dedupe_key,
                 origin_type: candidate.origin_type,
                 origin_id: candidate.origin_id,
                 decision: "sent_now",
                 conversation_turn_id: turn.id
               }) do
          {:ok,
           %{
             decision: "sent_now",
             message_id: message_id,
             turn_id: turn.id,
             conversation_id: conversation.id
           }}
        else
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp normalize_candidate(candidate) do
    %{
      user_id: Map.get(candidate, :user_id) || candidate["user_id"],
      chat_id: normalize_id(Map.get(candidate, :chat_id) || candidate["chat_id"]),
      origin_type: Map.get(candidate, :origin_type) || candidate["origin_type"] || "agent_push",
      origin_id: Map.get(candidate, :origin_id) || candidate["origin_id"],
      linked_delivery_id:
        Map.get(candidate, :linked_delivery_id) || candidate["linked_delivery_id"],
      linked_insight_id: Map.get(candidate, :linked_insight_id) || candidate["linked_insight_id"],
      title: Map.get(candidate, :title) || candidate["title"],
      body: Map.get(candidate, :body) || candidate["body"] || "",
      urgency: normalize_urgency(Map.get(candidate, :urgency) || candidate["urgency"]),
      interrupt_now: truthy?(Map.get(candidate, :interrupt_now) || candidate["interrupt_now"]),
      why_now: Map.get(candidate, :why_now) || candidate["why_now"],
      structured_data:
        Map.get(candidate, :structured_data) || candidate["structured_data"] || %{},
      conversation_metadata:
        Map.get(candidate, :conversation_metadata) || candidate["conversation_metadata"] || %{},
      dedupe_key:
        Map.get(candidate, :dedupe_key) || candidate["dedupe_key"] ||
          "telegram_push:#{Map.get(candidate, :origin_type) || candidate["origin_type"]}:#{Map.get(candidate, :origin_id) || candidate["origin_id"]}",
      telegram_opts: Map.get(candidate, :telegram_opts) || candidate["telegram_opts"] || []
    }
  end

  defp suppress_for_rate_limit?(candidate) do
    candidate.interrupt_now != true and candidate.urgency < 0.9 and
      recent_sent_push_count(candidate.user_id) >= push_limit_per_hour()
  end

  defp quiet_hours?(%DateTime{} = now) do
    local_hour = now.hour
    start_hour = quiet_hours_start_local()
    end_hour = quiet_hours_end_local()

    if start_hour < end_hour do
      local_hour >= start_hour and local_hour < end_hour
    else
      local_hour >= start_hour or local_hour < end_hour
    end
  end

  defp quiet_hours?(_now), do: false

  defp recent_sent_push_count(user_id) when is_binary(user_id) do
    threshold = DateTime.add(DateTime.utc_now(), -3600, :second)

    Maraithon.TelegramAssistant.PushReceipt
    |> where([receipt], receipt.user_id == ^user_id and receipt.decision == "sent_now")
    |> where([receipt], receipt.inserted_at >= ^threshold)
    |> select([receipt], count(receipt.id))
    |> Repo.one()
    |> Kernel.||(0)
  end

  defp recent_sent_push_count(_user_id), do: 0

  defp push_limit_per_hour do
    Application.get_env(:maraithon, :telegram_assistant, [])
    |> Keyword.get(:max_immediate_pushes_per_hour, @default_push_limit_per_hour)
    |> positive_integer(@default_push_limit_per_hour)
  end

  defp positive_integer(value, _default) when is_integer(value) and value > 0, do: value

  defp positive_integer(value, default) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, ""} when parsed > 0 -> parsed
      _other -> default
    end
  end

  defp positive_integer(_value, default), do: default

  defp quiet_hours_start_local do
    Application.get_env(:maraithon, :telegram_assistant, [])
    |> Keyword.get(:quiet_hours_start_local, 22)
    |> normalize_hour(22)
  end

  defp quiet_hours_end_local do
    Application.get_env(:maraithon, :telegram_assistant, [])
    |> Keyword.get(:quiet_hours_end_local, 7)
    |> normalize_hour(7)
  end

  defp normalize_hour(value, _default) when is_integer(value) and value >= 0 and value <= 23,
    do: value

  defp normalize_hour(value, default) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, ""} when parsed >= 0 and parsed <= 23 -> parsed
      _other -> default
    end
  end

  defp normalize_hour(_value, default), do: default

  defp telegram_destination(user_id) when is_binary(user_id) do
    ConnectedAccounts.telegram_destination(user_id)
  end

  defp telegram_destination(_user_id), do: nil

  defp truthy?(value) when value in [true, "true", "TRUE", "1", 1], do: true
  defp truthy?(_value), do: false

  defp normalize_urgency(value) when is_float(value), do: min(max(value, 0.0), 1.0)
  defp normalize_urgency(value) when is_integer(value), do: normalize_urgency(value / 1)
  defp normalize_urgency(_value), do: 0.0

  defp normalize_id(nil), do: nil
  defp normalize_id(value) when is_integer(value), do: Integer.to_string(value)
  defp normalize_id(value) when is_binary(value), do: value
  defp normalize_id(value), do: to_string(value)

  defp brief_structured_data(%Brief{
         metadata: %{"travel_itinerary_id" => itinerary_id} = metadata
       })
       when is_binary(itinerary_id) do
    %{
      "brief_type" => metadata["brief_type"] || "travel_prep",
      "travel_itinerary_id" => itinerary_id
    }
  end

  defp brief_structured_data(%Brief{metadata: metadata}) when is_map(metadata) do
    %{}
    |> maybe_put("brief_type", metadata["brief_type"])
    |> maybe_put("linked_project", normalize_linked_project(metadata["linked_project"]))
  end

  defp brief_structured_data(_brief), do: %{}

  defp brief_conversation_metadata(%Brief{metadata: %{"travel_itinerary_id" => itinerary_id}})
       when is_binary(itinerary_id) do
    %{"travel_itinerary_id" => itinerary_id}
  end

  defp brief_conversation_metadata(_brief), do: %{}

  defp normalize_linked_project(%{} = project) do
    %{
      "id" => project["id"] || project[:id],
      "name" => project["name"] || project[:name],
      "slug" => project["slug"] || project[:slug],
      "summary" => project["summary"] || project[:summary]
    }
  end

  defp normalize_linked_project(_project), do: nil

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp enqueue_insight_candidate(%Delivery{} = delivery) do
    delivery = Repo.preload(delivery, :insight)
    payload = Actions.telegram_payload(delivery)

    TelegramAssistant.enqueue_proactive_candidate(%{
      user_id: delivery.user_id,
      source: "insight",
      source_id: delivery.id,
      dedupe_key: "insight_delivery:#{delivery.id}",
      title: delivery.insight && delivery.insight.title,
      body: payload.text,
      urgency: delivery.score || 0.0,
      why_now: delivery.insight && delivery.insight.summary,
      structured_data: %{
        "linked_delivery_id" => delivery.id,
        "linked_insight_id" => delivery.insight_id,
        "message_class" => "insight"
      },
      telegram_opts:
        compact_map(%{"parse_mode" => "HTML", "reply_markup" => payload.reply_markup})
    })
    |> case do
      {:ok, _candidate} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp enqueue_brief_candidate(%Brief{} = brief) do
    todos = Briefs.todo_digest_todos(brief)

    attrs =
      if todos == [],
        do: standard_brief_candidate(brief),
        else: todo_digest_candidate(brief, todos)

    TelegramAssistant.enqueue_proactive_candidate(attrs)
    |> case do
      {:ok, _candidate} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp standard_brief_candidate(%Brief{} = brief) do
    payload = Briefs.telegram_payload(brief)

    %{
      user_id: brief.user_id,
      source: "brief",
      source_id: brief.id,
      dedupe_key: "brief:#{brief.id}",
      title: brief.title,
      body: payload.text,
      urgency: 0.7,
      why_now: brief.summary,
      structured_data: brief_structured_data(brief),
      telegram_opts:
        compact_map(%{"parse_mode" => "HTML", "reply_markup" => payload.reply_markup})
    }
  end

  defp todo_digest_candidate(%Brief{} = brief, todos) when is_list(todos) do
    payload = Briefs.telegram_payload(brief)

    %{
      user_id: brief.user_id,
      source: "brief",
      source_id: brief.id,
      dedupe_key: "brief:#{brief.id}",
      title: brief.title,
      body: payload.text,
      urgency: 0.7,
      why_now: brief.summary,
      structured_data:
        brief_structured_data(brief)
        |> Map.put("message_class", "todo_digest")
        |> Map.put("todo_ids", Enum.map(todos, & &1.id))
        |> Map.put("todo_count", length(todos))
        |> Map.put("brief_cadence", brief.cadence),
      telegram_opts:
        compact_map(%{"parse_mode" => "HTML", "reply_markup" => payload.reply_markup})
    }
  end

  defp compact_map(map) when is_map(map) do
    map
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp deliver_standard_brief(%Brief{} = brief) do
    payload = Briefs.telegram_payload(brief)

    case deliver(%{
           user_id: brief.user_id,
           chat_id: telegram_destination(brief.user_id),
           origin_type: "brief",
           origin_id: brief.id,
           dedupe_key: "brief:#{brief.id}",
           title: brief.title,
           body: payload.text,
           urgency: 0.7,
           interrupt_now: true,
           why_now: brief.summary,
           structured_data: brief_structured_data(brief),
           conversation_metadata: brief_conversation_metadata(brief),
           telegram_opts: [parse_mode: "HTML", reply_markup: payload.reply_markup]
         }) do
      {:ok, %{decision: "sent_now", message_id: message_id}} ->
        mark_brief_sent(brief, message_id)
        :ok

      {:ok, %{decision: decision}} when decision in ["suppressed", "merged", "queued_digest"] ->
        :ok

      {:error, reason} ->
        mark_brief_failed(brief, reason)
        {:error, reason}
    end
  end

  defp deliver_todo_digest_brief(%Brief{} = brief, todos) when is_list(todos) do
    if todos == [] do
      deliver_standard_brief(brief)
    else
      payload = Briefs.telegram_payload(brief)

      case deliver(%{
             user_id: brief.user_id,
             chat_id: telegram_destination(brief.user_id),
             origin_type: "brief",
             origin_id: brief.id,
             dedupe_key: "brief:#{brief.id}",
             title: brief.title,
             body: payload.text,
             urgency: 0.7,
             interrupt_now: true,
             why_now: brief.summary,
             structured_data:
               brief_structured_data(brief)
               |> Map.put("message_class", "todo_digest")
               |> Map.put("todo_ids", Enum.map(todos, & &1.id))
               |> Map.put("todo_count", length(todos)),
             conversation_metadata:
               brief_conversation_metadata(brief)
               |> Map.put("brief_cadence", brief.cadence),
             telegram_opts: [parse_mode: "HTML", reply_markup: payload.reply_markup]
           }) do
        {:ok, %{decision: "sent_now", message_id: message_id}} ->
          mark_brief_sent(brief, message_id)
          :ok

        {:ok, %{decision: decision}} when decision in ["suppressed", "merged", "queued_digest"] ->
          :ok

        {:error, reason} ->
          mark_brief_failed(brief, reason)
          {:error, reason}
      end
    end
  end

  defp mark_brief_sent(%Brief{} = brief, message_id) do
    brief
    |> Ecto.Changeset.change(%{
      status: "sent",
      sent_at: DateTime.utc_now(),
      provider_message_id: message_id,
      error_message: nil
    })
    |> Repo.update()
  end

  defp mark_brief_failed(%Brief{} = brief, reason) do
    brief
    |> Ecto.Changeset.change(%{
      status: "failed",
      error_message: inspect(reason)
    })
    |> Repo.update()
  end
end
