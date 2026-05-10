defmodule Maraithon.TelegramConversations do
  @moduledoc """
  Persistence and lookup for Telegram conversations and turns.
  """

  import Ecto.Query

  alias Maraithon.InsightNotifications.Delivery
  alias Maraithon.OperatorBus
  alias Maraithon.OperatorEvents
  alias Maraithon.Repo
  alias Maraithon.TelegramConversations.{Conversation, Turn}

  @general_idle_seconds 24 * 60 * 60
  @linked_idle_seconds 7 * 24 * 60 * 60

  def start_or_continue(user_id, chat_id, attrs \\ %{})
      when is_binary(user_id) and is_binary(chat_id) and is_map(attrs) do
    metadata = read_map(attrs, "metadata")
    mode = read_string(attrs, "mode") || read_string(metadata, "mode")
    linked_delivery_id = read_string(attrs, "linked_delivery_id")
    linked_insight_id = read_string(attrs, "linked_insight_id")
    reply_to_message_id = read_string(attrs, "reply_to_message_id")
    root_message_id = read_string(attrs, "root_message_id", reply_to_message_id)
    now = DateTime.utc_now()

    conversation =
      if mode == "push_thread" and is_nil(reply_to_message_id) and is_nil(linked_delivery_id) and
           is_nil(linked_insight_id) do
        nil
      else
        find_by_reply(chat_id, reply_to_message_id) ||
          open_pending_confirmation(chat_id) ||
          find_open_linked(chat_id, linked_delivery_id, linked_insight_id) ||
          find_recent_general(chat_id, now)
      end

    case conversation do
      %Conversation{} = existing ->
        existing
        |> Conversation.changeset(%{
          status: existing.status,
          last_turn_at: now,
          root_message_id: existing.root_message_id || root_message_id,
          linked_delivery_id: existing.linked_delivery_id || linked_delivery_id,
          linked_insight_id: existing.linked_insight_id || linked_insight_id,
          metadata: Map.merge(existing.metadata || %{}, read_map(attrs, "metadata"))
        })
        |> Repo.update()

      nil ->
        %Conversation{}
        |> Conversation.changeset(%{
          user_id: user_id,
          chat_id: chat_id,
          root_message_id: root_message_id,
          linked_delivery_id: linked_delivery_id,
          linked_insight_id: linked_insight_id,
          status: "open",
          last_turn_at: now,
          metadata: metadata
        })
        |> Repo.insert()
    end
  end

  def append_turn(%Conversation{} = conversation, attrs) when is_map(attrs) do
    now = DateTime.utc_now()

    Repo.transaction(fn ->
      turn =
        %Turn{}
        |> Turn.changeset(
          Map.merge(attrs, %{
            "conversation_id" => conversation.id
          })
        )
        |> Repo.insert!()

      updated_conversation =
        conversation
        |> Conversation.changeset(%{
          last_turn_at: now,
          last_intent: read_string(attrs, "intent", conversation.last_intent),
          summary: summarize_recent_turns(conversation.id)
        })
        |> Repo.update!()

      {:ok, operator_event} =
        OperatorEvents.record(turn_operator_event_attrs(updated_conversation, turn, now))

      {updated_conversation, turn, operator_event}
    end)
    |> case do
      {:ok, {conversation, turn, operator_event}} ->
        :ok = OperatorBus.broadcast(operator_event)
        {:ok, {conversation, turn}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def update_turn_text(chat_id, telegram_message_id, text)
      when is_binary(chat_id) and is_binary(telegram_message_id) and is_binary(text) do
    with %Conversation{} = conversation <- find_by_message(chat_id, telegram_message_id),
         %Turn{} = turn <-
           Repo.get_by(Turn,
             conversation_id: conversation.id,
             telegram_message_id: telegram_message_id
           ),
         {:ok, turn} <- turn |> Turn.changeset(%{text: text}) |> Repo.update() do
      {:ok, turn}
    else
      nil -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  def find_by_message(chat_id, telegram_message_id)
      when is_binary(chat_id) and is_binary(telegram_message_id) do
    Conversation
    |> join(:inner, [c], t in assoc(c, :turns))
    |> where([c, t], c.chat_id == ^chat_id and t.telegram_message_id == ^telegram_message_id)
    |> preload([_c, t], [:linked_delivery, :linked_insight, turns: t])
    |> order_by([c, _t], desc: c.updated_at)
    |> limit(1)
    |> Repo.one()
  end

  def find_turn_by_message(chat_id, telegram_message_id)
      when is_binary(chat_id) and is_binary(telegram_message_id) do
    Turn
    |> join(:inner, [turn], conversation in assoc(turn, :conversation))
    |> where(
      [turn, conversation],
      conversation.chat_id == ^chat_id and turn.telegram_message_id == ^telegram_message_id
    )
    |> order_by([turn, _conversation], desc: turn.inserted_at)
    |> limit(1)
    |> Repo.one()
  end

  def find_turn_by_message(_chat_id, _telegram_message_id), do: nil

  def find_by_reply(chat_id, reply_to_message_id)
      when is_binary(chat_id) and is_binary(reply_to_message_id) do
    chat_id
    |> find_by_message(reply_to_message_id)
    |> active_reply_conversation()
  end

  def find_by_reply(_chat_id, _reply_to_message_id), do: nil

  def find_by_delivery(delivery_id) when is_binary(delivery_id) do
    Conversation
    |> where([c], c.linked_delivery_id == ^delivery_id)
    |> order_by([c], desc: c.updated_at)
    |> preload(:turns)
    |> limit(1)
    |> Repo.one()
  end

  def open_pending_confirmation(chat_id) when is_binary(chat_id) do
    Conversation
    |> where([c], c.chat_id == ^chat_id and c.status == "awaiting_confirmation")
    |> order_by([c], desc: c.updated_at)
    |> preload([:linked_delivery, :linked_insight, :turns])
    |> limit(1)
    |> Repo.one()
  end

  def mark_awaiting_confirmation(%Conversation{} = conversation, attrs \\ %{}) do
    conversation
    |> Conversation.changeset(%{
      status: "awaiting_confirmation",
      metadata: Map.merge(conversation.metadata || %{}, read_map(attrs, "metadata"))
    })
    |> Repo.update()
  end

  def update_metadata(%Conversation{} = conversation, attrs) when is_map(attrs) do
    conversation
    |> Conversation.changeset(%{
      metadata: Map.merge(conversation.metadata || %{}, attrs)
    })
    |> Repo.update()
  end

  def reopen(%Conversation{} = conversation) do
    conversation
    |> Conversation.changeset(%{status: "open"})
    |> Repo.update()
  end

  def close(%Conversation{} = conversation, attrs \\ %{}) do
    conversation
    |> Conversation.changeset(%{
      status: "closed",
      summary: read_string(attrs, "summary", conversation.summary),
      metadata: Map.merge(conversation.metadata || %{}, read_map(attrs, "metadata"))
    })
    |> Repo.update()
  end

  def recent_turns(%Conversation{} = conversation, opts \\ []) do
    limit = Keyword.get(opts, :limit, 8)

    Turn
    |> where([t], t.conversation_id == ^conversation.id)
    |> order_by([t], desc: t.inserted_at)
    |> limit(^limit)
    |> Repo.all()
    |> Enum.reverse()
  end

  @doc """
  When a conversation grows past `keep_recent + threshold_extra` turns, fold
  the oldest turns into a single text summary stored in
  `conversation.metadata["historical_summary"]`. The recent N turns are still
  returned by `recent_turns/2`.

  This is best-effort and silent on failure: any LLM/DB error keeps the
  conversation as-is so the assistant loop never blocks on summarization.
  """
  def compact_old_turns(%Conversation{} = conversation, opts \\ []) do
    keep_recent = Keyword.get(opts, :keep_recent, 12)
    threshold_extra = Keyword.get(opts, :threshold_extra, 12)
    threshold = keep_recent + threshold_extra
    llm_complete = Keyword.get(opts, :llm_complete, &default_summary_llm/1)

    total = count_turns(conversation.id)

    if total > threshold do
      do_compact_old_turns(conversation, total, keep_recent, llm_complete)
    else
      {:ok, conversation}
    end
  end

  def compact_old_turns(_conversation, _opts), do: {:error, :invalid_conversation}

  defp do_compact_old_turns(conversation, total, keep_recent, llm_complete) do
    drop_count = max(total - keep_recent, 0)

    older_turns =
      Turn
      |> where([t], t.conversation_id == ^conversation.id)
      |> order_by([t], asc: t.inserted_at)
      |> limit(^drop_count)
      |> Repo.all()

    case build_history_summary(older_turns, conversation, llm_complete) do
      {:ok, summary_text} when is_binary(summary_text) and summary_text != "" ->
        through =
          case List.last(older_turns) do
            nil -> nil
            %Turn{inserted_at: at} -> DateTime.to_iso8601(at)
          end

        update_metadata(conversation, %{
          "historical_summary" => summary_text,
          "historical_summary_through" => through
        })

      _other ->
        {:ok, conversation}
    end
  end

  defp count_turns(conversation_id) do
    Turn
    |> where([t], t.conversation_id == ^conversation_id)
    |> select([t], count(t.id))
    |> Repo.one()
    |> Kernel.||(0)
  end

  defp build_history_summary([], _conversation, _llm_complete), do: {:ok, nil}

  defp build_history_summary(turns, conversation, llm_complete) do
    transcript =
      Enum.map_join(turns, "\n", fn turn ->
        "#{turn.role}: #{String.slice(turn.text || "", 0, 400)}"
      end)

    prior_summary =
      conversation.metadata
      |> Kernel.||(%{})
      |> Map.get("historical_summary", "")

    prompt = """
    You are summarizing the older portion of a Telegram chat between Kent and his assistant.
    Produce a tight 4-6 sentence summary of facts, decisions, and unresolved threads from this transcript.
    Preserve names, dates, and outstanding requests. Do not editorialize. Do not add fluff.

    Existing prior summary (may be empty):
    #{prior_summary}

    New older transcript:
    #{transcript}

    Return only the summary text.
    """

    params = %{
      "messages" => [%{"role" => "user", "content" => prompt}],
      "max_tokens" => 400,
      "temperature" => 0.0
    }

    case llm_complete.(params) do
      {:ok, %{content: content}} when is_binary(content) and content != "" ->
        {:ok, String.trim(content)}

      _other ->
        {:error, :summary_failed}
    end
  rescue
    _ -> {:error, :summary_failed}
  end

  defp default_summary_llm(params), do: Maraithon.LLM.complete_routing(params)

  def preload(%Conversation{} = conversation),
    do: Repo.preload(conversation, [:turns, :linked_delivery, :linked_insight])

  def latest_for_chat(chat_id) when is_binary(chat_id) do
    Conversation
    |> where([c], c.chat_id == ^chat_id)
    |> order_by([c], desc: c.updated_at)
    |> preload([:linked_delivery, :linked_insight, :turns])
    |> limit(1)
    |> Repo.one()
  end

  def latest_delivery_for_chat(chat_id) when is_binary(chat_id) do
    Delivery
    |> where([d], d.channel == "telegram" and d.destination == ^chat_id)
    |> order_by([d], desc: d.inserted_at)
    |> preload(:insight)
    |> limit(1)
    |> Repo.one()
  end

  def recent_user_turn_count(chat_id, window_seconds \\ @general_idle_seconds)
      when is_binary(chat_id) and is_integer(window_seconds) and window_seconds > 0 do
    threshold = DateTime.add(DateTime.utc_now(), -window_seconds, :second)

    Turn
    |> join(:inner, [turn], conversation in assoc(turn, :conversation))
    |> where([turn, conversation], conversation.chat_id == ^chat_id and turn.role == "user")
    |> where([turn, _conversation], turn.inserted_at >= ^threshold)
    |> select([turn, _conversation], count(turn.id))
    |> Repo.one()
    |> Kernel.||(0)
  end

  defp find_open_linked(chat_id, delivery_id, insight_id) do
    if is_nil(delivery_id) and is_nil(insight_id) do
      nil
    else
      threshold = DateTime.add(DateTime.utc_now(), -@linked_idle_seconds, :second)

      base_query =
        Conversation
        |> where([c], c.chat_id == ^chat_id and c.status in ["open", "awaiting_confirmation"])
        |> where([c], c.updated_at >= ^threshold)

      scoped_query =
        cond do
          is_binary(delivery_id) and is_binary(insight_id) ->
            where(
              base_query,
              [c],
              c.linked_delivery_id == ^delivery_id or c.linked_insight_id == ^insight_id
            )

          is_binary(delivery_id) ->
            where(base_query, [c], c.linked_delivery_id == ^delivery_id)

          is_binary(insight_id) ->
            where(base_query, [c], c.linked_insight_id == ^insight_id)

          true ->
            base_query
        end

      scoped_query
      |> order_by([c], desc: c.updated_at)
      |> preload([:linked_delivery, :linked_insight, :turns])
      |> limit(1)
      |> Repo.one()
    end
  end

  defp find_recent_general(chat_id, now) do
    threshold = DateTime.add(now, -@general_idle_seconds, :second)

    Conversation
    |> where([c], c.chat_id == ^chat_id and c.status == "open")
    |> where([c], is_nil(c.linked_delivery_id) and is_nil(c.linked_insight_id))
    |> where([c], c.updated_at >= ^threshold)
    |> order_by([c], desc: c.updated_at)
    |> preload([:linked_delivery, :linked_insight, :turns])
    |> limit(1)
    |> Repo.one()
  end

  defp summarize_recent_turns(conversation_id) do
    Turn
    |> where([t], t.conversation_id == ^conversation_id)
    |> order_by([t], desc: t.inserted_at)
    |> limit(6)
    |> Repo.all()
    |> Enum.reverse()
    |> Enum.map_join("\n", fn turn ->
      "#{turn.role}: #{String.slice(turn.text || "", 0, 160)}"
    end)
  end

  defp turn_operator_event_attrs(conversation, turn, occurred_at) do
    %{
      user_id: conversation.user_id,
      source: "telegram",
      event_type: "conversation_turn.recorded",
      source_item_id: turn.id,
      dedupe_key: "telegram:conversation_turn.recorded:#{turn.id}",
      occurred_at: occurred_at,
      payload: %{
        "conversation_id" => conversation.id,
        "chat_id" => conversation.chat_id,
        "role" => turn.role,
        "text" => turn.text,
        "turn_kind" => turn.turn_kind,
        "origin_type" => turn.origin_type,
        "telegram_message_id" => turn.telegram_message_id,
        "reply_to_message_id" => turn.reply_to_message_id,
        "intent" => turn.intent,
        "confidence" => turn.confidence
      },
      metadata: %{
        "conversation_status" => conversation.status,
        "root_message_id" => conversation.root_message_id,
        "linked_delivery_id" => conversation.linked_delivery_id,
        "linked_insight_id" => conversation.linked_insight_id
      }
    }
  end

  defp active_reply_conversation(%Conversation{} = conversation) do
    if expired_conversation?(conversation) do
      nil
    else
      conversation
    end
  end

  defp active_reply_conversation(_), do: nil

  defp expired_conversation?(%Conversation{status: status})
       when status not in ["open", "awaiting_confirmation"],
       do: true

  defp expired_conversation?(%Conversation{status: "awaiting_confirmation"}), do: false

  defp expired_conversation?(%Conversation{} = conversation) do
    reference_time =
      conversation.last_turn_at || conversation.updated_at || conversation.inserted_at

    idle_seconds =
      if is_binary(conversation.linked_delivery_id) or is_binary(conversation.linked_insight_id) do
        @linked_idle_seconds
      else
        @general_idle_seconds
      end

    stale? =
      case reference_time do
        %DateTime{} = value -> DateTime.diff(DateTime.utc_now(), value, :second) > idle_seconds
        _ -> false
      end

    resolved? =
      case conversation.linked_insight do
        %{status: status} when status in ["acknowledged", "dismissed"] -> true
        _ -> false
      end

    stale? or resolved?
  end

  defp read_string(map, key, default \\ nil) when is_map(map) do
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

  defp read_map(map, key) when is_map(map) do
    case fetch(map, key) do
      %{} = value -> value
      _ -> %{}
    end
  end

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
