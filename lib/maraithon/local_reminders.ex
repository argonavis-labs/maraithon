defmodule Maraithon.LocalReminders do
  @moduledoc """
  Context for macOS Reminders.app items synced from a user's local
  machine via EventKit. Owns bulk-insert with idempotent dedupe,
  open / due-soon / recently-completed lookups, substring search,
  guid lookup, and per-device purges.

  Re-ingest is the source of truth: companion devices re-push a
  reminder whenever the underlying EventKit row changes, and we
  upsert on `(user_id, device_id, source, guid)` so the stored row
  always reflects the latest title / notes / due date / completion.
  Unlike notes and messages, reminders are mutable — completing or
  uncompleting one in Reminders.app must propagate.
  """

  import Ecto.Query

  alias Maraithon.LocalReminders.LocalReminder
  alias Maraithon.Repo

  @upsert_fields [
    :local_id,
    :list_name,
    :list_color,
    :title,
    :notes,
    :priority,
    :due_at,
    :completed_at,
    :is_completed,
    :has_alarm,
    :url_attachment,
    :created_at,
    :modified_at,
    :updated_at
  ]

  @doc """
  Ingests a batch of reminder maps from a device for the given user.

  Each entry should be a string-keyed or atom-keyed map matching the
  companion EventKit payload. Inserts are idempotent via the
  `(user_id, device_id, source, guid)` unique constraint, and on
  conflict we update the mutable fields (`title`, `notes`, `due_at`,
  `is_completed`, etc.) — re-sending a reminder whose state changed
  in Reminders.app rewrites the stored row.

  Returns `{:ok, %{accepted: integer, duplicate: integer, invalid: integer}}`.
  Note: because we upsert, "duplicate" here counts rows that already
  existed (and may have been updated in place); the row is still
  considered to have been processed successfully.
  """
  def ingest_batch(user_id, device_id, reminders)
      when is_binary(user_id) and is_list(reminders) do
    started_at = System.monotonic_time(:millisecond)

    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    {prepared, invalid} =
      reminders
      |> Enum.map(&prepare_row(&1, user_id, device_id, now))
      |> Enum.split_with(&match?({:ok, _row}, &1))

    rows = Enum.map(prepared, fn {:ok, row} -> row end)

    {affected_count, _returned} =
      if rows == [] do
        {0, nil}
      else
        Repo.insert_all(LocalReminder, rows,
          on_conflict: {:replace, @upsert_fields},
          conflict_target: [:user_id, :device_id, :source, :guid]
        )
      end

    total = length(rows)
    # Conservative reporting: when on_conflict replaces an existing
    # row, the insert_all return value still counts it as "affected".
    # We can't distinguish fresh-insert from update without a second
    # query, so we report everything as accepted and let invalid be
    # the only non-success bucket. Tests pin this contract.
    accepted_count = affected_count
    duplicate_count = max(total - affected_count, 0)
    invalid_count = length(invalid)
    latency_ms = System.monotonic_time(:millisecond) - started_at

    :telemetry.execute(
      [:maraithon, :companion, :reminders_ingested],
      %{
        count: length(reminders),
        accepted: accepted_count,
        duplicate: duplicate_count,
        invalid: invalid_count,
        latency_ms: latency_ms
      },
      %{user_id: user_id, device_id: device_id}
    )

    {:ok,
     %{
       accepted: accepted_count,
       duplicate: duplicate_count,
       invalid: invalid_count
     }}
  end

  def ingest_batch(_user_id, _device_id, _reminders), do: {:error, :invalid_batch}

  @doc """
  Returns open (incomplete) reminders for a user, ordered by due
  date ascending then priority ascending (1 is highest priority).
  Reminders without a due date sort after those with one.
  """
  def open_reminders(user_id, opts \\ []) when is_binary(user_id) do
    limit = Keyword.get(opts, :limit, 25)
    list_name = Keyword.get(opts, :list_name)

    base =
      from reminder in LocalReminder,
        where: reminder.user_id == ^user_id and reminder.is_completed == false,
        # NULLS LAST keeps undated reminders below dated ones; priority 0
        # (default / no priority) goes to the back inside each bucket.
        order_by: [
          asc_nulls_last: reminder.due_at,
          asc: fragment("CASE WHEN ? = 0 THEN 10 ELSE ? END", reminder.priority, reminder.priority),
          desc: reminder.modified_at
        ],
        limit: ^limit

    base
    |> maybe_filter_list(list_name)
    |> Repo.all()
  end

  @doc """
  Open reminders due within the next `days_ahead` days. Includes
  overdue items (due_at <= now) since "due soon" colloquially means
  "needs my attention soon" — surfacing overdue is the right default.
  """
  def due_soon(user_id, opts \\ []) when is_binary(user_id) do
    limit = Keyword.get(opts, :limit, 25)
    days_ahead = Keyword.get(opts, :days_ahead, 7)
    list_name = Keyword.get(opts, :list_name)

    now = DateTime.utc_now()
    horizon = DateTime.add(now, days_ahead * 86_400, :second)

    base =
      from reminder in LocalReminder,
        where:
          reminder.user_id == ^user_id and reminder.is_completed == false and
            not is_nil(reminder.due_at) and reminder.due_at <= ^horizon,
        order_by: [
          asc: reminder.due_at,
          asc: fragment("CASE WHEN ? = 0 THEN 10 ELSE ? END", reminder.priority, reminder.priority)
        ],
        limit: ^limit

    base
    |> maybe_filter_list(list_name)
    |> Repo.all()
  end

  @doc """
  Recently-completed reminders for a user, newest completion first.
  Useful for "what did I just finish?" prompts.
  """
  def recent_completed(user_id, opts \\ []) when is_binary(user_id) do
    limit = Keyword.get(opts, :limit, 25)
    list_name = Keyword.get(opts, :list_name)

    base =
      from reminder in LocalReminder,
        where: reminder.user_id == ^user_id and reminder.is_completed == true,
        order_by: [desc_nulls_last: reminder.completed_at, desc: reminder.modified_at],
        limit: ^limit

    base
    |> maybe_filter_list(list_name)
    |> Repo.all()
  end

  @doc """
  Substring search across encrypted `title` and `notes`. Decryption
  happens in memory because Cloak ciphertext is opaque to ILIKE.
  Bounded by an overfetch ceiling so a noisy reminder list doesn't
  blow up memory.
  """
  def search(user_id, term, opts \\ [])
      when is_binary(user_id) and is_binary(term) do
    limit = Keyword.get(opts, :limit, 25)
    list_name = Keyword.get(opts, :list_name)
    needle = String.downcase(term)

    base =
      from reminder in LocalReminder,
        where: reminder.user_id == ^user_id,
        order_by: [desc: reminder.modified_at],
        limit: ^500

    base
    |> maybe_filter_list(list_name)
    |> Repo.all()
    |> Enum.filter(&matches_term?(&1, needle))
    |> Enum.take(limit)
  end

  @doc """
  Fetches one reminder for a user by its source GUID. Returns `nil`
  when no matching reminder exists.
  """
  def get_by_guid(user_id, guid) when is_binary(user_id) and is_binary(guid) do
    Repo.one(
      from reminder in LocalReminder,
        where: reminder.user_id == ^user_id and reminder.guid == ^guid,
        limit: 1
    )
  end

  def get_by_guid(_user_id, _guid), do: nil

  @doc """
  Purges every reminder for a (user, device) pair. Returns
  `{:ok, %{deleted: count}}`.
  """
  def purge_device(user_id, device_id) when is_binary(user_id) do
    {deleted, _} =
      Repo.delete_all(
        from reminder in LocalReminder,
          where: reminder.user_id == ^user_id and reminder.device_id == ^device_id
      )

    {:ok, %{deleted: deleted}}
  end

  # -- internals ---------------------------------------------------------

  defp maybe_filter_list(query, nil), do: query

  defp maybe_filter_list(query, list_name) when is_binary(list_name) do
    needle = String.trim(list_name)

    if needle == "" do
      query
    else
      from reminder in query,
        where: fragment("lower(?)", reminder.list_name) == ^String.downcase(needle)
    end
  end

  defp prepare_row(reminder, user_id, device_id, now) when is_map(reminder) do
    attrs = %{
      user_id: user_id,
      device_id: device_id,
      source: fetch(reminder, :source) || "reminders",
      guid: fetch(reminder, :guid),
      local_id: fetch(reminder, :local_id),
      list_name: fetch(reminder, :list_name),
      list_color: fetch(reminder, :list_color),
      title: fetch(reminder, :title),
      notes: fetch(reminder, :notes),
      priority: clamp_priority(fetch(reminder, :priority)),
      due_at: parse_datetime(fetch(reminder, :due_at)),
      completed_at: parse_datetime(fetch(reminder, :completed_at)),
      is_completed: truthy?(fetch(reminder, :is_completed)),
      has_alarm: truthy?(fetch(reminder, :has_alarm)),
      url_attachment: fetch(reminder, :url_attachment),
      created_at: parse_datetime(fetch(reminder, :created_at)),
      modified_at: parse_datetime(fetch(reminder, :modified_at))
    }

    changeset = LocalReminder.changeset(%LocalReminder{}, attrs)

    if changeset.valid? do
      struct = Ecto.Changeset.apply_changes(changeset)

      row =
        LocalReminder.__schema__(:fields)
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

  defp truthy?(true), do: true
  defp truthy?("true"), do: true
  defp truthy?(1), do: true
  defp truthy?(_other), do: false

  defp clamp_priority(nil), do: 0

  defp clamp_priority(value) when is_integer(value) do
    cond do
      value < 0 -> 0
      value > 9 -> 9
      true -> value
    end
  end

  defp clamp_priority(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, ""} -> clamp_priority(parsed)
      _ -> 0
    end
  end

  defp clamp_priority(_), do: 0

  defp parse_datetime(%DateTime{} = dt), do: DateTime.truncate(dt, :microsecond)

  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, dt, _offset} -> DateTime.truncate(dt, :microsecond)
      _ -> nil
    end
  end

  defp parse_datetime(_), do: nil

  defp matches_term?(%LocalReminder{title: title, notes: notes, list_name: list_name}, needle) do
    haystack =
      [title, notes, list_name]
      |> Enum.reject(&is_nil/1)
      |> Enum.map(&String.downcase/1)
      |> Enum.join(" ")

    String.contains?(haystack, needle)
  end
end
