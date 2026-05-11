defmodule Maraithon.LocalReminders.EmbedJob do
  @moduledoc """
  Background-job glue that re-embeds a single `local_reminders` row.

  Reminders are mutable (completion state, title rewrites), so the
  `Maraithon.LocalReminders.ingest_batch/3` path enqueues an embed job on
  every row it accepts — `LocalEmbeddings.refresh/4` no-ops if the source
  text hasn't changed, so the cost stays bounded.
  """

  alias Maraithon.LocalEmbeddings
  alias Maraithon.LocalReminders.LocalReminder
  alias Maraithon.Repo
  alias Maraithon.Runtime.BackgroundJobs

  require Logger

  @job_type "local_reminders_embed"
  @table "local_reminders"

  def job_type, do: @job_type
  def table, do: @table

  def enqueue(user_id, record_id) when is_binary(user_id) and is_binary(record_id) do
    BackgroundJobs.enqueue(@job_type, %{
      "user_id" => user_id,
      "queue" => "local_embeddings",
      "payload" => %{"record_id" => record_id},
      "dedupe_key" => "local_reminders_embed:#{record_id}"
    })
    |> handle_enqueue(record_id)
  rescue
    exception ->
      Logger.warning("local_reminders embed enqueue crashed",
        record_id: record_id,
        reason: Exception.message(exception)
      )

      :ok
  end

  def enqueue(_user_id, _record_id), do: :ok

  defp handle_enqueue({:ok, _job}, _record_id), do: :ok

  defp handle_enqueue({:error, reason}, record_id) do
    Logger.warning("local_reminders embed enqueue failed",
      record_id: record_id,
      reason: inspect(reason)
    )

    :ok
  end

  def run(record_id) when is_binary(record_id) do
    case Repo.get(LocalReminder, record_id) do
      nil ->
        {:ok, %{status: "missing", record_id: record_id}}

      %LocalReminder{} = reminder ->
        text = source_text(reminder)

        case LocalEmbeddings.refresh(@table, record_id, text) do
          {:ok, status} ->
            {:ok, %{status: status, record_id: record_id}}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  def run(_), do: {:error, :invalid_record_id}

  def source_text(%LocalReminder{} = reminder) do
    [reminder.title, reminder.notes]
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
