defmodule Maraithon.TelegramConversations.Privacy do
  @moduledoc """
  Bounded rollout and retention operations for conversation payloads.

  The schema migration is expansion-only. `backfill/1` is the explicit,
  rerunnable operator step that encrypts legacy plaintext in small locked
  batches and tombstones the old columns. `scrub_expired/1` removes only
  sensitive content, never conversation/turn identities or promoted dedupe and
  work-link facts.
  """

  import Ecto.Query

  alias Maraithon.Repo
  alias Maraithon.TelegramAssistant.{PreparedAction, Run}
  alias Maraithon.TelegramConversations.{Conversation, Turn}
  alias Maraithon.Todos.Todo

  @default_retention_days 90
  @default_batch_size 100
  @default_max_batches 20
  @max_batch_size 500
  @max_batches 1_000
  @active_run_statuses ~w(queued running waiting_confirmation)
  @terminal_action_statuses ~w(executed rejected expired failed)
  @terminal_todo_statuses ~w(done dismissed)

  def retention_days do
    :maraithon
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:retention_days, @default_retention_days)
    |> positive_integer(@default_retention_days)
  end

  @doc """
  Counts plaintext rows still requiring the explicit encryption backfill.

  This reads only presence/shape metadata in SQL; it never returns payloads.
  """
  def preflight do
    %{
      legacy_turns: Repo.aggregate(legacy_turn_query(), :count, :id),
      legacy_conversations: Repo.aggregate(legacy_conversation_query(), :count, :id)
    }
  end

  @doc """
  Runs a bounded number of idempotent encryption batches.

  Invalid oversized legacy rows are reported by ID and left untouched for
  deliberate operator handling. Successful rows are committed independently
  within each database batch and will not be selected again.
  """
  def backfill(opts \\ [])

  def backfill(opts) when is_list(opts) do
    batch_size = batch_size(opts)
    max_batches = opts |> Keyword.get(:max_batches, @default_max_batches) |> bounded_max_batches()

    Enum.reduce_while(1..max_batches, empty_backfill_result(), fn _batch, total ->
      excluded_turn_ids = Enum.map(total.blocked_turns, & &1.id)
      excluded_conversation_ids = Enum.map(total.blocked_conversations, & &1.id)

      case backfill_batch(
             batch_size: batch_size,
             exclude_turn_ids: excluded_turn_ids,
             exclude_conversation_ids: excluded_conversation_ids
           ) do
        {:ok, batch} ->
          next = merge_backfill_results(total, batch)

          processed =
            batch.migrated_turns + batch.migrated_conversations + length(batch.blocked_turns) +
              length(batch.blocked_conversations)

          if processed == 0, do: {:halt, next}, else: {:cont, next}

        {:error, reason} ->
          {:halt, Map.put(total, :error, reason)}
      end
    end)
    |> then(fn result ->
      if Map.has_key?(result, :error),
        do: {:error, result.error, Map.delete(result, :error)},
        else: {:ok, Map.put(result, :remaining, preflight())}
    end)
  end

  def backfill(_opts), do: {:error, :invalid_options}

  @doc false
  def backfill_batch(opts \\ [])

  def backfill_batch(opts) when is_list(opts) do
    limit = batch_size(opts)

    Repo.transaction(
      fn ->
        turns =
          opts
          |> Keyword.get(:exclude_turn_ids, [])
          |> legacy_turn_query()
          |> order_by([turn], asc: turn.inserted_at, asc: turn.id)
          |> limit(^limit)
          |> lock("FOR UPDATE SKIP LOCKED")
          |> Repo.all()

        conversations =
          opts
          |> Keyword.get(:exclude_conversation_ids, [])
          |> legacy_conversation_query()
          |> order_by([conversation], asc: conversation.updated_at, asc: conversation.id)
          |> limit(^limit)
          |> lock("FOR UPDATE SKIP LOCKED")
          |> Repo.all()

        {migrated_turns, blocked_turns} = backfill_turns(turns)
        {migrated_conversations, blocked_conversations} = backfill_conversations(conversations)

        %{
          batches: 1,
          migrated_turns: migrated_turns,
          migrated_conversations: migrated_conversations,
          blocked_turns: blocked_turns,
          blocked_conversations: blocked_conversations
        }
      end,
      timeout: 60_000
    )
  end

  def backfill_batch(_opts), do: {:error, :invalid_options}

  @doc """
  Scrubs one bounded retention batch.

  Only closed conversations older than the retention window qualify. A
  conversation is excluded while it has an active assistant run, a pending or
  outcome-unknown prepared action, or a linked open/snoozed todo. Rows are not
  deleted: message IDs, client IDs, source IDs, promoted run/action/todo facts,
  and OperatorEvent dedupe keys remain intact.
  """
  def scrub_expired(opts \\ [])

  def scrub_expired(opts) when is_list(opts) do
    case preflight() do
      %{legacy_turns: turns, legacy_conversations: conversations}
      when turns > 0 or conversations > 0 ->
        {:error, :legacy_backfill_required}

      _ready ->
        do_scrub_expired(opts)
    end
  end

  def scrub_expired(_opts), do: {:error, :invalid_options}

  defp do_scrub_expired(opts) do
    limit = batch_size(opts)

    days =
      opts |> Keyword.get(:retention_days, retention_days()) |> positive_integer(retention_days())

    now = Keyword.get(opts, :now, DateTime.utc_now())

    if match?(%DateTime{}, now) do
      cutoff = DateTime.add(now, -days * 86_400, :second)

      Repo.transaction(
        fn ->
          conversations =
            cutoff
            |> eligible_conversations()
            |> order_by([conversation: conversation],
              asc_nulls_first: conversation.last_turn_at,
              asc: conversation.id
            )
            |> limit(^limit)
            |> lock("FOR UPDATE SKIP LOCKED")
            |> Repo.all()

          conversation_ids = Enum.map(conversations, & &1.id)
          turn_ids = lock_unscrubbed_turn_ids(conversation_ids, cutoff, limit)
          scrubbed_turns = scrub_turn_ids(turn_ids, now)
          scrubbed_conversations = scrub_conversation_summaries(conversations, now)

          %{
            scrubbed_turns: scrubbed_turns,
            scrubbed_conversations: scrubbed_conversations,
            retained_ids: true
          }
        end,
        timeout: 60_000
      )
    else
      {:error, :invalid_now}
    end
  end

  defp legacy_turn_query(excluded_ids \\ []) do
    tombstone = Turn.legacy_text_tombstone()

    Turn
    |> where([turn], is_nil(turn.content_scrubbed_at))
    |> where(
      [turn],
      (is_nil(turn.text) and turn.legacy_text != ^tombstone) or
        (is_nil(turn.structured_data) and
           fragment("? <> '{}'::jsonb", turn.legacy_structured_data))
    )
    |> exclude_ids(excluded_ids)
  end

  defp legacy_conversation_query(excluded_ids \\ []) do
    Conversation
    |> where([conversation], is_nil(conversation.content_scrubbed_at))
    |> where(
      [conversation],
      (is_nil(conversation.summary) and not is_nil(conversation.legacy_summary)) or
        (is_nil(conversation.historical_summary) and
           fragment("jsonb_exists(?, 'historical_summary')", conversation.metadata))
    )
    |> exclude_ids(excluded_ids)
  end

  defp exclude_ids(query, []), do: query
  defp exclude_ids(query, ids) when is_list(ids), do: where(query, [row], row.id not in ^ids)
  defp exclude_ids(query, _invalid), do: query

  defp backfill_turns(turns) do
    Enum.reduce(turns, {0, []}, fn turn, {migrated, blocked} ->
      hydrated = Turn.hydrate(turn)

      attrs = %{
        text: hydrated.text,
        structured_data: hydrated.structured_data || %{}
      }

      changeset =
        turn
        |> Turn.changeset(attrs)
        |> Ecto.Changeset.force_change(:updated_at, turn.updated_at)

      case Repo.update(changeset) do
        {:ok, _updated} ->
          {migrated + 1, blocked}

        {:error, %Ecto.Changeset{} = invalid} ->
          {migrated, [%{id: hydrated.id, errors: changeset_errors(invalid)} | blocked]}
      end
    end)
    |> reverse_blocked()
  end

  defp backfill_conversations(conversations) do
    Enum.reduce(conversations, {0, []}, fn conversation, {migrated, blocked} ->
      hydrated = Conversation.hydrate(conversation)

      attrs = %{
        summary: hydrated.summary,
        historical_summary: hydrated.historical_summary,
        metadata: hydrated.metadata || %{}
      }

      changeset =
        conversation
        |> Conversation.changeset(attrs)
        |> Ecto.Changeset.force_change(:updated_at, conversation.updated_at)

      case Repo.update(changeset) do
        {:ok, _updated} ->
          {migrated + 1, blocked}

        {:error, %Ecto.Changeset{} = invalid} ->
          {migrated, [%{id: hydrated.id, errors: changeset_errors(invalid)} | blocked]}
      end
    end)
    |> reverse_blocked()
  end

  defp eligible_conversations(cutoff) do
    active_run =
      from run in Run,
        where:
          run.conversation_id == parent_as(:conversation).id and
            (is_nil(run.finished_at) or run.status in ^@active_run_statuses),
        select: 1

    active_run_linked_by_turn =
      from run in Run,
        join: turn in Turn,
        on: turn.assistant_run_id == run.id,
        where:
          turn.conversation_id == parent_as(:conversation).id and
            (is_nil(run.finished_at) or run.status in ^@active_run_statuses),
        select: 1

    pending_action =
      from action in PreparedAction,
        where:
          action.conversation_id == parent_as(:conversation).id and
            (is_nil(action.status) or action.status not in ^@terminal_action_statuses),
        select: 1

    pending_action_linked_by_turn =
      from action in PreparedAction,
        join: turn in Turn,
        on: turn.prepared_action_id == action.id,
        where:
          turn.conversation_id == parent_as(:conversation).id and
            (is_nil(action.status) or action.status not in ^@terminal_action_statuses),
        select: 1

    active_todo_linked_by_turn =
      from todo in Todo,
        join: turn in Turn,
        on: turn.linked_todo_id == todo.id,
        where:
          turn.conversation_id == parent_as(:conversation).id and
            (is_nil(todo.status) or todo.status not in ^@terminal_todo_statuses),
        select: 1

    active_todo_linked_by_conversation =
      from todo in Todo,
        where:
          (is_nil(todo.status) or todo.status not in ^@terminal_todo_statuses) and
            (fragment(
               "?::text = ?->>'linked_todo_id'",
               todo.id,
               parent_as(:conversation).metadata
             ) or
               fragment(
                 "? = 'todo:' || ?::text",
                 parent_as(:conversation).root_message_id,
                 todo.id
               )),
        select: 1

    needs_turn_scrub =
      from turn in Turn,
        where:
          turn.conversation_id == parent_as(:conversation).id and
            is_nil(turn.content_scrubbed_at) and turn.inserted_at < ^cutoff,
        select: 1

    from conversation in Conversation,
      as: :conversation,
      where: conversation.status == "closed",
      where:
        fragment(
          "COALESCE(?, ?) < ?",
          conversation.last_turn_at,
          conversation.updated_at,
          ^cutoff
        ),
      where: not exists(subquery(active_run)),
      where: not exists(subquery(active_run_linked_by_turn)),
      where: not exists(subquery(pending_action)),
      where: not exists(subquery(pending_action_linked_by_turn)),
      where: not exists(subquery(active_todo_linked_by_turn)),
      where: not exists(subquery(active_todo_linked_by_conversation)),
      where: is_nil(conversation.content_scrubbed_at) or exists(subquery(needs_turn_scrub))
  end

  defp lock_unscrubbed_turn_ids([], _cutoff, _limit), do: []

  defp lock_unscrubbed_turn_ids(conversation_ids, cutoff, limit) do
    Turn
    |> where([turn], turn.conversation_id in ^conversation_ids)
    |> where([turn], is_nil(turn.content_scrubbed_at) and turn.inserted_at < ^cutoff)
    |> order_by([turn], asc: turn.inserted_at, asc: turn.id)
    |> select([turn], turn.id)
    |> limit(^limit)
    |> lock("FOR UPDATE SKIP LOCKED")
    |> Repo.all()
  end

  defp scrub_turn_ids([], _now), do: 0

  defp scrub_turn_ids(turn_ids, now) do
    {count, _rows} =
      Turn
      |> where([turn], turn.id in ^turn_ids and is_nil(turn.content_scrubbed_at))
      |> Repo.update_all(
        set: [
          text: nil,
          legacy_text: Turn.legacy_text_tombstone(),
          structured_data: nil,
          legacy_structured_data: %{},
          content_scrubbed_at: now
        ]
      )

    count
  end

  defp scrub_conversation_summaries(conversations, now) do
    ids =
      conversations
      |> Enum.filter(&is_nil(&1.content_scrubbed_at))
      |> Enum.map(& &1.id)

    if ids == [] do
      0
    else
      {count, _rows} =
        from(conversation in Conversation,
          where: conversation.id in ^ids and is_nil(conversation.content_scrubbed_at),
          update: [
            set: [
              summary: nil,
              legacy_summary: nil,
              historical_summary: nil,
              metadata: fragment("? - 'historical_summary'", conversation.metadata),
              content_scrubbed_at: ^now
            ]
          ]
        )
        |> Repo.update_all([])

      count
    end
  end

  defp changeset_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Enum.reduce(opts, message, fn {key, value}, rendered ->
        String.replace(rendered, "%{#{key}}", to_string(value))
      end)
    end)
  end

  defp reverse_blocked({count, blocked}), do: {count, Enum.reverse(blocked)}

  defp empty_backfill_result do
    %{
      batches: 0,
      migrated_turns: 0,
      migrated_conversations: 0,
      blocked_turns: [],
      blocked_conversations: []
    }
  end

  defp merge_backfill_results(total, batch) do
    %{
      batches: total.batches + batch.batches,
      migrated_turns: total.migrated_turns + batch.migrated_turns,
      migrated_conversations: total.migrated_conversations + batch.migrated_conversations,
      blocked_turns: total.blocked_turns ++ batch.blocked_turns,
      blocked_conversations: total.blocked_conversations ++ batch.blocked_conversations
    }
  end

  defp batch_size(opts) do
    opts
    |> Keyword.get(:batch_size, Keyword.get(opts, :limit, @default_batch_size))
    |> positive_integer(@default_batch_size)
    |> min(@max_batch_size)
  end

  defp bounded_max_batches(value),
    do: value |> positive_integer(@default_max_batches) |> min(@max_batches)

  defp positive_integer(value, _default) when is_integer(value) and value > 0, do: value

  defp positive_integer(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} when parsed > 0 -> parsed
      _other -> default
    end
  end

  defp positive_integer(_value, default), do: default
end
