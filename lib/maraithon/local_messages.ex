defmodule Maraithon.LocalMessages do
  @moduledoc """
  Context for messages synced from a user's local machine (iMessage in v1,
  more sources later). Owns bulk-insert with idempotent dedupe, recent
  lookups for a chat, and per-device purges.
  """

  import Ecto.Query

  alias Maraithon.LocalEmbeddings
  alias Maraithon.LocalMessages.EmbedJob
  alias Maraithon.LocalMessages.LocalMessage
  alias Maraithon.LocalSearch
  alias Maraithon.Repo

  @doc """
  Ingests a batch of message maps from a device for the given user.

  Each entry should be a string-keyed or atom-keyed map matching the
  payload defined in the companion spec. Inserts are idempotent via the
  `(user_id, device_id, source, guid)` unique constraint — re-sending the
  same payload is a no-op.

  Returns `{:ok, %{accepted: integer, duplicate: integer}}`.
  """
  def ingest_batch(user_id, device_id, messages)
      when is_binary(user_id) and is_list(messages) do
    started_at = System.monotonic_time(:millisecond)

    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    {prepared, invalid} =
      messages
      |> Enum.map(&prepare_row(&1, user_id, device_id, now))
      |> Enum.split_with(&match?({:ok, _row}, &1))

    rows = Enum.map(prepared, fn {:ok, row} -> row end)

    # On-conflict :replace backfills mutable text fields on re-sync (e.g. a
    # later client with an improved typedstream decoder fills in text that was
    # first stored NULL). Identity columns and the original `sent_at` stay
    # untouched. Because :replace upserts conflicting rows, `insert_all`'s count
    # would include re-sends — so we look up which keys already existed to keep
    # the accepted/duplicate accounting (and the embed enqueue) correct.
    existing_keys = existing_message_keys(user_id, device_id, rows)

    {_upsert_count, upserted_rows} =
      if rows == [] do
        {0, []}
      else
        Repo.insert_all(LocalMessage, rows,
          on_conflict:
            {:replace,
             [
               :sender_handle,
               :chat_display_name,
               :chat_style,
               :chat_key,
               :text,
               :has_attachments,
               :attachments,
               :updated_at
             ]},
          conflict_target: [:user_id, :device_id, :source, :guid],
          returning: [:id, :source, :guid]
        )
      end

    inserted_rows =
      Enum.reject(upserted_rows, fn row ->
        MapSet.member?(existing_keys, {row.source, row.guid})
      end)

    inserted_count = length(inserted_rows)

    enqueue_embed_jobs(user_id, inserted_rows)

    total = length(rows)
    duplicate_count = total - inserted_count
    invalid_count = length(invalid)
    latency_ms = System.monotonic_time(:millisecond) - started_at

    :telemetry.execute(
      [:maraithon, :companion, :messages_ingested],
      %{
        count: length(messages),
        accepted: inserted_count,
        duplicate: duplicate_count,
        invalid: invalid_count,
        latency_ms: latency_ms
      },
      %{user_id: user_id, device_id: device_id}
    )

    {:ok,
     %{
       accepted: inserted_count,
       duplicate: duplicate_count,
       invalid: invalid_count
     }}
  end

  def ingest_batch(_user_id, _device_id, _messages), do: {:error, :invalid_batch}

  # Which (source, guid) keys from this batch already exist for the device —
  # used to tell genuine inserts apart from :replace upserts (re-sends).
  defp existing_message_keys(_user_id, _device_id, []), do: MapSet.new()

  defp existing_message_keys(user_id, device_id, rows) do
    guids = Enum.map(rows, & &1.guid)

    from(m in LocalMessage,
      where: m.user_id == ^user_id and m.device_id == ^device_id and m.guid in ^guids,
      select: {m.source, m.guid}
    )
    |> Repo.all()
    |> MapSet.new()
  end

  @doc """
  Returns the most recent messages for a chat for a user.
  """
  def recent_for_chat(user_id, chat_key, opts \\ [])
      when is_binary(user_id) and is_binary(chat_key) do
    limit = Keyword.get(opts, :limit, 50)

    Repo.all(
      from msg in LocalMessage,
        where: msg.user_id == ^user_id,
        where: msg.chat_key == ^chat_key,
        order_by: [desc: msg.sent_at],
        limit: ^limit
    )
  end

  @doc """
  Returns the most recent messages across every chat for a user, newest first.

  Accepts optional `:limit` (default 50) and `:chat_key` (to restrict to a
  single thread).
  """
  def recent_for_user(user_id, opts \\ []) when is_binary(user_id) do
    limit = Keyword.get(opts, :limit, 50)
    chat_key = Keyword.get(opts, :chat_key)

    query =
      from msg in LocalMessage,
        where: msg.user_id == ^user_id,
        order_by: [desc: msg.sent_at],
        limit: ^limit

    query =
      if is_binary(chat_key) and chat_key != "" do
        from msg in query, where: msg.chat_key == ^chat_key
      else
        query
      end

    Repo.all(query)
  end

  @doc """
  Searches messages for a user using a substring match on the encrypted
  `text` and `sender_handle` fields. Since these columns are encrypted at
  rest, we decrypt in memory and filter — fine for the per-user volumes we
  expect today.

  Options:
    * `:limit` — max rows to return (default 50)
    * `:from_handle` — restrict to messages whose `sender_handle`
      substring-matches the value
    * `:since` — only include messages with `sent_at >= since`
    * `:before` — only include messages with `sent_at <= before`
  """
  def search(user_id, term, opts \\ [])
      when is_binary(user_id) and is_binary(term) do
    limit = Keyword.get(opts, :limit, 50)
    from_handle = Keyword.get(opts, :from_handle)
    since = Keyword.get(opts, :since)
    before_ts = Keyword.get(opts, :before)
    query = LocalSearch.compile(term)
    handle_needle = if is_binary(from_handle), do: LocalSearch.normalize(from_handle), else: nil

    base_query =
      from msg in LocalMessage,
        where: msg.user_id == ^user_id,
        order_by: [desc: msg.sent_at]

    base_query =
      base_query
      |> maybe_where_since(since)
      |> maybe_where_before(before_ts)

    base_query
    |> Repo.all()
    |> Enum.filter(&matches_text?(&1, query))
    |> Enum.filter(&matches_handle?(&1, handle_needle))
    |> Enum.take(limit)
  end

  @doc """
  Pgvector-backed semantic lookup over messages.

  The caller is responsible for computing the embedding (typically via
  `Maraithon.LLM.Embeddings.embed/2`) so that fan-out callers like
  `Maraithon.Tools.RecallAnywhere` only pay the embedding cost once and
  reuse the same vector across every source.

  Returns `[{%LocalMessage{}, similarity}, ...]` ordered by descending
  cosine similarity, or `[]` when the `embedding` column hasn't been
  migrated yet — callers should treat that as a soft-fail and fall back
  to substring search.

  Options:
    * `:limit` — max results (default 10)
    * `:min_similarity` — discard rows below this value (default 0.0)
  """
  def semantic_search(user_id, query, opts \\ [])

  def semantic_search(user_id, query, opts)
      when is_binary(user_id) and is_binary(query) and is_list(opts) do
    limit = Keyword.get(opts, :limit, 12)
    pool_size = Keyword.get(opts, :pool_size, 200)
    from_handle = Keyword.get(opts, :from_handle)
    handle_needle = if is_binary(from_handle), do: String.downcase(from_handle), else: nil

    pool =
      from(msg in LocalMessage,
        where: msg.user_id == ^user_id,
        order_by: [desc: msg.sent_at],
        limit: ^pool_size
      )
      |> Repo.all()
      |> Enum.filter(&matches_handle?(&1, handle_needle))

    Maraithon.LocalSemanticSearch.rank_by_similarity(
      pool,
      query,
      &message_text/1,
      Keyword.put(opts, :limit, limit)
    )
  end

  def semantic_search(user_id, query_vector, opts)
      when is_binary(user_id) and is_list(query_vector) and is_list(opts) do
    limit = Keyword.get(opts, :limit, 10)

    case LocalEmbeddings.semantic_search("local_messages", user_id, query_vector, opts) do
      [] ->
        []

      rows ->
        ids = Enum.map(rows, fn {id, _sim} -> id end)

        messages =
          Repo.all(
            from msg in LocalMessage,
              where: msg.user_id == ^user_id and msg.id in ^ids
          )

        sim_by_id = Map.new(rows)

        messages
        |> Enum.map(fn msg -> {msg, Map.get(sim_by_id, msg.id, 0.0)} end)
        |> Enum.sort_by(fn {_msg, sim} -> -sim end)
        |> Enum.take(limit)
    end
  end

  def semantic_search(_user_id, _query, _opts), do: []

  defp message_text(%LocalMessage{text: text, chat_display_name: chat}) do
    [text, chat]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" ")
  end

  @doc """
  Fetches one message for a user by its source GUID. Returns `nil` when no
  matching message exists.
  """
  def get_by_guid(user_id, guid) when is_binary(user_id) and is_binary(guid) do
    Repo.one(
      from msg in LocalMessage,
        where: msg.user_id == ^user_id and msg.guid == ^guid,
        limit: 1
    )
  end

  def get_by_guid(_user_id, _guid), do: nil

  @doc """
  Returns the top-N most recently active chats for a user along with the
  latest message in each chat and a count of messages in that chat over the
  last 7 days.

  Each entry is a map of:

      %{
        chat_key: binary,
        chat_display_name: binary | nil,
        latest_message: %LocalMessage{},
        message_count_last_7d: non_neg_integer
      }
  """
  def chats_recent(user_id, opts \\ []) when is_binary(user_id) do
    limit = Keyword.get(opts, :limit, 12)
    now = Keyword.get(opts, :now, DateTime.utc_now())
    seven_days_ago = DateTime.add(now, -7 * 24 * 60 * 60, :second)

    latest_per_chat_query =
      from msg in LocalMessage,
        where: msg.user_id == ^user_id and not is_nil(msg.chat_key),
        group_by: msg.chat_key,
        select: %{chat_key: msg.chat_key, latest_sent_at: max(msg.sent_at)},
        order_by: [desc: max(msg.sent_at)],
        limit: ^limit

    latest_rows = Repo.all(latest_per_chat_query)

    Enum.map(latest_rows, fn %{chat_key: chat_key, latest_sent_at: latest_sent_at} ->
      latest_message =
        Repo.one(
          from msg in LocalMessage,
            where:
              msg.user_id == ^user_id and msg.chat_key == ^chat_key and
                msg.sent_at == ^latest_sent_at,
            limit: 1
        )

      count_7d =
        Repo.one(
          from msg in LocalMessage,
            where:
              msg.user_id == ^user_id and msg.chat_key == ^chat_key and
                msg.sent_at >= ^seven_days_ago,
            select: count(msg.id)
        ) || 0

      %{
        chat_key: chat_key,
        chat_display_name: latest_message && latest_message.chat_display_name,
        latest_message: latest_message,
        message_count_last_7d: count_7d
      }
    end)
  end

  @doc """
  Purges every message for a (user, device) pair. Returns
  `{:ok, %{deleted: count}}`.
  """
  def purge_device(user_id, device_id) when is_binary(user_id) do
    {deleted, _} =
      Repo.delete_all(
        from msg in LocalMessage,
          where: msg.user_id == ^user_id and msg.device_id == ^device_id
      )

    {:ok, %{deleted: deleted}}
  end

  # -- internals ---------------------------------------------------------

  defp prepare_row(message, user_id, device_id, now) when is_map(message) do
    attrs = %{
      user_id: user_id,
      device_id: device_id,
      source: fetch(message, :source) || "imessage",
      guid: fetch(message, :guid),
      local_id: fetch(message, :local_id),
      is_from_me: truthy?(fetch(message, :is_from_me)),
      sender_handle: Maraithon.TextSanitize.scrub(fetch(message, :sender_handle)),
      chat_key: derive_chat_key(message),
      chat_display_name: Maraithon.TextSanitize.scrub(fetch(message, :chat_display_name)),
      chat_style: fetch(message, :chat_style),
      text: Maraithon.TextSanitize.scrub(fetch(message, :text)),
      sent_at: parse_datetime(fetch(message, :sent_at)),
      has_attachments: truthy?(fetch(message, :has_attachments)),
      attachments: normalize_attachments(fetch(message, :attachments)),
      encrypted_with_device_key: truthy?(fetch(message, :encrypted_with_device_key)),
      key_id: fetch(message, :key_id)
    }

    changeset = LocalMessage.changeset(%LocalMessage{}, attrs)

    if changeset.valid? do
      struct = Ecto.Changeset.apply_changes(changeset)

      row =
        LocalMessage.__schema__(:fields)
        |> Kernel.--([:id, :inserted_at, :updated_at])
        |> Enum.into(%{}, fn field -> {field, Map.get(struct, field)} end)
        |> Map.put(:id, Ecto.UUID.generate())
        |> Map.put(:inserted_at, now)
        |> Map.put(:updated_at, now)

      {:ok, row}
    else
      {:error, changeset}
    end
  end

  defp prepare_row(_other, _user_id, _device_id, _now), do: {:error, :invalid}

  defp fetch(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp derive_chat_key(message) do
    case fetch(message, :chat_key) do
      value when is_binary(value) and value != "" ->
        value

      _other ->
        case fetch(message, :chat_handles) do
          handles when is_list(handles) and handles != [] ->
            handles
            |> Enum.map(&to_string/1)
            |> Enum.sort()
            |> Enum.join(",")

          _ ->
            nil
        end
    end
  end

  defp truthy?(true), do: true
  defp truthy?("true"), do: true
  defp truthy?(1), do: true
  defp truthy?(_other), do: false

  defp normalize_attachments(nil), do: %{}
  defp normalize_attachments(map) when is_map(map), do: map

  defp normalize_attachments(list) when is_list(list) do
    %{"items" => list}
  end

  defp normalize_attachments(_other), do: %{}

  defp parse_datetime(%DateTime{} = dt), do: DateTime.truncate(dt, :microsecond)

  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, dt, _offset} -> DateTime.truncate(dt, :microsecond)
      _ -> nil
    end
  end

  defp parse_datetime(_), do: nil

  defp maybe_where_since(query, nil), do: query

  defp maybe_where_since(query, %DateTime{} = since) do
    from msg in query, where: msg.sent_at >= ^since
  end

  defp maybe_where_since(query, value) when is_binary(value) do
    case parse_datetime(value) do
      %DateTime{} = dt -> from(msg in query, where: msg.sent_at >= ^dt)
      _ -> query
    end
  end

  defp maybe_where_since(query, _other), do: query

  defp maybe_where_before(query, nil), do: query

  defp maybe_where_before(query, %DateTime{} = before_ts) do
    from msg in query, where: msg.sent_at <= ^before_ts
  end

  defp maybe_where_before(query, value) when is_binary(value) do
    case parse_datetime(value) do
      %DateTime{} = dt -> from(msg in query, where: msg.sent_at <= ^dt)
      _ -> query
    end
  end

  defp maybe_where_before(query, _other), do: query

  defp matches_text?(%LocalMessage{} = msg, query) do
    LocalSearch.matches?(query, [
      msg.text,
      msg.chat_display_name,
      msg.sender_handle
    ])
  end

  defp matches_text?(_msg, _query), do: false

  defp matches_handle?(_msg, nil), do: true

  defp matches_handle?(%LocalMessage{} = msg, needle) do
    [
      msg.sender_handle,
      msg.chat_key,
      msg.chat_display_name
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&LocalSearch.normalize/1)
    |> Enum.any?(&String.contains?(&1, needle))
  end

  defp matches_handle?(_msg, _needle), do: false

  defp enqueue_embed_jobs(_user_id, []), do: :ok

  defp enqueue_embed_jobs(user_id, inserted_rows) do
    if LocalEmbeddings.embedding_storage_available?("local_messages") do
      Enum.each(inserted_rows, fn
        %{id: id} when is_binary(id) -> EmbedJob.enqueue(user_id, id)
        %LocalMessage{id: id} when is_binary(id) -> EmbedJob.enqueue(user_id, id)
        _ -> :ok
      end)
    end

    :ok
  end
end
