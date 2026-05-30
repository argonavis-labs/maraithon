defmodule Maraithon.Companion.Devices do
  @moduledoc """
  Companion device registry: register, verify, revoke, and touch
  desktop companion devices that push local context to Maraithon.

  Pattern mirrors `Maraithon.Accounts` `UserSession` flow — plaintext
  bearer tokens are shown to the caller exactly once; only a SHA-256
  hex digest is persisted as `token_hash`.
  """

  import Ecto.Query

  alias Maraithon.Companion.Device
  alias Maraithon.LocalBrowserHistory.LocalVisit
  alias Maraithon.LocalCalendar.LocalEvent
  alias Maraithon.LocalFiles.LocalFile
  alias Maraithon.LocalMessages.LocalMessage
  alias Maraithon.LocalNotes.LocalNote
  alias Maraithon.LocalReminders.LocalReminder
  alias Maraithon.LocalVoiceMemos.LocalVoiceMemo
  alias Maraithon.Repo

  @data_sources [
    %{
      schema: LocalMessage,
      stat_key: :messages_count,
      table_key: :messages,
      aliases: ~w(messages imessage)
    },
    %{schema: LocalNote, stat_key: :notes_count, table_key: :notes, aliases: ~w(notes)},
    %{
      schema: LocalVoiceMemo,
      stat_key: :voice_memos_count,
      table_key: :voice_memos,
      aliases: ~w(voice_memos voice-memos)
    },
    %{
      schema: LocalEvent,
      stat_key: :calendar_events_count,
      table_key: :calendar_events,
      aliases: ~w(calendar calendar_events calendar-events)
    },
    %{
      schema: LocalReminder,
      stat_key: :reminders_count,
      table_key: :reminders,
      aliases: ~w(reminders)
    },
    %{schema: LocalFile, stat_key: :files_count, table_key: :files, aliases: ~w(files)},
    %{
      schema: LocalVisit,
      stat_key: :browser_visits_count,
      table_key: :browser_visits,
      aliases: ~w(browser_history browser-history browser_visits browser-visits visits)
    }
  ]

  @stat_sources Enum.map(@data_sources, &{&1.schema, &1.stat_key})

  @source_by_alias Enum.reduce(@data_sources, %{}, fn source, acc ->
                     Enum.reduce(source.aliases, acc, &Map.put(&2, &1, source))
                   end)

  @empty_stats Enum.into(@stat_sources, %{}, fn {_schema, key} -> {key, 0} end)

  @doc """
  Registers (or refreshes) a paired companion device for a user.

  Generates a fresh plaintext bearer token, stores its SHA-256 hex
  digest, and returns `{:ok, %{device: device, token: plaintext}}` so
  the caller can hand the token to the device.

  If a `(user_id, device_id)` row already exists (e.g. the user re-runs
  the pairing flow), the row's `token_hash` is rotated and any prior
  `revoked_at` is cleared.
  """
  def register(user_id, device_id, opts \\ []) when is_binary(user_id) do
    device_name = Keyword.get(opts, :device_name)
    token = generate_token()
    token_hash = hash_token(token)
    now = DateTime.utc_now()

    attrs = %{
      user_id: user_id,
      device_id: device_id,
      device_name: device_name,
      token_hash: token_hash,
      last_seen_at: now,
      revoked_at: nil
    }

    result =
      case Repo.get_by(Device, user_id: user_id, device_id: device_id) do
        nil ->
          %Device{}
          |> Device.changeset(attrs)
          |> Repo.insert()

        %Device{} = existing ->
          existing
          |> Device.changeset(attrs)
          |> Repo.update()
      end

    case result do
      {:ok, device} ->
        :telemetry.execute(
          [:maraithon, :companion, :device_paired],
          %{count: 1},
          %{user_id: user_id, device_id: device_id}
        )

        {:ok, %{device: device, token: token}}

      error ->
        error
    end
  end

  @doc """
  Revokes a paired device by row id (uuid).
  """
  def revoke(user_id, id) when is_binary(user_id) and is_binary(id) do
    case Repo.get_by(Device, id: id, user_id: user_id) do
      nil ->
        {:error, :not_found}

      %Device{revoked_at: %DateTime{}} = device ->
        {:ok, device}

      %Device{} = device ->
        device
        |> Ecto.Changeset.change(revoked_at: DateTime.utc_now())
        |> Repo.update()
    end
  end

  @doc """
  Fetches one device row for the user. Returns `nil` if no row matches.
  """
  def get(user_id, id) when is_binary(user_id) and is_binary(id) do
    Repo.get_by(Device, id: id, user_id: user_id)
  end

  def get(_user_id, _id), do: nil

  @doc """
  Deletes one device row and purges all `local_*` rows for that
  `(user_id, device_id)`. Returns `{:ok, %{device: device, deleted: counts}}`
  on success, where `counts` maps each source table key (e.g. `:messages`)
  to the number of rows deleted.
  """
  def delete(user_id, id) when is_binary(user_id) and is_binary(id) do
    case Repo.get_by(Device, id: id, user_id: user_id) do
      nil ->
        {:error, :not_found}

      %Device{} = device ->
        deleted = purge_all_device_data(user_id, device.device_id)

        case Repo.delete(device) do
          {:ok, deleted_device} -> {:ok, %{device: deleted_device, deleted: deleted}}
          error -> error
        end
    end
  end

  @doc """
  Purges synced source data for a `(user_id, device_id)` pair without
  removing the companion device registration.

  Pass `nil`, `""`, or `"all"` to delete every supported source. Pass a
  source id such as `"notes"` or `"browser_history"` to delete only that
  source. Returns `{:ok, counts}` where `counts` maps table keys to the
  number of rows deleted, or `{:error, :unsupported_source}`.
  """
  def purge_data(user_id, device_id, source \\ nil)

  def purge_data(user_id, device_id, source)
      when is_binary(user_id) and is_binary(device_id) do
    case normalize_source(source) do
      :all ->
        {:ok, purge_all_device_data(user_id, device_id)}

      %{schema: schema, table_key: table_key} ->
        {:ok, %{table_key => purge_source_rows(schema, user_id, device_id)}}

      :unsupported ->
        {:error, :unsupported_source}
    end
  end

  @doc """
  Lists every device row for a user (including revoked), most recently
  seen first. Callers that want only active rows should filter on
  `revoked_at` themselves — the admin UI and `enrich_with_stats/1`
  expect to see revoked rows too so users can audit their pairings.
  """
  def list_for_user(user_id) when is_binary(user_id) do
    Repo.all(
      from device in Device,
        where: device.user_id == ^user_id,
        order_by: [desc: coalesce(device.last_seen_at, device.inserted_at)]
    )
  end

  @doc """
  Returns `[{device, stats_map}]` for the given devices, where `stats_map`
  carries the per-source row counts pulled from each `local_*` table.

  Implementation note: we issue one grouped `count(*) … GROUP BY device_id`
  query per source schema rather than per-device round-trips. With seven
  source tables and a single fan-in `Map.merge/2`, this is `O(sources)`
  queries — independent of how many devices the user has paired.

  Counts are scoped to the device owner's `user_id` so cross-user noise
  cannot leak in.
  """
  def enrich_with_stats(devices) when is_list(devices) do
    device_ids = Enum.map(devices, & &1.device_id)
    user_ids = devices |> Enum.map(& &1.user_id) |> Enum.uniq()

    counts_by_device =
      if device_ids == [] do
        %{}
      else
        @stat_sources
        |> Enum.reduce(%{}, fn {schema, key}, acc ->
          schema
          |> count_query(user_ids, device_ids)
          |> Repo.all()
          |> Enum.reduce(acc, fn {device_id, count}, inner ->
            inner
            |> Map.put_new(device_id, %{})
            |> Map.update!(device_id, &Map.put(&1, key, count))
          end)
        end)
      end

    Enum.map(devices, fn device ->
      counts = Map.get(counts_by_device, device.device_id, %{})
      {device, Map.merge(@empty_stats, counts)}
    end)
  end

  defp count_query(schema, user_ids, device_ids) do
    from row in schema,
      where: row.user_id in ^user_ids and row.device_id in ^device_ids,
      group_by: row.device_id,
      select: {row.device_id, count(row.id)}
  end

  defp purge_all_device_data(user_id, device_id) do
    Enum.into(@data_sources, %{}, fn %{schema: schema, table_key: table_key} ->
      {table_key, purge_source_rows(schema, user_id, device_id)}
    end)
  end

  defp purge_source_rows(schema, user_id, device_id) do
    {count, _} =
      Repo.delete_all(
        from row in schema,
          where: row.user_id == ^user_id and row.device_id == ^device_id
      )

    count
  end

  defp normalize_source(nil), do: :all
  defp normalize_source(""), do: :all

  defp normalize_source(source) when is_binary(source) do
    source
    |> String.trim()
    |> String.downcase()
    |> case do
      "" -> :all
      "all" -> :all
      source -> Map.get(@source_by_alias, source, :unsupported)
    end
  end

  defp normalize_source(_source), do: :unsupported

  @doc """
  Verifies a plaintext bearer token. Returns the device if it exists,
  is not revoked, and the hash matches. Returns `nil` otherwise.
  """
  def verify_token(token) when is_binary(token) and token != "" do
    token_hash = hash_token(token)

    Repo.one(
      from device in Device,
        where: device.token_hash == ^token_hash,
        where: is_nil(device.revoked_at)
    )
  end

  def verify_token(_), do: nil

  @doc """
  Bumps `last_seen_at` on a device. Best-effort — failures are swallowed.
  """
  def touch_last_seen(%Device{} = device) do
    case device
         |> Ecto.Changeset.change(last_seen_at: DateTime.utc_now())
         |> Repo.update() do
      {:ok, updated} -> updated
      _error -> device
    end
  end

  @doc """
  SHA-256 hex digest used as the on-disk identifier for a token.
  """
  def hash_token(token) when is_binary(token) do
    :sha256
    |> :crypto.hash(token)
    |> Base.encode16(case: :lower)
  end

  defp generate_token do
    :crypto.strong_rand_bytes(32)
    |> Base.url_encode64(padding: false)
  end
end
