defmodule Maraithon.LocalCalendar.EmbedJob do
  @moduledoc """
  Background-job glue that re-embeds a single `local_calendar_events` row.

  Source text is `title + notes + location` (skipping blanks). Events that
  are pure timeslots without any text — extremely rare but possible —
  collapse to `nil` and are skipped.
  """

  alias Maraithon.LocalCalendar.LocalEvent
  alias Maraithon.LocalEmbeddings
  alias Maraithon.Repo
  alias Maraithon.Runtime.BackgroundJobs

  require Logger

  @job_type "local_calendar_events_embed"
  @table "local_calendar_events"

  def job_type, do: @job_type
  def table, do: @table

  def enqueue(user_id, record_id) when is_binary(user_id) and is_binary(record_id) do
    BackgroundJobs.enqueue(@job_type, %{
      "user_id" => user_id,
      "queue" => "local_embeddings",
      "payload" => %{"record_id" => record_id},
      "dedupe_key" => "local_calendar_events_embed:#{record_id}"
    })
    |> handle_enqueue(record_id)
  rescue
    exception ->
      Logger.warning("local_calendar_events embed enqueue crashed",
        record_id: record_id,
        reason: Exception.message(exception)
      )

      :ok
  end

  def enqueue(_user_id, _record_id), do: :ok

  defp handle_enqueue({:ok, _job}, _record_id), do: :ok

  defp handle_enqueue({:error, reason}, record_id) do
    Logger.warning("local_calendar_events embed enqueue failed",
      record_id: record_id,
      reason: inspect(reason)
    )

    :ok
  end

  def run(record_id) when is_binary(record_id) do
    case Repo.get(LocalEvent, record_id) do
      nil ->
        {:ok, %{status: "missing", record_id: record_id}}

      %LocalEvent{} = event ->
        text = source_text(event)

        case LocalEmbeddings.refresh(@table, record_id, text) do
          {:ok, status} ->
            {:ok, %{status: status, record_id: record_id}}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  def run(_), do: {:error, :invalid_record_id}

  def source_text(%LocalEvent{} = event) do
    [event.title, event.notes, event.location]
    |> Enum.reject(&blank?/1)
    |> Enum.uniq()
    |> Enum.join("\n")
    |> normalize()
  end

  def source_text(_), do: nil

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(_), do: true

  defp normalize(""), do: nil

  defp normalize(text) when is_binary(text) do
    case String.trim(text) do
      "" -> nil
      trimmed -> trimmed
    end
  end
end
