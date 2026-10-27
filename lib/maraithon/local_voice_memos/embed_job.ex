defmodule Maraithon.LocalVoiceMemos.EmbedJob do
  @moduledoc """
  Background-job glue that re-embeds a single `local_voice_memos` row.

  Per spec: embed on `transcript` when present, otherwise fall back to
  `title`. Memos with neither (audio-only, no transcription engine) are
  skipped — `source_text/1` returns `nil` and `LocalEmbeddings.refresh/4`
  short-circuits to `{:ok, :empty}`.
  """

  alias Maraithon.LocalEmbeddings
  alias Maraithon.LocalVoiceMemos.LocalVoiceMemo
  alias Maraithon.Repo
  alias Maraithon.Runtime.BackgroundJobs

  require Logger

  @job_type "local_voice_memos_embed"
  @table "local_voice_memos"

  def job_type, do: @job_type
  def table, do: @table

  def enqueue(user_id, record_id) when is_binary(user_id) and is_binary(record_id) do
    BackgroundJobs.enqueue(@job_type, %{
      "user_id" => user_id,
      "queue" => "local_embeddings",
      "payload" => %{"record_id" => record_id},
      "dedupe_key" => "local_voice_memos_embed:#{record_id}"
    })
    |> handle_enqueue(record_id)
  rescue
    exception ->
      Logger.warning("local_voice_memos embed enqueue crashed",
        record_id: record_id,
        reason: Exception.message(exception)
      )

      :ok
  end

  def enqueue(_user_id, _record_id), do: :ok

  defp handle_enqueue({:ok, _job}, _record_id), do: :ok

  defp handle_enqueue({:error, reason}, record_id) do
    Logger.warning("local_voice_memos embed enqueue failed",
      record_id: record_id,
      reason: inspect(reason)
    )

    :ok
  end

  def run(record_id) when is_binary(record_id) do
    case Repo.get(LocalVoiceMemo, record_id) do
      nil ->
        {:ok, %{status: "missing", record_id: record_id}}

      %LocalVoiceMemo{} = memo ->
        text = source_text(memo)

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
  Returns transcript when present, else title, else nil.
  """
  def source_text(%LocalVoiceMemo{transcript: transcript, title: title}) do
    cond do
      is_binary(transcript) and String.trim(transcript) != "" -> String.trim(transcript)
      is_binary(title) and String.trim(title) != "" -> String.trim(title)
      true -> nil
    end
  end

  def source_text(_), do: nil
end
