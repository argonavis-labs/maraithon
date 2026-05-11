defmodule MaraithonWeb.CompanionChannel do
  @moduledoc """
  Realtime channel for the Maraithon Companion macOS app.

  Joined at `companion:device:<device_id>`; the join only succeeds when
  the `<device_id>` segment matches the device bound to the bearer token
  the socket connected with (see `MaraithonWeb.CompanionSocket`). This
  keeps a compromised token from joining a different device's topic.

  Each ingest message accepted by this channel mirrors one of the HTTP
  endpoints under `/api/v1/companion/*`. The reducer logic — dedupe via
  `(user_id, device_id, source, guid)`, privacy filtering, telemetry —
  lives in the `Maraithon.Local*` context modules, so the channel only
  shapes the inbound payload and forwards it.

  Supported inbound events:

    * `"ingest:messages"`
    * `"ingest:notes"`
    * `"ingest:voice_memos"`
    * `"ingest:calendar_events"`
    * `"ingest:reminders"`
    * `"ingest:files"`
    * `"ingest:browser_history"`

  Each reply mirrors the HTTP response shape, e.g.
  `{:ok, %{accepted: 3, duplicate: 1, invalid: 0}}` for collections;
  `browser_history` additionally returns `filtered`.
  """

  use MaraithonWeb, :channel

  require Logger

  alias Maraithon.LocalBrowserHistory
  alias Maraithon.LocalCalendar
  alias Maraithon.LocalFiles
  alias Maraithon.LocalMessages
  alias Maraithon.LocalNotes
  alias Maraithon.LocalReminders
  alias Maraithon.LocalVoiceMemos

  @impl true
  def join("companion:device:" <> requested_device_id, _params, socket) do
    device = socket.assigns.current_device

    if requested_device_id == device.device_id do
      :telemetry.execute(
        [:maraithon, :companion, :channel_joined],
        %{count: 1},
        %{user_id: device.user_id, device_id: device.device_id}
      )

      {:ok, %{device_id: device.device_id}, socket}
    else
      {:error, %{reason: "device_mismatch"}}
    end
  end

  @impl true
  def terminate(reason, socket) do
    case socket.assigns[:current_device] do
      nil ->
        :ok

      device ->
        :telemetry.execute(
          [:maraithon, :companion, :channel_dropped],
          %{count: 1},
          %{
            user_id: device.user_id,
            device_id: device.device_id,
            reason: inspect(reason)
          }
        )

        :ok
    end
  end

  @impl true
  def handle_in("ingest:messages", payload, socket) do
    handle_collection(socket, payload, "messages", "imessage", &LocalMessages.ingest_batch/3)
  end

  @impl true
  def handle_in("ingest:notes", payload, socket) do
    handle_collection(socket, payload, "notes", "notes", &LocalNotes.ingest_batch/3)
  end

  @impl true
  def handle_in("ingest:voice_memos", payload, socket) do
    handle_collection(
      socket,
      payload,
      "voice_memos",
      "voice_memos",
      &LocalVoiceMemos.ingest_batch/3
    )
  end

  @impl true
  def handle_in("ingest:calendar_events", payload, socket) do
    handle_collection(
      socket,
      payload,
      "calendar_events",
      "calendar",
      &LocalCalendar.ingest_batch/3
    )
  end

  @impl true
  def handle_in("ingest:reminders", payload, socket) do
    handle_collection(socket, payload, "reminders", "reminders", &LocalReminders.ingest_batch/3)
  end

  @impl true
  def handle_in("ingest:files", payload, socket) do
    handle_collection(socket, payload, "files", "files", &LocalFiles.ingest_batch/3)
  end

  @impl true
  def handle_in("ingest:browser_history", payload, socket) do
    device = socket.assigns.current_device
    user_id = socket.assigns.current_user_id

    case extract_collection(payload, "visits", "browser_history") do
      {:ok, items, source} ->
        items = Enum.map(items, &Map.put_new(stringify(&1), "source", source))

        case LocalBrowserHistory.ingest_batch(user_id, device.device_id, items) do
          {:ok, %{accepted: a, duplicate: d, invalid: i, filtered: f} = result} ->
            emit_ingested(device, "browser_history", result)
            {:reply, {:ok, %{accepted: a, duplicate: d, invalid: i, filtered: f}}, socket}

          {:error, reason} ->
            Logger.warning("companion channel browser_history ingest failed",
              reason: inspect(reason)
            )

            {:reply, {:error, %{reason: "invalid_batch"}}, socket}
        end

      {:error, :missing_items} ->
        {:reply, {:error, %{reason: "visits_required"}}, socket}
    end
  end

  @impl true
  def handle_in(event, _payload, socket) do
    Logger.debug("companion channel ignoring unknown event", event: event)
    {:reply, {:error, %{reason: "unknown_event"}}, socket}
  end

  defp handle_collection(socket, payload, batch_key, default_source, ingest_fun) do
    device = socket.assigns.current_device
    user_id = socket.assigns.current_user_id

    case extract_collection(payload, batch_key, default_source) do
      {:ok, items, source} ->
        items = Enum.map(items, &Map.put_new(stringify(&1), "source", source))

        case ingest_fun.(user_id, device.device_id, items) do
          {:ok, %{accepted: a, duplicate: d, invalid: i} = result} ->
            emit_ingested(device, batch_key, result)
            {:reply, {:ok, %{accepted: a, duplicate: d, invalid: i}}, socket}

          {:error, reason} ->
            Logger.warning("companion channel #{batch_key} ingest failed",
              reason: inspect(reason)
            )

            {:reply, {:error, %{reason: "invalid_batch"}}, socket}
        end

      {:error, :missing_items} ->
        {:reply, {:error, %{reason: "#{batch_key}_required"}}, socket}
    end
  end

  defp extract_collection(payload, batch_key, default_source) do
    items = payload[batch_key] || payload[String.to_atom(batch_key)]
    source = payload["source"] || payload[:source] || default_source

    cond do
      is_list(items) -> {:ok, items, source}
      true -> {:error, :missing_items}
    end
  end

  defp emit_ingested(device, batch_key, result) do
    :telemetry.execute(
      [:maraithon, :companion, :channel_ingested],
      Map.merge(%{count: 1}, numeric_metrics(result)),
      %{
        user_id: device.user_id,
        device_id: device.device_id,
        batch: batch_key
      }
    )
  end

  defp numeric_metrics(map) when is_map(map) do
    map
    |> Enum.filter(fn {_k, v} -> is_integer(v) end)
    |> Map.new()
  end

  defp stringify(map) when is_map(map) do
    Map.new(map, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), v}
      pair -> pair
    end)
  end

  defp stringify(other), do: other
end
