defmodule Maraithon.TelegramAssistant.RunStreamPreview do
  @moduledoc """
  In-memory rolling preview of the reply text a run is currently streaming.

  Polling surfaces (mobile/web chat) read this so the user watches the
  answer being written instead of staring at a spinner during long model
  turns. Entries are best-effort: lost on restart, swept after a few
  minutes, and reset whenever a new model turn starts streaming.
  """

  use GenServer

  @table __MODULE__
  @sweep_interval :timer.minutes(2)
  @max_age_ms :timer.minutes(10)
  @max_chars 600

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @doc "Clears the preview for a run; called when a model turn starts streaming."
  def reset(run_id) when is_binary(run_id) do
    safe_insert(run_id, "")
  end

  def reset(_run_id), do: :ok

  @doc "Appends streamed reply text to a run's preview."
  def append(run_id, delta) when is_binary(run_id) and is_binary(delta) and delta != "" do
    current =
      case safe_lookup(run_id) do
        {text, _at} -> text
        nil -> ""
      end

    safe_insert(run_id, tail_text(current <> delta))
  end

  def append(_run_id, _delta), do: :ok

  @doc "Returns the current preview text for a run, or nil."
  def snapshot(run_id) when is_binary(run_id) do
    case safe_lookup(run_id) do
      {"", _at} -> nil
      {text, _at} -> text
      nil -> nil
    end
  end

  def snapshot(_run_id), do: nil

  @doc "Drops the preview once a run finishes."
  def delete(run_id) when is_binary(run_id) do
    :ets.delete(@table, run_id)
    :ok
  rescue
    ArgumentError -> :ok
  end

  def delete(_run_id), do: :ok

  @impl true
  def init(_args) do
    :ets.new(@table, [:set, :public, :named_table, read_concurrency: true])
    schedule_sweep()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:sweep, state) do
    cutoff = System.monotonic_time(:millisecond) - @max_age_ms

    :ets.select_delete(@table, [{{:_, :_, :"$1"}, [{:<, :"$1", cutoff}], [true]}])

    schedule_sweep()
    {:noreply, state}
  end

  defp schedule_sweep do
    Process.send_after(self(), :sweep, @sweep_interval)
  end

  defp safe_insert(run_id, text) do
    :ets.insert(@table, {run_id, text, System.monotonic_time(:millisecond)})
    :ok
  rescue
    ArgumentError -> :ok
  end

  defp safe_lookup(run_id) do
    case :ets.lookup(@table, run_id) do
      [{^run_id, text, at}] -> {text, at}
      _ -> nil
    end
  rescue
    ArgumentError -> nil
  end

  # Keep the tail of long previews; the user only needs the live edge.
  defp tail_text(text) do
    if String.length(text) > @max_chars do
      String.slice(text, -@max_chars, @max_chars)
    else
      text
    end
  end
end
