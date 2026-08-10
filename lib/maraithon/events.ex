defmodule Maraithon.Events do
  @moduledoc """
  Event store for agent events.
  """

  import Ecto.Query
  alias Maraithon.Events.Event
  alias Maraithon.Repo
  alias Maraithon.Runtime.DatabaseClock

  @default_payload_purge_batch 100
  @max_payload_purge_batch 500
  @default_payload_backfill_batch 25
  @max_payload_backfill_batch 100
  @payload_backfill_timeout_ms 30_000

  @doc """
  Append an event to the log.
  """
  def append(agent_id, event_type, payload, opts \\ []) do
    Repo.transaction(fn ->
      :ok = Maraithon.DurablePayload.require_current_mutation!()

      attrs = %{
        agent_id: agent_id,
        sequence_num: opts[:sequence_num] || next_sequence_num(agent_id),
        event_type: event_type,
        payload: payload,
        idempotency_key: opts[:idempotency_key]
      }

      case %Event{} |> Event.changeset(attrs) |> Repo.insert() do
        {:ok, event} -> event
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  @doc """
  List events for an agent.
  """
  def list_events(agent_id, opts \\ []) do
    after_seq = opts[:after_seq]
    limit = opts[:limit] || 100
    types = opts[:types]

    query =
      from(e in Event,
        where: e.agent_id == ^agent_id,
        order_by: [asc: e.sequence_num],
        limit: ^limit
      )

    query =
      if after_seq do
        from(e in query, where: e.sequence_num > ^after_seq)
      else
        query
      end

    query =
      if types && types != [] do
        from(e in query, where: e.event_type in ^types)
      else
        query
      end

    Repo.all(query)
    |> Enum.map(&format_event/1)
  end

  @doc """
  Returns the number of unpurged Events still needing ciphertext promotion or
  derived spend facts.

  This query reads only scalar/null metadata and never loads payload content.
  """
  def legacy_payload_encryption_backlog do
    Event
    |> where([event], is_nil(event.payload_purged_at))
    |> where(
      [event],
      is_nil(event.payload) or
        is_nil(event.spend_total_cost) or
        is_nil(event.spend_input_tokens) or
        is_nil(event.spend_output_tokens) or
        is_nil(event.spend_llm_calls) or
        fragment("? <> '{}'::jsonb", event.legacy_payload)
    )
    |> Repo.aggregate(:count, timeout: @payload_backfill_timeout_ms, log: false)
  end

  @doc """
  Promotes one bounded, resumable batch of legacy Event payloads to ciphertext.

  Rows are locked with `SKIP LOCKED`, spend facts are derived by the normal
  Event changeset before plaintext is cleared, and no payload content is
  returned or logged. The result contains migrated counts and blocked IDs with
  closed error codes; `Maraithon.DurablePayloadPrivacy.backfill/1` performs the
  bounded repeat loop.
  """
  def backfill_legacy_payload_encryption(opts \\ [])

  def backfill_legacy_payload_encryption(opts) when is_list(opts) do
    with {:ok, {limit, skip}} <- payload_backfill_options(opts) do
      Repo.transaction(
        fn ->
          :ok = Maraithon.DurablePayload.require_legacy_mutation!()

          events =
            Event
            |> where([event], is_nil(event.payload_purged_at))
            |> where(
              [event],
              is_nil(event.payload) or
                is_nil(event.spend_total_cost) or
                is_nil(event.spend_input_tokens) or
                is_nil(event.spend_output_tokens) or
                is_nil(event.spend_llm_calls) or
                fragment("? <> '{}'::jsonb", event.legacy_payload)
            )
            |> order_by([event], asc: event.inserted_at, asc: event.id)
            |> offset(^skip)
            |> limit(^limit)
            |> lock("FOR UPDATE SKIP LOCKED")
            |> Repo.all(log: false)

          Enum.reduce(events, %{migrated_events: 0, blocked_events: []}, fn event, result ->
            case promote_legacy_event_payload(event) do
              :ok ->
                %{result | migrated_events: result.migrated_events + 1}

              {:blocked, blocked} ->
                %{result | blocked_events: [blocked | result.blocked_events]}
            end
          end)
          |> Map.update!(:blocked_events, &Enum.reverse/1)
        end,
        timeout: @payload_backfill_timeout_ms
      )
    end
  end

  def backfill_legacy_payload_encryption(_opts),
    do: {:error, :invalid_event_payload_backfill}

  @doc """
  Purges one bounded batch of event payload bodies older than `cutoff`.

  Event identity, sequence, type, idempotency headers, timestamps, and derived
  spend facts remain intact. Calling this repeatedly until it returns zero is
  safe for a durable retention job.
  """
  def purge_payloads_before(cutoff, opts \\ [])

  def purge_payloads_before(%DateTime{} = cutoff, opts) when is_list(opts) do
    with :ok <- validate_utc_cutoff(cutoff),
         {:ok, limit} <- payload_purge_limit(opts) do
      Repo.transaction(fn ->
        :ok = Maraithon.DurablePayload.require_current_mutation!()

        candidate_ids =
          from(candidate in Event,
            where: is_nil(candidate.payload_purged_at),
            where: candidate.inserted_at < ^cutoff,
            order_by: [asc: candidate.inserted_at, asc: candidate.id],
            limit: ^limit,
            select: candidate.id
          )

        now = DatabaseClock.now!()

        {count, _rows} =
          Repo.update_all(
            from(event in Event,
              where: is_nil(event.payload_purged_at),
              where: event.id in subquery(candidate_ids)
            ),
            set: [payload: nil, legacy_payload: %{}, payload_purged_at: now]
          )

        count
      end)
    end
  end

  def purge_payloads_before(_cutoff, _opts), do: {:error, :invalid_event_payload_retention}

  @doc """
  Get the latest sequence number for an agent.
  """
  def latest_sequence_num(agent_id) do
    from(e in Event,
      where: e.agent_id == ^agent_id,
      select: max(e.sequence_num)
    )
    |> Repo.one()
    |> Kernel.||(0)
  end

  @doc """
  Get events after a specific sequence number (for replay).
  """
  def get_events_after(agent_id, sequence_num) do
    from(e in Event,
      where: e.agent_id == ^agent_id,
      where: e.sequence_num > ^sequence_num,
      order_by: [asc: e.sequence_num]
    )
    |> Repo.all()
    |> Enum.map(&Event.hydrate_payload!/1)
  end

  # Private functions

  defp promote_legacy_event_payload(%Event{} = event) do
    payload = Event.read_payload!(event)

    changeset =
      event
      |> Event.changeset(%{payload: payload})
      |> Ecto.Changeset.put_change(:legacy_payload, %{})

    if changeset.valid? do
      case Repo.update(changeset, log: false) do
        {:ok, _event} -> :ok
        {:error, _changeset} -> {:blocked, %{id: event.id, errors: [:persistence_failed]}}
      end
    else
      {:blocked, %{id: event.id, errors: [:payload_out_of_bounds]}}
    end
  end

  defp payload_backfill_options(opts) do
    if Keyword.keyword?(opts) do
      limit = Keyword.get(opts, :limit, @default_payload_backfill_batch)
      skip = Keyword.get(opts, :skip, 0)

      if is_integer(limit) and limit in 1..@max_payload_backfill_batch and
           is_integer(skip) and skip in 0..10_000 do
        {:ok, {limit, skip}}
      else
        {:error, :invalid_event_payload_backfill}
      end
    else
      {:error, :invalid_event_payload_backfill}
    end
  end

  defp validate_utc_cutoff(%DateTime{utc_offset: 0, std_offset: 0}), do: :ok
  defp validate_utc_cutoff(_cutoff), do: {:error, :invalid_event_payload_retention}

  defp payload_purge_limit(opts) do
    if Keyword.keyword?(opts) do
      case Keyword.get(opts, :limit, @default_payload_purge_batch) do
        limit when is_integer(limit) and limit in 1..@max_payload_purge_batch -> {:ok, limit}
        _invalid -> {:error, :invalid_event_payload_retention}
      end
    else
      {:error, :invalid_event_payload_retention}
    end
  end

  defp next_sequence_num(agent_id) do
    latest_sequence_num(agent_id) + 1
  end

  defp format_event(event) do
    %{
      id: event.id,
      sequence_num: event.sequence_num,
      event_type: event.event_type,
      payload: Event.read_payload!(event),
      created_at: event.inserted_at
    }
  end
end
