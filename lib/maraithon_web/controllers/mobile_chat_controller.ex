defmodule MaraithonWeb.MobileChatController do
  use MaraithonWeb, :controller

  alias Maraithon.AssistantChat
  alias Maraithon.TelegramAssistant.Run
  alias Maraithon.TelegramConversations.Conversation
  alias MaraithonWeb.MobileChatJSON

  def index(conn, params) do
    user_id = conn.assigns.current_user.id

    {:ok, threads} = AssistantChat.list_threads(user_id, limit: limit(params))
    json(conn, MobileChatJSON.thread_index(threads))
  end

  def create(conn, params) do
    user_id = conn.assigns.current_user.id

    case AssistantChat.create_thread(user_id, thread_params(params)) do
      {:ok, thread} ->
        conn
        |> put_status(:created)
        |> json(MobileChatJSON.thread(thread))

      {:error, reason} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(MobileChatJSON.error(reason))
    end
  end

  def show(conn, %{"id" => thread_id}) do
    user_id = conn.assigns.current_user.id

    case AssistantChat.get_thread(user_id, thread_id) do
      {:ok, thread} ->
        json(conn, MobileChatJSON.thread(thread))

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(MobileChatJSON.error(:not_found))
    end
  end

  def create_message(conn, %{"thread_id" => thread_id} = params) do
    user_id = conn.assigns.current_user.id

    case AssistantChat.send_message(user_id, thread_id, message_params(params)) do
      {:ok, %{thread: %Conversation{} = thread, run: %Run{} = run}} ->
        status = if run.status in ["queued", "running"], do: :accepted, else: :ok

        conn
        |> put_status(status)
        |> json(MobileChatJSON.thread_with_run(thread, run))

      {:ok, %{thread: %Conversation{} = thread}} ->
        json(conn, MobileChatJSON.thread(thread))

      {:error, :assistant_run_in_progress, %Run{} = run, %Conversation{} = thread} ->
        conn
        |> put_status(:conflict)
        |> json(
          Map.merge(MobileChatJSON.error(:assistant_run_in_progress), %{
            run: MobileChatJSON.run(run),
            thread: Map.fetch!(MobileChatJSON.thread(thread), :thread)
          })
        )

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(MobileChatJSON.error(:not_found))

      {:error, reason} ->
        conn
        |> put_status(status_for_error(reason))
        |> json(MobileChatJSON.error(reason))
    end
  end

  def show_run(conn, %{"id" => run_id}) do
    user_id = conn.assigns.current_user.id

    case AssistantChat.get_run(user_id, run_id) do
      {:ok, run} ->
        json(conn, %{run: MobileChatJSON.run(run)})

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(MobileChatJSON.error(:not_found))
    end
  end

  def decide_prepared_action(conn, %{"id" => prepared_action_id} = params) do
    user_id = conn.assigns.current_user.id
    decision = text_param(params, "decision") || get_in(params, ["decision", "value"])

    case AssistantChat.decide_prepared_action(user_id, prepared_action_id, decision, params) do
      {:ok, %{prepared_action: prepared_action, thread: thread}} ->
        json(conn, MobileChatJSON.action_result(prepared_action, thread))

      {:error, :prepared_action_expired, prepared_action, thread} ->
        conn
        |> put_status(:gone)
        |> json(
          Map.merge(MobileChatJSON.action_result(prepared_action, thread), %{
            error: "prepared_action_expired"
          })
        )

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(MobileChatJSON.error(:not_found))

      {:error, reason} ->
        conn
        |> put_status(status_for_error(reason))
        |> json(MobileChatJSON.error(reason))
    end
  end

  defp thread_params(%{"thread" => thread}) when is_map(thread), do: thread
  defp thread_params(params), do: params

  defp message_params(%{"message" => message}) when is_map(message), do: message
  defp message_params(params), do: params

  defp limit(params) do
    case Integer.parse(to_string(Map.get(params, "limit", "50"))) do
      {value, ""} -> value |> max(1) |> min(100)
      _ -> 50
    end
  end

  defp status_for_error(:message_too_long), do: :unprocessable_entity
  defp status_for_error(:missing_client_message_id), do: :unprocessable_entity
  defp status_for_error(:empty_message), do: :unprocessable_entity
  defp status_for_error(:invalid_decision), do: :bad_request
  defp status_for_error(_reason), do: :unprocessable_entity

  defp text_param(params, key) do
    case Map.get(params, key) do
      value when is_binary(value) ->
        value = String.trim(value)
        if value == "", do: nil, else: value

      _ ->
        nil
    end
  end
end
