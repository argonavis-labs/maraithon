defmodule MaraithonWeb.CompanionController do
  @moduledoc """
  JSON endpoints used by the Maraithon Companion macOS app, gated by
  `MaraithonWeb.Plugs.CompanionDeviceAuth` which assigns
  `:current_device` and `:current_user_id`.
  """

  use MaraithonWeb, :controller

  require Logger

  alias Maraithon.Accounts
  alias Maraithon.LocalMessages
  alias Maraithon.LocalNotes
  alias Maraithon.LocalVoiceMemos

  @max_batch_size 500

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

      case LocalMessages.ingest_batch(user_id, device.device_id, messages) do
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
          |> json(%{error: "invalid_batch"})
      end
    else
      {:error, :missing_messages} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "messages array is required"})

      {:error, :too_many_messages} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "batch exceeds maximum of #{@max_batch_size}"})

      {:error, :device_mismatch} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "device_id does not match this token"})
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
  DELETE /api/v1/companion/devices/:id/messages

  Purges all local messages for a given device row id. The device must
  belong to the user identified by the bearer token; we also accept the
  caller purging their own currently-authenticated device.
  """
  def purge_messages(conn, %{"id" => id}) do
    device = conn.assigns.current_device
    user_id = conn.assigns.current_user_id

    cond do
      id == device.id or id == device.device_id ->
        {:ok, %{deleted: deleted}} = LocalMessages.purge_device(user_id, device.device_id)
        json(conn, %{deleted: deleted})

      true ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "device not found"})
    end
  end

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

  defp ingest_collection(conn, params, batch_key, default_source, ingest_fun) do
    device = conn.assigns.current_device
    user_id = conn.assigns.current_user_id

    with {:ok, items, source} <- extract_collection(params, batch_key, default_source),
         :ok <- validate_device(device, params) do
      items = Enum.map(items, &Map.put_new(stringify(&1), "source", source))

      case ingest_fun.(user_id, device.device_id, items) do
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
          |> json(%{error: "invalid_batch"})
      end
    else
      {:error, :missing_items} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "#{batch_key} array is required"})

      {:error, :too_many_items} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "batch exceeds maximum of #{@max_batch_size}"})

      {:error, :device_mismatch} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "device_id does not match this token"})
    end
  end

  defp extract_collection(params, batch_key, default_source) do
    source = params["source"] || default_source
    items = params[batch_key]

    cond do
      not is_list(items) ->
        {:error, :missing_items}

      length(items) > @max_batch_size ->
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

      provided ->
        if provided == device.device_id, do: :ok, else: {:error, :device_mismatch}
    end
  end

  defp stringify(map) when is_map(map) do
    Map.new(map, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), v}
      pair -> pair
    end)
  end

  defp stringify(other), do: other
end
