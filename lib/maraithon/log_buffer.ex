defmodule Maraithon.LogBuffer do
  @moduledoc """
  Bounded in-memory buffer of recent application logs for admin inspection.
  """

  use GenServer

  @default_max_entries 500

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def record(entry) when is_map(entry) do
    if Process.whereis(__MODULE__) do
      GenServer.cast(__MODULE__, {:record, normalize_entry(entry)})
    else
      :ok
    end
  end

  def recent(limit \\ 100) when is_integer(limit) and limit > 0 do
    if Process.whereis(__MODULE__) do
      GenServer.call(__MODULE__, {:recent, limit})
    else
      []
    end
  end

  def recent_matching(limit, matcher)
      when is_integer(limit) and limit > 0 and is_function(matcher, 1) do
    if Process.whereis(__MODULE__) do
      GenServer.call(__MODULE__, {:recent_matching, limit, matcher})
    else
      []
    end
  end

  def clear do
    if Process.whereis(__MODULE__) do
      GenServer.call(__MODULE__, :clear)
    else
      :ok
    end
  end

  @impl true
  def init(opts) do
    config = Application.get_env(:maraithon, __MODULE__, [])

    max_entries =
      Keyword.get(opts, :max_entries, Keyword.get(config, :max_entries, @default_max_entries))

    {:ok, %{entries: :queue.new(), max_entries: max_entries}}
  end

  @impl true
  def handle_cast({:record, entry}, state) do
    entries =
      :queue.in(entry, state.entries)
      |> trim_to_limit(state.max_entries)

    {:noreply, %{state | entries: entries}}
  end

  @impl true
  def handle_call({:recent, limit}, _from, state) do
    entries =
      state.entries
      |> :queue.to_list()
      |> Enum.take(-limit)
      |> Enum.reverse()

    {:reply, entries, state}
  end

  def handle_call({:recent_matching, limit, matcher}, _from, state) do
    entries =
      state.entries
      |> :queue.to_list()
      |> Enum.reverse()
      |> Enum.filter(matcher)
      |> Enum.take(limit)

    {:reply, entries, state}
  end

  def handle_call(:clear, _from, state) do
    {:reply, :ok, %{state | entries: :queue.new()}}
  end

  defp trim_to_limit(entries, max_entries) do
    if :queue.len(entries) > max_entries do
      {_dropped, trimmed} = :queue.out(entries)
      trim_to_limit(trimmed, max_entries)
    else
      entries
    end
  end

  defp normalize_entry(entry) do
    %{
      timestamp:
        entry
        |> Map.get(:timestamp, Map.get(entry, "timestamp"))
        |> normalize_timestamp(),
      level:
        entry
        |> Map.get(:level, Map.get(entry, "level", :info))
        |> normalize_level(),
      message:
        entry
        |> Map.get(:message, Map.get(entry, "message", ""))
        |> normalize_message(),
      metadata:
        entry
        |> Map.get(:metadata, Map.get(entry, "metadata", %{}))
        |> normalize_metadata()
    }
  end

  defp normalize_timestamp(%DateTime{} = value), do: DateTime.to_iso8601(value)

  defp normalize_timestamp(value) when is_binary(value) and byte_size(value) <= 64 do
    case DateTime.from_iso8601(value) do
      {:ok, _datetime, _offset} -> value
      _other -> DateTime.utc_now() |> DateTime.to_iso8601()
    end
  end

  defp normalize_timestamp(_value), do: DateTime.utc_now() |> DateTime.to_iso8601()

  defp normalize_level(level)
       when level in [:debug, :info, :notice, :warning, :error, :critical, :alert, :emergency],
       do: level

  defp normalize_level(:warn), do: :warning
  defp normalize_level(_level), do: :info

  defp normalize_metadata_key(key) when is_atom(key),
    do: normalize_metadata_key(Atom.to_string(key))

  defp normalize_metadata_key(key) when is_binary(key) do
    if byte_size(key) <= 64 and String.valid?(key) and
         Regex.match?(~r/^[A-Za-z0-9_.-]+$/, key),
       do: key,
       else: nil
  end

  defp normalize_metadata_key(_key), do: nil

  defp normalize_message(value) when is_binary(value),
    do: Maraithon.Redaction.redact_string(value)

  defp normalize_message(value),
    do:
      value
      |> inspect(pretty: false, limit: 20, printable_limit: 500)
      |> Maraithon.Redaction.redact_string()

  defp normalize_metadata(metadata) when is_map(metadata) or is_list(metadata) do
    metadata
    |> Enum.take(128)
    |> Enum.reduce(%{}, fn {key, value}, acc ->
      case normalize_metadata_key(key) do
        nil ->
          acc

        safe_key ->
          if Maraithon.SafeLogMetadata.structured_key?(safe_key) do
            safe_value = Maraithon.Redaction.log_metadata_value(safe_key, value)
            Map.put(acc, safe_key, normalize_metadata_value(safe_value))
          else
            acc
          end
      end
    end)
  rescue
    _error -> %{}
  end

  defp normalize_metadata(_), do: %{}

  defp normalize_metadata_value(value) when is_binary(value), do: value

  defp normalize_metadata_value(value)
       when is_number(value) or is_boolean(value) or is_nil(value), do: value

  defp normalize_metadata_value(value),
    do: inspect(value, pretty: false, limit: 20, printable_limit: 500)
end
