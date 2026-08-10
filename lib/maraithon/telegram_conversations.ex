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

  # A pending confirmation/clarification older than this is considered
  # abandoned. An unrelated later message must not attach to it and bleed its
  # stale context — see `open_pending_confirmation/2` and
  # `open_pending_clarification/1`.
  @awaiting_state_freshness_seconds 10 * 60

  @doc false
  def hydrate(%Conversation{} = conversation), do: Conversation.hydrate(conversation)
  def hydrate(%Turn{} = turn), do: Turn.hydrate(turn)
  def hydrate(other), do: other

  def start_or_continue(user_id, chat_id, attrs \\ %{})
      when is_binary(user_id) and is_binary(chat_id) and is_map(attrs) do
    metadata = read_map(attrs, "metadata")
    surface = read_string(attrs, "surface", "telegram")
    mode = read_string(attrs, "mode") || read_string(metadata, "mode")
    linked_delivery_id = read_string(attrs, "linked_delivery_id")
    linked_insight_id = read_string(attrs, "linked_insight_id")
    reply_to_message_id = read_string(attrs, "reply_to_message_id")
    root_message_id = read_string(attrs, "root_message_id", reply_to_message_id)
    confirmation_reply? = read_bool(attrs, "confirmation_reply", false)
    # Default false, matching the confirmation path: a caller that doesn't
    # explicitly compute whether this message looks like an answer to a
    # pending clarification (e.g. a push landing via `PushBroker`) must not
    # silently attach to — and keep alive — a stale
    # `pending_clarification` conversation. Only `TelegramRouter`, which
    # inspects the inbound text, should opt in.
    clarification_reply? = read_bool(attrs, "clarification_reply", false)
    now = DateTime.utc_now()

    conversation =
      if mode == "push_thread" and is_nil(reply_to_message_id) and is_nil(linked_delivery_id) and
           is_nil(linked_insight_id) do
        nil
      else
        # Each top-level ask gets its own conversation row. A webhook retry is
        # the one exception: Telegram's source message id is the durable root,
        # so the same `(chat_id, root_message_id)` must re-enter the original
        # conversation and its resumable Run instead of minting a parallel
        # thread. The database unique index is the final race barrier; this
        # lookup is the normal retry path.
        find_by_root(chat_id, root_message_id) ||
          find_by_reply(chat_id, reply_to_message_id) ||
          open_pending_confirmation(chat_id, confirmation_reply?) ||
          open_pending_clarification(chat_id, clarification_reply?) ||
          find_open_linked(chat_id, linked_delivery_id, linked_insight_id)
      end

    case conversation do
      %Conversation{} = existing ->
        existing
        |> Conversation.changeset(%{
          status: existing.status,
          surface: existing.surface || surface,
          last_turn_at: now,
          root_message_id: existing.root_message_id || root_message_id,
          linked_delivery_id: existing.linked_delivery_id || linked_delivery_id,
          linked_insight_id: existing.linked_insight_id || linked_insight_id,
          metadata: Map.merge(existing.metadata || %{}, read_map(attrs, "metadata"))
        })
        |> Repo.update()
        |> hydrate_conversation_result()

      nil ->
        changeset =
          Conversation.changeset(%Conversation{}, %{
            user_id: user_id,
            chat_id: chat_id,
            surface: surface,
            root_message_id: root_message_id,
            linked_delivery_id: linked_delivery_id,
            linked_insight_id: linked_insight_id,
            status: "open",
            last_turn_at: now,
            metadata: metadata
          })

        case Repo.insert(changeset) do
          {:ok, conversation} ->
            {:ok, Conversation.hydrate(conversation)}

          {:error, changeset} = error ->
            # Two workers can race before either sees the root lookup. Reuse
            # the winner on the unique conflict; every other insert failure
            # remains visible to the caller.
            if is_binary(root_message_id) and root_conflict?(changeset) do
              case find_by_root(chat_id, root_message_id) do
                %Conversation{} = conversation -> {:ok, conversation}
                nil -> error
              end
            else
              error
            end
        end
    end
  end

  def create_mobile_thread(user_id, attrs \\ %{}) when is_binary(user_id) and is_map(attrs) do
    client_thread_id = read_string(attrs, "client_thread_id") || Ecto.UUID.generate()
    title = read_string(attrs, "title", "New conversation")
    chat_id = "mobile:#{user_id}:#{client_thread_id}"
    root_message_id = read_string(attrs, "root_message_id")
    now = DateTime.utc_now()

    metadata =
      attrs
      |> read_map("metadata")
      |> Map.merge(%{
        "mobile_thread" => true,
        "client_thread_id" => client_thread_id,
        "title" => title,
        "last_mobile_run_id" => nil
      })

    %Conversation{}
    |> Conversation.changeset(%{
      user_id: user_id,
      chat_id: chat_id,
      surface: "mobile",
      root_message_id: root_message_id,
      status: "open",
      last_turn_at: now,
      metadata: metadata
    })
    |> Repo.insert()
    |> hydrate_conversation_result()
  end

  def get_mobile_thread_for_todo(user_id, todo_id)
      when is_binary(user_id) and is_binary(todo_id) do
    root_message_id = "todo:#{todo_id}"
    client_thread_id = "todo-#{todo_id}"
    chat_id = "mobile:#{user_id}:#{client_thread_id}"

    Conversation
    |> where([c], c.user_id == ^user_id and c.surface == "mobile")
    |> where(
      [c],
      c.root_message_id == ^root_message_id or
        c.chat_id == ^chat_id or
        fragment("?->>'linked_todo_id' = ?", c.metadata, ^todo_id)
    )
    |> order_by([c], desc_nulls_last: c.last_turn_at, desc: c.updated_at)
    |> preload(:turns)
    |> limit(1)
    |> Repo.one()
    |> Conversation.hydrate()
  end

  def get_mobile_thread_for_todo(_user_id, _todo_id), do: nil

  def list_mobile_threads(user_id, opts \\ []) when is_binary(user_id) do
    limit = opts |> Keyword.get(:limit, 50) |> max(1) |> min(100)

    Conversation
    |> where([c], c.user_id == ^user_id and c.surface == "mobile")
    |> order_by([c], desc_nulls_last: c.last_turn_at, desc: c.updated_at)
    |> limit(^limit)
    |> preload(:turns)
    |> Repo.all()
    |> Enum.map(&Conversation.hydrate/1)
  end

  def get_mobile_thread(user_id, conversation_id)
      when is_binary(user_id) and is_binary(conversation_id) do
    Conversation
    |> where([c], c.user_id == ^user_id and c.id == ^conversation_id and c.surface == "mobile")
    |> preload(:turns)
    |> Repo.one()
    |> Conversation.hydrate()
  end

  def latest_run_for_conversation(conversation_id) when is_binary(conversation_id) do
    Maraithon.TelegramAssistant.Run
    |> where([run], run.conversation_id == ^conversation_id)
    |> order_by([run], desc: run.started_at)
    |> limit(1)
    |> Repo.one()
    |> Maraithon.TelegramAssistant.Run.hydrate_payloads()
  end

  def active_run_for_conversation(conversation_id) when is_binary(conversation_id) do
    Maraithon.TelegramAssistant.Run
    |> where([run], run.conversation_id == ^conversation_id)
    |> where([run], run.status in ["queued", "running", "waiting_confirmation"])
    |> order_by([run], desc: run.started_at)
    |> limit(1)
    |> Repo.one()
    |> Maraithon.TelegramAssistant.Run.hydrate_payloads()
  end

  @doc """
  Appends a turn to a conversation.

  Idempotent for both Telegram provider message ids and deterministic local
  client message ids. The latter is used by mobile and checkpointed delivery
  drains to reserve exactly one local turn even when two retries race.
  """
  def append_turn(%Conversation{} = conversation, attrs) when is_map(attrs) do
    case append_turn_with_status(conversation, attrs) do
      {:ok, {conversation, turn, _insert_status}} -> {:ok, {conversation, turn}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc false
  def append_turn_with_status(%Conversation{} = conversation, attrs) when is_map(attrs) do
    now = DateTime.utc_now()
    telegram_message_id = read_string(attrs, "telegram_message_id")
    client_message_id = read_string(attrs, "client_message_id")

    Repo.transaction(fn ->
      case insert_or_reuse_turn(conversation, attrs, telegram_message_id, client_message_id) do
        {:ok, turn, :inserted} ->
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

          {updated_conversation, turn, :inserted, operator_event}

        {:ok, turn, :reused} ->
          {conversation, turn, :reused, nil}

        {:error, changeset} ->
          Repo.rollback(changeset)
      end
    end)
    |> case do
      {:ok, {conversation, turn, status, nil}} ->
        {:ok, {conversation, turn, status}}

      {:ok, {conversation, turn, status, operator_event}} ->
        :ok = OperatorBus.broadcast(operator_event)
        {:ok, {conversation, turn, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  True when a completed assistant reply turn already exists for the given
  inbound Telegram message id in this chat.

  Every reply flow (`TelegramRouter.send_assistant_turn/5`,
  `TelegramAssistant.handle_inbound/1`, the runner, etc.) stamps the
  assistant turn's `reply_to_message_id` with the inbound message id it
  answered. A caught failure's fallback apology is sent directly via
  `TelegramResponder` and is *not* recorded as a turn, so this only reports
  true when the run actually produced its user-visible answer — used by
  `ChatWorker` to skip reprocessing a Telegram webhook retry whose first
  attempt already completed (so non-idempotent tool side effects don't
  double-fire), without building a general idempotency framework.
  """
  def assistant_reply_recorded?(chat_id, telegram_message_id)
      when is_binary(chat_id) and is_binary(telegram_message_id) do
    # A terminal turn tagged with a Runner run id is only completion evidence
    # once that Run's ledger is terminal too. If the process died after the
    # turn commit but before `complete_run/2`, durable ingress must re-enter
    # the checkpoint drain instead of skipping reconciliation.
    Turn
    |> join(:inner, [turn], conversation in assoc(turn, :conversation))
    |> where(
      [turn, conversation],
      conversation.chat_id == ^chat_id and turn.role == "assistant" and
        turn.reply_to_message_id == ^telegram_message_id and
        (is_nil(turn.terminal_response) or turn.terminal_response == true) and
        (conversation.status != "awaiting_confirmation" or turn.turn_kind != "action_result")
    )
    |> select([turn, _conversation], turn)
    |> Repo.all()
    |> Enum.map(&Turn.hydrate/1)
    |> Enum.any?(fn turn ->
      Turn.effective_terminal_response(turn) and
        terminal_turn_run_reconciled?(Turn.effective_assistant_run_id(turn))
    end)
  end

  def assistant_reply_recorded?(_chat_id, _telegram_message_id), do: false

  defp terminal_turn_run_reconciled?(run_id) when is_binary(run_id) do
    with {:ok, run_id} <- Ecto.UUID.cast(run_id),
         %Maraithon.TelegramAssistant.Run{
           status: status,
           finished_at: %DateTime{}
         }
         when status in ["completed", "waiting_confirmation", "degraded"] <-
           Repo.get(Maraithon.TelegramAssistant.Run, run_id) do
      true
    else
      _invalid_incomplete_or_missing -> false
    end
  end

  defp terminal_turn_run_reconciled?(_legacy_turn_without_run), do: true

  defp insert_or_reuse_turn(conversation, attrs, telegram_message_id, client_message_id) do
    %Turn{}
    |> Turn.changeset(Map.merge(attrs, %{"conversation_id" => conversation.id}))
    # The savepoint keeps the surrounding transaction usable after the
    # expected unique conflict so we can fetch the winning reservation.
    |> Repo.insert(mode: :savepoint)
    |> case do
      {:ok, turn} ->
        {:ok, Turn.hydrate(turn), :inserted}

      {:error, changeset} ->
        cond do
          is_binary(telegram_message_id) and
              unique_constraint_error?(changeset, :telegram_message_id) ->
            reuse_turn(conversation.id, :telegram_message_id, telegram_message_id, changeset)

          is_binary(client_message_id) and
              unique_constraint_error?(changeset, :client_message_id) ->
            reuse_turn(conversation.id, :client_message_id, client_message_id, changeset)

          true ->
            {:error, changeset}
        end
    end
  end

  defp reuse_turn(conversation_id, field, value, changeset) do
    case Repo.get_by(Turn, [{:conversation_id, conversation_id}, {field, value}]) do
      %Turn{} = existing -> {:ok, Turn.hydrate(existing), :reused}
      nil -> {:error, changeset}
    end
  end

  @telegram_message_id_constraint_name "telegram_conversation_turns_conversation_id_telegram_message_id"
  @client_message_id_constraint_name "telegram_conversation_turns_conversation_id_client_message_id_i"

  defp unique_constraint_error?(changeset, field)
       when field in [:telegram_message_id, :client_message_id] do
    expected_name =
      case field do
        :telegram_message_id -> @telegram_message_id_constraint_name
        :client_message_id -> @client_message_id_constraint_name
      end

    Enum.any?(changeset.errors, fn
      {^field, {_message, opts}} ->
        Keyword.get(opts, :constraint) == :unique and
          Keyword.get(opts, :constraint_name) == expected_name

      _other ->
        false
    end)
  end

  defp unique_constraint_error?(_changeset, _field), do: false

  def update_turn_text(chat_id, telegram_message_id, text)
      when is_binary(chat_id) and is_binary(telegram_message_id) and is_binary(text) do
    with %Conversation{} = conversation <- find_by_message(chat_id, telegram_message_id),
         %Turn{} = turn <-
           Repo.get_by(Turn,
             conversation_id: conversation.id,
             telegram_message_id: telegram_message_id
           ),
         {:ok, turn} <- turn |> Turn.hydrate() |> Turn.changeset(%{text: text}) |> Repo.update() do
      {:ok, Turn.hydrate(turn)}
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
    |> Conversation.hydrate()
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
    |> Turn.hydrate()
  end

  def find_turn_by_message(_chat_id, _telegram_message_id), do: nil

  def find_turn_by_client_message_id(conversation_id, client_message_id)
      when is_binary(conversation_id) and is_binary(client_message_id) do
    Turn
    |> where([turn], turn.conversation_id == ^conversation_id)
    |> where([turn], turn.client_message_id == ^client_message_id)
    |> order_by([turn], desc: turn.inserted_at)
    |> limit(1)
    |> Repo.one()
    |> Turn.hydrate()
  end

  def find_turn_by_client_message_id(_conversation_id, _client_message_id), do: nil

  def delete_turn(%Conversation{} = conversation, turn_id) when is_binary(turn_id) do
    with %Turn{} = turn <- Repo.get_by(Turn, id: turn_id, conversation_id: conversation.id) do
      Repo.transaction(fn ->
        Repo.delete!(turn)

        last_turn_at =
          Turn
          |> where([t], t.conversation_id == ^conversation.id)
          |> select([t], max(t.inserted_at))
          |> Repo.one()

        conversation
        |> Conversation.changeset(%{
          last_turn_at: last_turn_at || DateTime.utc_now(),
          summary: summarize_recent_turns(conversation.id)
        })
        |> Repo.update!()
      end)
      |> case do
        {:ok, updated_conversation} -> {:ok, Conversation.hydrate(updated_conversation)}
        {:error, reason} -> {:error, reason}
      end
    else
      nil -> {:error, :not_found}
    end
  end

  def delete_turn(_conversation, _turn_id), do: {:error, :not_found}

  def find_by_root(chat_id, root_message_id)
      when is_binary(chat_id) and is_binary(root_message_id) do
    Conversation
    |> where([conversation], conversation.chat_id == ^chat_id)
    |> where([conversation], conversation.root_message_id == ^root_message_id)
    |> preload([:linked_delivery, :linked_insight, :turns])
    |> limit(1)
    |> Repo.one()
    |> Conversation.hydrate()
  end

  def find_by_root(_chat_id, _root_message_id), do: nil

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
    |> Conversation.hydrate()
  end

  @doc """
  Finds the chat's open `awaiting_confirmation` conversation, if any is fresh
  enough and this message looks like it's actually answering it.

  `confirmation_reply?` should be true when the inbound text is a
  recognizable yes/no answer (see `TelegramRouter`'s `affirmative?/1` and
  `negative?/1`). A stale conversation (older than
  `@awaiting_state_freshness_seconds`) is expired back to `"open"` and never
  attached to. A fresh-but-unrelated message (not a recognizable yes/no) is
  left alone but also not attached to — the caller starts a new conversation
  instead, so the stale thread doesn't bleed its context into an unrelated
  ask.
  """
  # Shared note for `open_pending_confirmation/2` and
  # `open_pending_clarification/2`: within the freshness window, ANY inbound
  # message used to attach to a pending awaiting-state conversation and
  # inherit its turns, even when the text had nothing to do with the pending
  # question. Both now take a `*_reply?` gate so an unrelated new ask starts
  # a fresh conversation instead of bleeding into the stale one.
  def open_pending_confirmation(chat_id, confirmation_reply? \\ true) when is_binary(chat_id) do
    Conversation
    |> where([c], c.chat_id == ^chat_id and c.status == "awaiting_confirmation")
    |> order_by([c], desc: c.updated_at)
    |> preload([:linked_delivery, :linked_insight, :turns])
    |> limit(1)
    |> Repo.one()
    |> Conversation.hydrate()
    |> resolve_pending_confirmation(confirmation_reply?)
  end

  defp resolve_pending_confirmation(nil, _confirmation_reply?), do: nil

  defp resolve_pending_confirmation(%Conversation{} = conversation, confirmation_reply?) do
    cond do
      stale_awaiting_state?(conversation) ->
        _ = expire_stale_awaiting_confirmation(conversation)
        nil

      confirmation_reply? ->
        conversation

      true ->
        nil
    end
  end

  defp expire_stale_awaiting_confirmation(%Conversation{} = conversation) do
    conversation
    |> Conversation.changeset(%{
      status: "open",
      metadata:
        Map.merge(conversation.metadata || %{}, %{
          "expired_awaiting_confirmation" => true,
          "expired_at" => DateTime.to_iso8601(DateTime.utc_now())
        })
    })
    |> Repo.update()
  end

  # The user is answering a clarifying question the bot asked — continue that
  # thread instead of opening a new one, unless it's gone stale or this
  # message doesn't actually look like an answer.
  #
  # `clarification_reply?` should be true when the inbound text is a
  # recognizable answer to the pending clarifying question (see
  # `TelegramRouter`'s `clarification_reply?/1`). Unlike a confirmation, a
  # clarification answer isn't a fixed yes/no vocabulary — it can be any
  # short direct reply — so the gate only rejects text that looks like a
  # fresh, unrelated ask (a slash command, or a long multi-sentence message)
  # rather than requiring an exact match. A fresh-but-unrelated message is
  # left alone but not attached to — the caller starts a new conversation
  # instead, so the stale thread doesn't bleed its context into an unrelated
  # ask.
  defp open_pending_clarification(chat_id, clarification_reply?)
       when is_binary(chat_id) do
    Conversation
    |> where([c], c.chat_id == ^chat_id and c.status == "open")
    |> where([c], fragment("? @> ?", c.metadata, ^%{"pending_clarification" => true}))
    |> order_by([c], desc: c.updated_at)
    |> preload([:linked_delivery, :linked_insight, :turns])
    |> limit(1)
    |> Repo.one()
    |> Conversation.hydrate()
    |> resolve_pending_clarification(clarification_reply?)
  end

  defp resolve_pending_clarification(nil, _clarification_reply?), do: nil

  defp resolve_pending_clarification(%Conversation{} = conversation, clarification_reply?) do
    cond do
      stale_awaiting_state?(conversation) ->
        _ =
          update_metadata(conversation, %{
            "pending_clarification" => false,
            "clarification_expired_at" => DateTime.to_iso8601(DateTime.utc_now())
          })

        nil

      clarification_reply? ->
        conversation

      true ->
        nil
    end
  end

  defp stale_awaiting_state?(%Conversation{} = conversation) do
    reference_time =
      conversation.last_turn_at || conversation.updated_at || conversation.inserted_at

    case reference_time do
      %DateTime{} = value ->
        DateTime.diff(DateTime.utc_now(), value, :second) > @awaiting_state_freshness_seconds

      _ ->
        false
    end
  end

  def mark_awaiting_confirmation(%Conversation{} = conversation, attrs \\ %{}) do
    conversation
    |> Conversation.changeset(%{
      status: "awaiting_confirmation",
      metadata: Map.merge(conversation.metadata || %{}, read_map(attrs, "metadata"))
    })
    |> Repo.update()
    |> hydrate_conversation_result()
  end

  def update_metadata(%Conversation{} = conversation, attrs) when is_map(attrs) do
    conversation
    |> Conversation.changeset(%{
      metadata: Map.merge(conversation.metadata || %{}, attrs)
    })
    |> Repo.update()
    |> hydrate_conversation_result()
  end

  def reopen(%Conversation{} = conversation) do
    conversation
    |> Conversation.changeset(%{status: "open"})
    |> Repo.update()
    |> hydrate_conversation_result()
  end

  def close(%Conversation{} = conversation, attrs \\ %{}) do
    conversation
    |> Conversation.changeset(%{
      status: "closed",
      summary: read_string(attrs, "summary", conversation.summary),
      metadata: Map.merge(conversation.metadata || %{}, read_map(attrs, "metadata"))
    })
    |> Repo.update()
    |> hydrate_conversation_result()
  end

  def recent_turns(%Conversation{} = conversation, opts \\ []) do
    limit = Keyword.get(opts, :limit, 8)

    Turn
    |> where([t], t.conversation_id == ^conversation.id)
    |> order_by([t], desc: t.inserted_at)
    |> limit(^limit)
    |> Repo.all()
    |> Enum.map(&Turn.hydrate/1)
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
  def compact_old_turns(conversation, opts \\ [])

  def compact_old_turns(%Conversation{} = conversation, opts) do
    keep_recent = Keyword.get(opts, :keep_recent, 12)
    threshold_extra = Keyword.get(opts, :threshold_extra, 12)
    turn_threshold = keep_recent + threshold_extra
    token_threshold = Keyword.get(opts, :token_threshold, 30_000)
    llm_complete = Keyword.get(opts, :llm_complete, &default_summary_llm/1)

    total = count_turns(conversation.id)
    tokens_estimate = estimate_conversation_tokens(conversation.id)

    over_turn_budget? = total > turn_threshold
    over_token_budget? = total > keep_recent and tokens_estimate >= token_threshold

    cond do
      over_turn_budget? or over_token_budget? ->
        do_compact_old_turns(conversation, total, keep_recent, llm_complete)

      true ->
        {:ok, conversation}
    end
  end

  def compact_old_turns(_conversation, _opts), do: {:error, :invalid_conversation}

  defp estimate_conversation_tokens(conversation_id) do
    Turn
    |> where([t], t.conversation_id == ^conversation_id)
    |> select([t], sum(coalesce(t.text_bytes, 0)))
    |> Repo.one()
    |> case do
      nil -> 0
      bytes when is_integer(bytes) -> div(bytes, 4)
      _other -> 0
    end
  end

  defp do_compact_old_turns(conversation, total, keep_recent, llm_complete) do
    drop_count = max(total - keep_recent, 0)

    older_turns =
      Turn
      |> where([t], t.conversation_id == ^conversation.id)
      |> order_by([t], asc: t.inserted_at)
      |> limit(^drop_count)
      |> Repo.all()
      |> Enum.map(&Turn.hydrate/1)

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
    You are summarizing the older portion of a Telegram chat between the operator and their assistant.
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

  def preload(%Conversation{} = conversation) do
    conversation
    |> Repo.preload([:turns, :linked_delivery, :linked_insight])
    |> Conversation.hydrate()
  end

  def latest_for_chat(chat_id) when is_binary(chat_id) do
    Conversation
    |> where([c], c.chat_id == ^chat_id)
    |> order_by([c], desc: c.updated_at)
    |> preload([:linked_delivery, :linked_insight, :turns])
    |> limit(1)
    |> Repo.one()
    |> Conversation.hydrate()
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
      |> Conversation.hydrate()
    end
  end

  defp summarize_recent_turns(conversation_id) do
    Turn
    |> where([t], t.conversation_id == ^conversation_id)
    |> order_by([t], desc: t.inserted_at)
    |> limit(6)
    |> Repo.all()
    |> Enum.map(&Turn.hydrate/1)
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
        "turn_kind" => turn.turn_kind,
        "origin_type" => turn.origin_type,
        "telegram_message_id" => turn.telegram_message_id,
        "reply_to_message_id" => turn.reply_to_message_id,
        "intent" => turn.intent,
        "confidence" => turn.confidence,
        "text_bytes" => turn.text_bytes,
        "assistant_run_id" => turn.assistant_run_id,
        "message_class" => turn.message_class,
        "prepared_action_id" => turn.prepared_action_id,
        "linked_todo_id" => turn.linked_todo_id,
        "terminal_response" => turn.terminal_response
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

  defp hydrate_conversation_result({:ok, %Conversation{} = conversation}),
    do: {:ok, Conversation.hydrate(conversation)}

  defp hydrate_conversation_result(other), do: other

  defp root_conflict?(changeset) do
    Enum.any?(changeset.errors, fn
      {_field, {_message, opts}} ->
        Keyword.get(opts, :constraint) == :unique and
          Keyword.get(opts, :constraint_name) ==
            "telegram_conversations_chat_id_root_message_id_index"

      _other ->
        false
    end)
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

  defp read_bool(map, key, default) when is_map(map) do
    case fetch(map, key) do
      true -> true
      false -> false
      "true" -> true
      "false" -> false
      _ -> default
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
