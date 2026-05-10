defmodule Maraithon.LocalMessages do
  @moduledoc """
  Context for messages synced from a user's local machine (iMessage in v1,
  more sources later). Owns bulk-insert with idempotent dedupe, recent
  lookups for a chat, and per-device purges.
  """

  import Ecto.Query

  alias Maraithon.LocalMessages.LocalMessage
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

    {inserted_count, _returned} =
      if rows == [] do
        {0, nil}
      else
        Repo.insert_all(LocalMessage, rows,
          on_conflict: :nothing,
          conflict_target: [:user_id, :device_id, :source, :guid]
        )
      end

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
      sender_handle: fetch(message, :sender_handle),
      chat_key: derive_chat_key(message),
      chat_display_name: fetch(message, :chat_display_name),
      chat_style: fetch(message, :chat_style),
      text: fetch(message, :text),
      sent_at: parse_datetime(fetch(message, :sent_at)),
      has_attachments: truthy?(fetch(message, :has_attachments)),
      attachments: normalize_attachments(fetch(message, :attachments))
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
end
