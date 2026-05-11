defmodule Maraithon.LocalMessages.EmbedJob do
  @moduledoc """
  Background-job glue that re-embeds a single `local_messages` row after
  ingest. Enqueueing is best-effort: a record without text is skipped and
  the runner failure path leaves `embedding = NULL` so semantic search
  silently drops the row from results.

  The job payload is `%{"record_id" => <uuid>}`. The handler in
  `Maraithon.Runtime.BackgroundJobHandler` dispatches on
  `job_type = "local_messages_embed"`.
  """

  alias Maraithon.LocalEmbeddings
  alias Maraithon.LocalMessages.LocalMessage
  alias Maraithon.Repo
  alias Maraithon.Runtime.BackgroundJobs

  require Logger

  @job_type "local_messages_embed"
  @table "local_messages"

  @doc "Job type string that BackgroundJobHandler dispatches on."
  def job_type, do: @job_type

  @doc "Table name the embedding is written to."
  def table, do: @table

  @doc """
  Enqueue an embed job for `record_id` belonging to `user_id`.

  Returns `:ok` always — failures to enqueue are logged but never raised,
  because losing an embedding is a recoverable degradation, not a data
  integrity issue.
  """
  def enqueue(user_id, record_id) when is_binary(user_id) and is_binary(record_id) do
    BackgroundJobs.enqueue(@job_type, %{
      "user_id" => user_id,
      "queue" => "local_embeddings",
      "payload" => %{"record_id" => record_id},
      "dedupe_key" => "local_messages_embed:#{record_id}"
    })
    |> handle_enqueue(record_id)
  rescue
    exception ->
      Logger.warning("local_messages embed enqueue crashed",
        record_id: record_id,
        reason: Exception.message(exception)
      )

      :ok
  end

  def enqueue(_user_id, _record_id), do: :ok

  defp handle_enqueue({:ok, _job}, _record_id), do: :ok

  defp handle_enqueue({:error, reason}, record_id) do
    Logger.warning("local_messages embed enqueue failed",
      record_id: record_id,
      reason: inspect(reason)
    )

    :ok
  end

  @doc """
  Execute the embed for `record_id`. Called from the background job
  handler. Returns `{:ok, result}` or `{:error, reason}`.
  """
  def run(record_id) when is_binary(record_id) do
    case Repo.get(LocalMessage, record_id) do
      nil ->
        {:ok, %{status: "missing", record_id: record_id}}

      %LocalMessage{} = message ->
        text = source_text(message)

        case LocalEmbeddings.refresh(@table, record_id, text) do
          {:ok, status} ->
            {:ok, %{status: status, record_id: record_id}}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  def run(_), do: {:error, :invalid_record_id}

  @doc """
  Canonical embedding source text for a `LocalMessage`. Empty messages
  (purely attachments, etc.) collapse to `nil` so we skip them.
  """
  def source_text(%LocalMessage{} = msg) do
    [msg.text, msg.chat_display_name, msg.sender_handle]
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
