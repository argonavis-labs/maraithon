defmodule Maraithon.LocalVoiceMemos do
  @moduledoc """
  Context for macOS Voice Memos recordings synced from a user's local
  machine. Owns bulk-insert with idempotent dedupe, recent lookups, simple
  ILIKE search, and per-device purges.
  """

  import Ecto.Query

  alias Maraithon.LocalVoiceMemos.LocalVoiceMemo
  alias Maraithon.Repo

  @doc """
  Ingests a batch of voice memo maps from a device for the given user.

  Each entry should be a string-keyed or atom-keyed map matching the
  payload defined in the companion spec. Inserts are idempotent via the
  `(user_id, device_id, source, guid)` unique constraint — re-sending the
  same payload is a no-op.

  Returns `{:ok, %{accepted: integer, duplicate: integer, invalid: integer}}`.
  """
  def ingest_batch(user_id, device_id, memos)
      when is_binary(user_id) and is_list(memos) do
    started_at = System.monotonic_time(:millisecond)

    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    {prepared, invalid} =
      memos
      |> Enum.map(&prepare_row(&1, user_id, device_id, now))
      |> Enum.split_with(&match?({:ok, _row}, &1))

    rows = Enum.map(prepared, fn {:ok, row} -> row end)

    {inserted_count, _returned} =
      if rows == [] do
        {0, nil}
      else
        Repo.insert_all(LocalVoiceMemo, rows,
          on_conflict: :nothing,
          conflict_target: [:user_id, :device_id, :source, :guid]
        )
      end

    total = length(rows)
    duplicate_count = total - inserted_count
    invalid_count = length(invalid)
    latency_ms = System.monotonic_time(:millisecond) - started_at

    :telemetry.execute(
      [:maraithon, :companion, :voice_memos_ingested],
      %{
        count: length(memos),
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

  def ingest_batch(_user_id, _device_id, _memos), do: {:error, :invalid_batch}

  @doc """
  Returns the most recent voice memos for a user, newest created first.
  """
  def recent_for_user(user_id, opts \\ []) when is_binary(user_id) do
    limit = Keyword.get(opts, :limit, 50)

    Repo.all(
      from memo in LocalVoiceMemo,
        where: memo.user_id == ^user_id,
        order_by: [desc: memo.created_at],
        limit: ^limit
    )
  end

  @doc """
  Searches voice memos for a user using a substring match on the encrypted
  `title` and `snippet` fields. Decrypts in memory and filters — fine for
  the small device-bounded volumes we expect today.
  """
  def search(user_id, term, opts \\ [])
      when is_binary(user_id) and is_binary(term) do
    limit = Keyword.get(opts, :limit, 50)
    needle = String.downcase(term)

    user_id
    |> recent_for_user(limit: 500)
    |> Enum.filter(&matches_term?(&1, needle))
    |> Enum.take(limit)
  end

  @doc """
  Fetches one voice memo for a user by its source GUID. Returns `nil`
  when no matching memo exists.

  TODO: depends on server schema agent for the durable query semantics
  shared with the assistant tool surface
  (`Maraithon.Tools.VoiceMemosGet`).
  """
  def get_by_guid(user_id, guid) when is_binary(user_id) and is_binary(guid) do
    Repo.one(
      from memo in LocalVoiceMemo,
        where: memo.user_id == ^user_id and memo.guid == ^guid,
        limit: 1
    )
  end

  def get_by_guid(_user_id, _guid), do: nil

  @doc """
  Purges every voice memo for a (user, device) pair. Returns
  `{:ok, %{deleted: count}}`.
  """
  def purge_device(user_id, device_id) when is_binary(user_id) do
    {deleted, _} =
      Repo.delete_all(
        from memo in LocalVoiceMemo,
          where: memo.user_id == ^user_id and memo.device_id == ^device_id
      )

    {:ok, %{deleted: deleted}}
  end

  # -- internals ---------------------------------------------------------

  defp prepare_row(memo, user_id, device_id, now) when is_map(memo) do
    attrs = %{
      user_id: user_id,
      device_id: device_id,
      source: fetch(memo, :source) || "voice_memos",
      guid: fetch(memo, :guid),
      local_id: fetch(memo, :local_id),
      title: fetch(memo, :title),
      snippet: fetch(memo, :snippet),
      duration_seconds: parse_integer(fetch(memo, :duration_seconds)),
      file_size_bytes: parse_integer(fetch(memo, :file_size_bytes)),
      created_at: parse_datetime(fetch(memo, :created_at))
    }

    changeset = LocalVoiceMemo.changeset(%LocalVoiceMemo{}, attrs)

    if changeset.valid? do
      struct = Ecto.Changeset.apply_changes(changeset)

      row =
        LocalVoiceMemo.__schema__(:fields)
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

  defp parse_integer(value) when is_integer(value), do: value

  defp parse_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, _} -> int
      :error -> nil
    end
  end

  defp parse_integer(_), do: nil

  defp parse_datetime(%DateTime{} = dt), do: DateTime.truncate(dt, :microsecond)

  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, dt, _offset} -> DateTime.truncate(dt, :microsecond)
      _ -> nil
    end
  end

  defp parse_datetime(_), do: nil

  defp matches_term?(%LocalVoiceMemo{title: title, snippet: snippet}, needle) do
    haystack =
      [title, snippet]
      |> Enum.reject(&is_nil/1)
      |> Enum.map(&String.downcase/1)
      |> Enum.join(" ")

    String.contains?(haystack, needle)
  end
end
