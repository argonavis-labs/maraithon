defmodule Maraithon.LocalFiles.EmbedJob do
  @moduledoc """
  Background-job glue that re-embeds a single `local_files` row. Source
  text is `filename + path + text_content`; files without extracted text
  (binary formats, images, archives) still embed on filename + path so
  recall can match by filename.
  """

  alias Maraithon.LocalEmbeddings
  alias Maraithon.LocalFiles.LocalFile
  alias Maraithon.Repo
  alias Maraithon.Runtime.BackgroundJobs

  require Logger

  @job_type "local_files_embed"
  @table "local_files"
  # We cap the text portion to bound OpenAI request size + cost. Long
  # PDFs/Markdown files would otherwise drown the embedding signal in
  # boilerplate (and blow past the 8K token input cap on most models).
  @max_text_chars 4_000

  def job_type, do: @job_type
  def table, do: @table

  def enqueue(user_id, record_id) when is_binary(user_id) and is_binary(record_id) do
    BackgroundJobs.enqueue(@job_type, %{
      "user_id" => user_id,
      "queue" => "local_embeddings",
      "payload" => %{"record_id" => record_id},
      "dedupe_key" => "local_files_embed:#{record_id}"
    })
    |> handle_enqueue(record_id)
  rescue
    exception ->
      Logger.warning("local_files embed enqueue crashed",
        record_id: record_id,
        reason: Exception.message(exception)
      )

      :ok
  end

  def enqueue(_user_id, _record_id), do: :ok

  defp handle_enqueue({:ok, _job}, _record_id), do: :ok

  defp handle_enqueue({:error, reason}, record_id) do
    Logger.warning("local_files embed enqueue failed",
      record_id: record_id,
      reason: inspect(reason)
    )

    :ok
  end

  def run(record_id) when is_binary(record_id) do
    case Repo.get(LocalFile, record_id) do
      nil ->
        {:ok, %{status: "missing", record_id: record_id}}

      %LocalFile{} = file ->
        text = source_text(file)

        case LocalEmbeddings.refresh(@table, record_id, text) do
          {:ok, status} ->
            {:ok, %{status: status, record_id: record_id}}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  def run(_), do: {:error, :invalid_record_id}

  def source_text(%LocalFile{} = file) do
    text_excerpt = truncate(file.text_content)

    [file.filename, file.path, text_excerpt]
    |> Enum.reject(&blank?/1)
    |> Enum.uniq()
    |> Enum.join("\n")
    |> normalize()
  end

  def source_text(_), do: nil

  defp truncate(nil), do: nil

  defp truncate(value) when is_binary(value) do
    trimmed = String.trim(value)

    cond do
      trimmed == "" -> nil
      String.length(trimmed) <= @max_text_chars -> trimmed
      true -> String.slice(trimmed, 0, @max_text_chars)
    end
  end

  defp truncate(_), do: nil

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
