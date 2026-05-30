defmodule MaraithonWeb.CompanionController do
  @moduledoc """
  JSON endpoints used by the Maraithon Companion macOS app, gated by
  `MaraithonWeb.Plugs.CompanionDeviceAuth` which assigns
  `:current_device` and `:current_user_id`.
  """

  use MaraithonWeb, :controller

  require Logger

  alias Maraithon.Accounts
  alias Maraithon.Companion.DeviceKeys
  alias Maraithon.Companion.Devices
  alias Maraithon.LocalBrowserHistory
  alias Maraithon.LocalCalendar
  alias Maraithon.LocalFiles
  alias Maraithon.LocalMessages
  alias Maraithon.LocalNotes
  alias Maraithon.LocalReminders
  alias Maraithon.LocalVoiceMemos
  alias Maraithon.Tools.RecallAnywhere
  alias MaraithonWeb.ApiErrorCopy

  @max_batch_size 500
  @max_files_batch_size 200
  @recall_default_limit 20
  @recall_max_limit 50

  @doc """
  POST /api/v1/companion/messages

  Accepts a batch of local messages from a paired device.
  """
  def ingest(conn, params) do
    device = conn.assigns.current_device
    user_id = conn.assigns.current_user_id

    with {:ok, messages, source} <- extract_batch(params),
         :ok <- validate_device(device, params) do
      messages = Enum.map(messages, &Map.put_new(stringify(&1), "source", source))

      result =
        try do
          LocalMessages.ingest_batch(user_id, device.device_id, messages)
        rescue
          exception ->
            Logger.error(
              "companion messages ingest crashed",
              error: Exception.format(:error, exception, __STACKTRACE__),
              batch_size: length(messages)
            )

            {:error, :ingest_exception}
        end

      case result do
        {:ok, %{accepted: accepted, duplicate: duplicate, invalid: invalid}} ->
          json(conn, %{
            accepted: accepted,
            duplicate: duplicate,
            invalid: invalid
          })

        {:error, reason} ->
          Logger.warning("companion ingest failed", reason: inspect(reason))

          conn
          |> put_status(:bad_request)
          |> json(ApiErrorCopy.companion_sync(reason, "messages"))
      end
    else
      {:error, :missing_messages} ->
        conn
        |> put_status(:bad_request)
        |> json(ApiErrorCopy.companion_sync(:missing_items, "messages"))

      {:error, :too_many_messages} ->
        conn
        |> put_status(:bad_request)
        |> json(ApiErrorCopy.companion_sync(:too_many_items, @max_batch_size))

      {:error, :device_mismatch} ->
        conn
        |> put_status(:bad_request)
        |> json(ApiErrorCopy.companion_sync(:device_mismatch, nil))
    end
  end

  @doc """
  POST /api/v1/companion/notes

  Accepts a batch of macOS Notes.app notes from a paired device.
  """
  def ingest_notes(conn, params) do
    ingest_collection(conn, params, "notes", "notes", &LocalNotes.ingest_batch/3)
  end

  @doc """
  POST /api/v1/companion/voice-memos

  Accepts a batch of macOS Voice Memos recordings from a paired device.
  """
  def ingest_voice_memos(conn, params) do
    ingest_collection(
      conn,
      params,
      "voice_memos",
      "voice_memos",
      &LocalVoiceMemos.ingest_batch/3
    )
  end

  @doc """
  POST /api/v1/companion/calendar-events

  Accepts a batch of macOS Calendar.app events (sourced from EventKit,
  which aggregates iCloud, Exchange, Google CalDAV, and any other
  calendar accounts the user has added locally) from a paired device.
  """
  def ingest_calendar_events(conn, params) do
    ingest_collection(
      conn,
      params,
      "calendar_events",
      "calendar",
      &LocalCalendar.ingest_batch/3
    )
  end

  @doc """
  POST /api/v1/companion/reminders

  Accepts a batch of macOS Reminders.app items from a paired device.
  Re-ingest overwrites mutable fields (title, due, completion) on the
  matching row, so the assistant always sees the latest state from
  the user's Reminders.app.
  """
  def ingest_reminders(conn, params) do
    ingest_collection(
      conn,
      params,
      "reminders",
      "reminders",
      &LocalReminders.ingest_batch/3
    )
  end

  @doc """
  POST /api/v1/companion/files

  Accepts a batch of file metadata + extracted-text rows from a paired
  device. Privacy filters (skip `Library/`, dotfiles, `.ssh/`, etc.)
  are enforced client-side; the server only enforces the size caps:
  at most 200 records per batch, and `text_content` (after base64
  decode) capped at 200 KB per record by `LocalFiles.ingest_batch/3`.
  """
  def ingest_files(conn, params) do
    ingest_collection(
      conn,
      params,
      "files",
      "files",
      &LocalFiles.ingest_batch/3,
      max_batch: @max_files_batch_size
    )
  end

  @doc """
  POST /api/v1/companion/browser-history

  Accepts a batch of browser visits (Chrome, Safari, Arc, Brave) from a
  paired device. Rows whose host matches the server-side privacy
  deny-list are dropped before insert and reported as `filtered`.
  """
  def ingest_browser_history(conn, params) do
    device = conn.assigns.current_device
    user_id = conn.assigns.current_user_id

    with {:ok, items, source} <-
           extract_collection(params, "visits", "browser_history", @max_batch_size),
         :ok <- validate_device(device, params) do
      items = Enum.map(items, &Map.put_new(stringify(&1), "source", source))

      result =
        try do
          LocalBrowserHistory.ingest_batch(user_id, device.device_id, items)
        rescue
          exception ->
            Logger.error(
              "companion browser_history ingest crashed",
              error: Exception.format(:error, exception, __STACKTRACE__),
              batch_size: length(items)
            )

            {:error, :ingest_exception}
        end

      case result do
        {:ok, %{accepted: accepted, duplicate: duplicate, invalid: invalid, filtered: filtered}} ->
          json(conn, %{
            accepted: accepted,
            duplicate: duplicate,
            invalid: invalid,
            filtered: filtered
          })

        {:error, reason} ->
          Logger.warning("companion browser-history ingest failed", reason: inspect(reason))

          conn
          |> put_status(:bad_request)
          |> json(ApiErrorCopy.companion_sync(reason, "browser_history"))
      end
    else
      {:error, :missing_items} ->
        conn
        |> put_status(:bad_request)
        |> json(ApiErrorCopy.companion_sync(:missing_items, "visits"))

      {:error, :too_many_items} ->
        conn
        |> put_status(:bad_request)
        |> json(ApiErrorCopy.companion_sync(:too_many_items, @max_batch_size))

      {:error, :device_mismatch} ->
        conn
        |> put_status(:bad_request)
        |> json(ApiErrorCopy.companion_sync(:device_mismatch, nil))
    end
  end

  @doc """
  POST /api/v1/companion/recall

  Cross-source semantic + substring recall for the desktop Recall panel.
  Wraps `Maraithon.Tools.RecallAnywhere.execute/1` so the Mac app can
  surface the same unified search the assistant uses, without going
  through the chat surface.

  Body:
    * `query` (required) — the user's natural-language question
    * `limit` (optional) — clamp result count (default 20, max 50)
    * `sources` (optional) — list of source ids to restrict to
  """
  def recall(conn, params) do
    user_id = conn.assigns.current_user_id

    case extract_recall_args(params, user_id) do
      {:ok, args} ->
        case RecallAnywhere.execute(args) do
          {:ok, result} ->
            json(conn, result)

          {:error, reason} ->
            Logger.warning("companion recall failed", reason: inspect(reason))

            conn
            |> put_status(:bad_request)
            |> json(ApiErrorCopy.companion_recall(reason))
        end

      {:error, message} ->
        conn
        |> put_status(:bad_request)
        |> json(ApiErrorCopy.companion_recall(message))
    end
  end

  @doc """
  GET /api/v1/companion/whoami

  Returns the email + device metadata the current bearer token is bound to.
  """
  def whoami(conn, _params) do
    device = conn.assigns.current_device
    user_id = conn.assigns.current_user_id

    email =
      case Accounts.get_user(user_id) do
        nil -> nil
        user -> user.email
      end

    json(conn, %{
      email: email,
      device_name: device.device_name,
      device_id: device.device_id,
      last_seen_at: device.last_seen_at
    })
  end

  @doc """
  GET /api/v1/companion/devices

  Returns the list of devices paired to the calling user with last-seen
  metadata and per-source row counts. The current device is flagged so
  the desktop app can render a "This Mac" badge.
  """
  def list_devices(conn, _params) do
    device = conn.assigns.current_device
    user_id = conn.assigns.current_user_id

    devices_with_stats =
      user_id
      |> Devices.list_for_user()
      |> Devices.enrich_with_stats()

    json(conn, %{
      current_device_id: device.id,
      devices: Enum.map(devices_with_stats, &serialize_device(&1, device))
    })
  end

  @doc """
  POST /api/v1/companion/devices/:id/revoke

  Revokes a paired device's bearer token. The device must belong to the
  calling user. Idempotent: a second call returns the already-revoked row.
  """
  def revoke_device(conn, %{"id" => id}) do
    user_id = conn.assigns.current_user_id

    case Devices.revoke(user_id, id) do
      {:ok, device} ->
        json(conn, %{
          status: "revoked",
          device_id: device.device_id,
          id: device.id,
          revoked_at: device.revoked_at
        })

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(ApiErrorCopy.companion_device(:not_found))
    end
  end

  @doc """
  DELETE /api/v1/companion/devices/:id

  Deletes a paired device and purges every `local_*` row that belongs to
  it. Returns the per-source delete counts so the caller can show a
  receipt. The device must belong to the calling user.
  """
  def delete_device(conn, %{"id" => id}) do
    user_id = conn.assigns.current_user_id

    case Devices.delete(user_id, id) do
      {:ok, %{device: device, deleted: counts}} ->
        json(conn, %{
          status: "deleted",
          device_id: device.device_id,
          id: device.id,
          deleted: counts
        })

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(ApiErrorCopy.companion_device(:not_found))

      {:error, reason} ->
        Logger.warning("companion device delete failed", reason: inspect(reason))

        conn
        |> put_status(:bad_request)
        |> json(ApiErrorCopy.companion_device(:delete_failed))
    end
  end

  @doc """
  DELETE /api/v1/companion/devices/:id/data
  DELETE /api/v1/companion/devices/:id/data/:source

  Deletes synced source data for the currently authenticated Mac without
  revoking or removing the device pairing. The endpoint is intentionally
  scoped to the bearer token's own device so a stolen token cannot delete
  historical data for another paired Mac.
  """
  def purge_device_data(conn, %{"id" => id} = params) do
    device = conn.assigns.current_device
    user_id = conn.assigns.current_user_id

    if current_device_id?(device, id) do
      case Devices.purge_data(user_id, device.device_id, Map.get(params, "source")) do
        {:ok, deleted} ->
          json(conn, %{deleted: deleted})

        {:error, :unsupported_source} ->
          conn
          |> put_status(:bad_request)
          |> json(ApiErrorCopy.companion_device(:unsupported_source))
      end
    else
      conn
      |> put_status(:not_found)
      |> json(ApiErrorCopy.companion_device(:not_found))
    end
  end

  @doc """
  DELETE /api/v1/companion/devices/:id/messages

  Purges all local messages for a given device row id. The device must
  belong to the user identified by the bearer token; we also accept the
  caller purging their own currently-authenticated device.
  """
  def purge_messages(conn, %{"id" => id}) do
    device = conn.assigns.current_device
    user_id = conn.assigns.current_user_id

    cond do
      current_device_id?(device, id) ->
        {:ok, %{messages: deleted}} = Devices.purge_data(user_id, device.device_id, "messages")
        json(conn, %{deleted: deleted})

      true ->
        conn
        |> put_status(:not_found)
        |> json(ApiErrorCopy.companion_device(:not_found))
    end
  end

  @doc """
  POST /api/v1/companion/device-keys

  Uploads (or refreshes) a Curve25519 public key for the calling device.
  The device retains the matching private half in its Keychain and uses
  it to derive per-record content-encryption keys for opt-in client-side
  encryption.

  Body:

      {
        "key_id": "<short, client-chosen identifier>",
        "public_key": "<base64-encoded Curve25519 public key>"
      }
  """
  def upload_device_key(conn, params) do
    device = conn.assigns.current_device
    user_id = conn.assigns.current_user_id

    with {:ok, key_id} <- fetch_key_id(params),
         {:ok, public_key} <- fetch_public_key(params),
         {:ok, key} <-
           DeviceKeys.upsert(user_id, device.device_id, %{
             key_id: key_id,
             public_key: public_key
           }) do
      json(conn, %{
        key_id: key.key_id,
        public_key: key.public_key,
        device_id: device.device_id
      })
    else
      {:error, :missing_key_id} ->
        conn
        |> put_status(:bad_request)
        |> json(ApiErrorCopy.companion_device_key(:missing_key_id))

      {:error, :missing_public_key} ->
        conn
        |> put_status(:bad_request)
        |> json(ApiErrorCopy.companion_device_key(:missing_public_key))

      {:error, %Ecto.Changeset{} = changeset} ->
        Logger.warning("device_key upload invalid",
          errors: inspect(changeset.errors)
        )

        conn
        |> put_status(:bad_request)
        |> json(ApiErrorCopy.companion_device_key(changeset))

      {:error, reason} ->
        Logger.warning("device_key upload failed", reason: inspect(reason))

        conn
        |> put_status(:bad_request)
        |> json(ApiErrorCopy.companion_device_key(reason))
    end
  end

  @doc """
  GET /api/v1/companion/device-keys/me

  Returns the newest non-revoked public key currently on file for the
  calling device. The device uses this to detect server-side drift —
  e.g. another paired Mac uploaded a different key against the same
  `device_id` — so it can decide whether to re-pair or keep encrypting
  with the local Keychain key.

  Returns `{"key": null}` when the device has not yet uploaded a key.
  """
  def current_device_key(conn, _params) do
    device = conn.assigns.current_device
    user_id = conn.assigns.current_user_id

    case DeviceKeys.current_for(user_id, device.device_id) do
      nil ->
        json(conn, %{key: nil})

      key ->
        json(conn, %{
          key: %{
            key_id: key.key_id,
            public_key: key.public_key,
            inserted_at: key.inserted_at
          }
        })
    end
  end

  defp fetch_key_id(params) do
    case params["key_id"] do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, :missing_key_id}
    end
  end

  defp fetch_public_key(params) do
    case params["public_key"] do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, :missing_public_key}
    end
  end

  defp current_device_id?(device, id), do: id == device.id or id == device.device_id

  defp extract_batch(params) do
    source = params["source"] || "imessage"
    messages = params["messages"]

    cond do
      not is_list(messages) ->
        {:error, :missing_messages}

      length(messages) > @max_batch_size ->
        {:error, :too_many_messages}

      true ->
        {:ok, messages, source}
    end
  end

  defp ingest_collection(conn, params, batch_key, default_source, ingest_fun, opts \\ []) do
    device = conn.assigns.current_device
    user_id = conn.assigns.current_user_id
    max_batch = Keyword.get(opts, :max_batch, @max_batch_size)

    with {:ok, items, source} <-
           extract_collection(params, batch_key, default_source, max_batch),
         :ok <- validate_device(device, params) do
      items = Enum.map(items, &Map.put_new(stringify(&1), "source", source))

      # Match the channel handler: a Postgrex `22001` (or any other
      # exception) from `ingest_fun` must not 500 the request. Convert
      # to a `bad_request` with `invalid_batch` so the client just
      # retries the offending batch instead of treating the whole
      # source as broken.
      result =
        try do
          ingest_fun.(user_id, device.device_id, items)
        rescue
          exception ->
            Logger.error(
              "companion #{batch_key} ingest crashed",
              error: Exception.format(:error, exception, __STACKTRACE__),
              batch_size: length(items)
            )

            {:error, :ingest_exception}
        end

      case result do
        {:ok, %{accepted: accepted, duplicate: duplicate, invalid: invalid}} ->
          json(conn, %{
            accepted: accepted,
            duplicate: duplicate,
            invalid: invalid
          })

        {:error, reason} ->
          Logger.warning("companion #{batch_key} ingest failed", reason: inspect(reason))

          conn
          |> put_status(:bad_request)
          |> json(ApiErrorCopy.companion_sync(reason, batch_key))
      end
    else
      {:error, :missing_items} ->
        conn
        |> put_status(:bad_request)
        |> json(ApiErrorCopy.companion_sync(:missing_items, batch_key))

      {:error, :too_many_items} ->
        conn
        |> put_status(:bad_request)
        |> json(ApiErrorCopy.companion_sync(:too_many_items, max_batch))

      {:error, :device_mismatch} ->
        conn
        |> put_status(:bad_request)
        |> json(ApiErrorCopy.companion_sync(:device_mismatch, nil))
    end
  end

  defp extract_collection(params, batch_key, default_source, max_batch) do
    source = params["source"] || default_source
    items = params[batch_key]

    cond do
      not is_list(items) ->
        {:error, :missing_items}

      length(items) > max_batch ->
        {:error, :too_many_items}

      true ->
        {:ok, items, source}
    end
  end

  defp validate_device(device, params) do
    case params["device_id"] do
      nil ->
        :ok

      "" ->
        :ok

      provided when is_binary(provided) ->
        # Swift encodes `UUID` as uppercase, Ecto.UUID round-trips to
        # lowercase — compare case-insensitively so the macOS companion
        # doesn't 400 against its own device's lowercased identifier.
        if String.downcase(provided) == String.downcase(device.device_id || ""),
          do: :ok,
          else: {:error, :device_mismatch}

      _ ->
        {:error, :device_mismatch}
    end
  end

  defp serialize_device({device, stats}, current_device) do
    %{
      id: device.id,
      device_id: device.device_id,
      device_name: device.device_name,
      last_seen_at: device.last_seen_at,
      paired_at: device.inserted_at,
      revoked_at: device.revoked_at,
      is_current: device.id == current_device.id,
      counts: stats
    }
  end

  defp stringify(map) when is_map(map) do
    Map.new(map, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), v}
      pair -> pair
    end)
  end

  defp stringify(other), do: other

  defp extract_recall_args(params, user_id) do
    case params["query"] do
      query when is_binary(query) and query != "" ->
        limit = normalize_recall_limit(params["limit"])

        args =
          %{"user_id" => user_id, "query" => query, "limit" => limit}
          |> maybe_add_sources(params["sources"])

        {:ok, args}

      _ ->
        {:error, :missing_query}
    end
  end

  defp normalize_recall_limit(value) when is_integer(value) and value > 0,
    do: min(value, @recall_max_limit)

  defp normalize_recall_limit(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, ""} when parsed > 0 -> min(parsed, @recall_max_limit)
      _ -> @recall_default_limit
    end
  end

  defp normalize_recall_limit(_), do: @recall_default_limit

  defp maybe_add_sources(args, sources) when is_list(sources) do
    Map.put(args, "sources", sources)
  end

  defp maybe_add_sources(args, _), do: args
end
