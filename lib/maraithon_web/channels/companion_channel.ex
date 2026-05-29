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
  alias MaraithonWeb.ApiErrorCopy

  @max_batch_size 500
  @max_files_batch_size 200

  @atom_batch_keys %{
    "messages" => :messages,
    "notes" => :notes,
    "voice_memos" => :voice_memos,
    "calendar_events" => :calendar_events,
    "reminders" => :reminders,
    "files" => :files,
    "visits" => :visits
  }

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
      {:error, ApiErrorCopy.companion_channel_error(:device_mismatch, nil)}
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
    handle_collection(socket, payload, "files", "files", &LocalFiles.ingest_batch/3,
      max_batch: @max_files_batch_size
    )
  end

  @impl true
  def handle_in("ingest:browser_history", payload, socket) do
    device = socket.assigns.current_device
    user_id = socket.assigns.current_user_id

    case extract_collection(payload, "visits", "browser_history", @max_batch_size) do
      {:ok, items, source} ->
        items = Enum.map(items, &Map.put_new(stringify(&1), "source", source))

        case safe_ingest("browser_history", items, fn ->
               LocalBrowserHistory.ingest_batch(user_id, device.device_id, items)
             end) do
          {:ok, %{accepted: a, duplicate: d, invalid: i, filtered: f} = result} ->
            emit_ingested(device, "browser_history", result)
            {:reply, {:ok, %{accepted: a, duplicate: d, invalid: i, filtered: f}}, socket}

          {:error, reason} ->
            Logger.warning("companion channel browser_history ingest failed",
              reason: inspect(reason)
            )

            {:reply, {:error, ApiErrorCopy.companion_channel_error(reason, "browser_history")},
             socket}
        end

      {:error, :missing_items} ->
        {:reply, {:error, ApiErrorCopy.companion_channel_error(:missing_items, "visits")}, socket}

      {:error, :too_many_items} ->
        {:reply, {:error, ApiErrorCopy.companion_channel_error(:too_many_items, @max_batch_size)},
         socket}
    end
  end

  @impl true
  def handle_in(event, _payload, socket) do
    Logger.debug("companion channel ignoring unknown event", event: event)
    {:reply, {:error, ApiErrorCopy.companion_channel_error(:unknown_event, nil)}, socket}
  end

  defp handle_collection(socket, payload, batch_key, default_source, ingest_fun, opts \\ []) do
    device = socket.assigns.current_device
    user_id = socket.assigns.current_user_id
    max_batch = Keyword.get(opts, :max_batch, @max_batch_size)

    case extract_collection(payload, batch_key, default_source, max_batch) do
      {:ok, items, source} ->
        items = Enum.map(items, &Map.put_new(stringify(&1), "source", source))

        # Wrap the ingest in `try/rescue` so a single bad row can never
        # crash the channel GenServer. Before this guard a Postgrex
        # `22001` (value too long) raised through `ingest_batch/3`
        # killed the channel for the whole device, and *every* other
        # source (iMessage, Reminders, Voice Memos) sharing that
        # channel started getting 400 until Phoenix re-supervised it.
        # Now the offending batch returns `invalid_batch`; the channel
        # stays alive and the other sources keep flowing.
        result =
          safe_ingest(batch_key, items, fn ->
            ingest_fun.(user_id, device.device_id, items)
          end)

        case result do
          {:ok, %{accepted: a, duplicate: d, invalid: i} = ok} ->
            emit_ingested(device, batch_key, ok)
            {:reply, {:ok, %{accepted: a, duplicate: d, invalid: i}}, socket}

          {:error, reason} ->
            Logger.warning("companion channel #{batch_key} ingest failed",
              reason: inspect(reason)
            )

            {:reply, {:error, ApiErrorCopy.companion_channel_error(reason, batch_key)}, socket}
        end

      {:error, :missing_items} ->
        {:reply, {:error, ApiErrorCopy.companion_channel_error(:missing_items, batch_key)},
         socket}

      {:error, :too_many_items} ->
        {:reply, {:error, ApiErrorCopy.companion_channel_error(:too_many_items, max_batch)},
         socket}
    end
  end

  defp extract_collection(payload, batch_key, default_source, max_batch) do
    items = payload[batch_key] || atom_key_value(payload, batch_key)
    source = payload["source"] || payload[:source] || default_source

    cond do
      is_list(items) and length(items) <= max_batch -> {:ok, items, source}
      is_list(items) -> {:error, :too_many_items}
      true -> {:error, :missing_items}
    end
  end

  defp safe_ingest(batch_key, items, fun) do
    try do
      fun.()
    rescue
      exception ->
        Logger.error(
          "companion channel #{batch_key} ingest crashed",
          error: Exception.format(:error, exception, __STACKTRACE__),
          batch_size: length(items)
        )

        {:error, :ingest_exception}
    end
  end

  defp atom_key_value(payload, batch_key) do
    case Map.fetch(@atom_batch_keys, batch_key) do
      {:ok, atom_key} -> payload[atom_key]
      :error -> nil
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
