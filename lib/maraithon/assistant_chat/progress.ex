defmodule Maraithon.AssistantChat.Progress do
  @moduledoc """
  Best-effort progress hints. Conversation/run rows remain the durable source.

  Hints never authorize work and may arrive before an enclosing transaction
  commits. Consumers periodically reconcile and always reload on reconnect.
  """
  alias Maraithon.TelegramAssistant.{Run, Step, RunStreamPreview}
  alias Maraithon.Repo

  def topic(user_id, thread_id), do: "assistant-progress:#{user_id}:#{thread_id}"

  def subscribe(user_id, thread_id),
    do: Phoenix.PubSub.subscribe(Maraithon.PubSub, topic(user_id, thread_id))

  def unsubscribe(user_id, thread_id),
    do: Phoenix.PubSub.unsubscribe(Maraithon.PubSub, topic(user_id, thread_id))

  def changed(user_id, thread_id) when is_binary(user_id) and is_binary(thread_id) do
    Phoenix.PubSub.broadcast(
      Maraithon.PubSub,
      topic(user_id, thread_id),
      {:assistant_progress, thread_id}
    )

    :ok
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  def changed(_, _), do: :ok

  def notify_result({:ok, %Run{} = run} = result) do
    RunStreamPreview.bind(run)
    changed(run.user_id, run.conversation_id)
    result
  end

  def notify_result({:ok, %Step{run_id: run_id}} = result) do
    case Repo.get(Run, run_id) do
      %Run{} = run -> changed(run.user_id, run.conversation_id)
      _ -> :ok
    end

    result
  rescue
    _ -> result
  catch
    :exit, _ -> result
  end

  def notify_result({:ok, %{user_id: user_id, conversation_id: thread_id}} = result) do
    changed(user_id, thread_id)
    result
  end

  def notify_result(result), do: result

  def preview(user_id, thread_id, run_id, reply) do
    Phoenix.PubSub.broadcast(
      Maraithon.PubSub,
      topic(user_id, thread_id),
      {:assistant_preview, thread_id,
       %{schema_version: 1, thread_id: thread_id, run_id: run_id, reply: reply}}
    )
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end
end
