defmodule MaraithonWeb.AssistantProgress do
  @moduledoc """
  Shared public progress snapshot for web and native clients.

  The opaque cursor identifies this projection, not a promise to replay every
  token or internal step. Reconnect replaces client state with the current
  authorized snapshot. Drafts and outcomes use the existing public projection.
  """
  alias Maraithon.AssistantChat
  alias MaraithonWeb.MobileChatJSON

  def snapshot(user_id, thread_id) do
    with {:ok, conversation} <- AssistantChat.get_thread(user_id, thread_id) do
      {:ok, project(conversation)}
    end
  end

  def project(conversation) do
    thread = MobileChatJSON.thread(conversation).thread
    # Streaming text is ephemeral and must not advance the durable cursor.
    thread = Map.update!(thread, :pending_run, &without_preview/1)

    cursor =
      :crypto.hash(:sha256, :erlang.term_to_binary(thread)) |> Base.url_encode64(padding: false)

    %{schema_version: 1, cursor: cursor, thread: thread}
  end

  def apply_preview(thread, %{run_id: run_id, reply: reply}) do
    case thread.pending_run do
      %{id: ^run_id, status: status} = run when status in ["queued", "running"] ->
        summary = Map.put(run.work_summary || %{}, "preview", reply)
        %{thread | pending_run: %{run | work_summary: summary}}

      _ ->
        thread
    end
  end

  defp without_preview(nil), do: nil

  defp without_preview(run) do
    Map.update(run, :work_summary, nil, fn
      summary when is_map(summary) -> Map.drop(summary, ["preview", "thinking"])
      other -> other
    end)
  end
end
