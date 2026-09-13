defmodule MaraithonWeb.TodoWorkspace do
  @moduledoc "The web todo's conversation lifecycle. Execution remains in AssistantChat's durable workers."
  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [start_async: 3, connected?: 1]

  alias Maraithon.AssistantChat
  alias Maraithon.AssistantChat.Progress
  alias MaraithonWeb.AssistantProgress

  def empty do
    %{
      todo_id: nil,
      thread: nil,
      history_limit: 60,
      loading?: false,
      busy?: false,
      error: nil,
      timer: nil,
      pulse: nil,
      subscription: nil
    }
  end

  def load(socket) do
    todo = socket.assigns.selected_todo
    state = socket.assigns.workspace

    cond do
      not connected?(socket) ->
        socket

      todo && todo.id == state.todo_id ->
        socket

      true ->
        cancel_timer(state)
        unsubscribe(state)
        socket = assign(socket, :workspace, empty())

        if todo do
          user_id = socket.assigns.current_user.id

          socket
          |> put(todo_id: todo.id, loading?: true)
          |> start_async({:workspace, todo.id, :load}, fn ->
            user_id |> AssistantChat.get_or_create_todo_thread(todo.id) |> project_result()
          end)
        else
          socket
        end
    end
  end

  def event("refresh", _params, socket) do
    if socket.assigns.workspace.thread do
      {:noreply, refresh(socket)}
    else
      {:noreply, socket |> put(todo_id: nil) |> load()}
    end
  end

  def event("earlier", _params, socket) do
    {:noreply, put(socket, history_limit: socket.assigns.workspace.history_limit + 60)}
  end

  def event("send", %{"body" => body, "client_message_id" => id}, socket)
      when is_binary(body) and is_binary(id) do
    state = socket.assigns.workspace
    body = String.trim(body)

    cond do
      state.busy? || state.loading? || is_nil(state.thread) ->
        {:noreply, socket}

      body == "" ->
        {:noreply, socket}

      byte_size(body) > 16_384 ->
        {:noreply, put(socket, error: "That message is too long. Shorten it and try again.")}

      Ecto.UUID.cast(id) == :error ->
        {:noreply,
         put(socket,
           error: "Refresh the page before trying again. Your draft is kept in this tab."
         )}

      true ->
        user_id = socket.assigns.current_user.id
        thread_id = state.thread.id

        {:noreply,
         socket
         |> stop_poll()
         |> put(busy?: true, error: nil)
         |> start_async({:workspace, state.todo_id, :send}, fn ->
           AssistantChat.send_message(user_id, thread_id, %{
             "body" => body,
             "client_message_id" => id
           })
           |> project_result()
         end)}
    end
  end

  def event("decide", %{"action_id" => action_id, "decision" => decision} = params, socket)
      when is_binary(action_id) and decision in ["confirm", "reject"] do
    state = socket.assigns.workspace
    card = find_card(state.thread, action_id)

    cond do
      state.busy? || state.loading? ->
        {:noreply, socket}

      is_nil(card) ->
        {:noreply,
         put(socket, error: "This action has changed. Refresh the conversation to review it.")}

      decision == "confirm" && card["connection_required"] == true ->
        {:noreply,
         put(socket,
           error: card["connection_notice"] || "Connect this account before continuing."
         )}

      true ->
        user_id = socket.assigns.current_user.id
        edits = Map.take(params["draft_edits"] || %{}, ~w(recipient subject body cc bcc))

        {:noreply,
         socket
         |> stop_poll()
         |> put(busy?: true, error: nil)
         |> start_async({:workspace, state.todo_id, :decide}, fn ->
           AssistantChat.decide_prepared_action(user_id, action_id, decision, %{
             "draft_edits" => edits
           })
           |> project_result()
         end)}
    end
  end

  def event(_, _, socket), do: {:noreply, socket}

  def context_changed(socket) do
    state = socket.assigns.workspace

    if state.thread && not state.busy? && not state.loading? do
      user_id = socket.assigns.current_user.id
      todo_id = state.todo_id

      socket
      |> stop_poll()
      |> put(loading?: true)
      |> start_async({:workspace, todo_id, :context}, fn ->
        user_id |> AssistantChat.get_or_create_todo_thread(todo_id) |> project_result()
      end)
    else
      socket
    end
  end

  def result(todo_id, operation, result, socket) do
    if socket.assigns.workspace.todo_id == todo_id do
      socket = put(socket, loading?: false, busy?: false)

      socket =
        case result do
          {:ok, {:ok, thread}} ->
            put(socket, thread: thread, error: nil)

          {:ok, {:error, :assistant_run_in_progress, thread}} ->
            put(socket,
              thread: thread,
              error:
                "Maraithon is still working. Your message is kept here; send it when the reply arrives."
            )

          {:ok, {:error, :prepared_action_expired, thread}} ->
            put(socket,
              thread: thread,
              error: "This action expired. Ask Maraithon to prepare it again."
            )

          _ ->
            error =
              if operation == :decide,
                do:
                  "Could not confirm the outcome. Refresh to check the action before trying again.",
                else: "Could not refresh the conversation. Your draft is kept here. Try again."

            put(socket, error: error)
        end

      {:noreply, socket |> subscribe() |> schedule_poll()}
    else
      {:noreply, socket}
    end
  end

  def progress(thread_id, socket) do
    state = socket.assigns.workspace

    if state.thread && state.thread.id == thread_id && not state.loading? && not state.busy? do
      # Coalesce lifecycle hints, including bursts of tool-step writes.
      socket = stop_poll(socket)
      pulse = make_ref()
      timer = Process.send_after(self(), {:workspace_poll, pulse}, 300)
      {:noreply, put(socket, timer: timer, pulse: pulse)}
    else
      {:noreply, socket}
    end
  end

  def preview(thread_id, preview, socket) do
    state = socket.assigns.workspace

    if state.thread && state.thread.id == thread_id do
      {:noreply, put(socket, thread: AssistantProgress.apply_preview(state.thread, preview))}
    else
      {:noreply, socket}
    end
  end

  def poll(pulse, socket) do
    if socket.assigns.workspace.pulse == pulse do
      {:noreply, socket |> put(timer: nil, pulse: nil) |> refresh()}
    else
      {:noreply, socket}
    end
  end

  defp refresh(socket) do
    state = socket.assigns.workspace

    if state.thread && not state.busy? && not state.loading? do
      user_id = socket.assigns.current_user.id
      thread_id = state.thread.id

      socket
      |> stop_poll()
      |> put(loading?: true)
      |> start_async({:workspace, state.todo_id, :refresh}, fn ->
        AssistantChat.get_thread(user_id, thread_id) |> project_result()
      end)
    else
      socket
    end
  end

  defp project_result({:ok, %{thread: thread}}), do: {:ok, project(thread)}
  defp project_result({:ok, thread}), do: {:ok, project(thread)}

  defp project_result({:error, reason, _action_or_run, thread}),
    do: {:error, reason, project(thread)}

  defp project_result(other), do: other

  defp project(thread) do
    # Use the same account, expiry, approval and public-copy projection as native clients.
    AssistantProgress.project(thread).thread
    |> Map.update!(:pending_run, fn
      %{status: status} = run when status in ["queued", "running"] -> run
      _ -> nil
    end)
    |> Map.update!(:messages, fn messages ->
      Enum.filter(
        messages,
        &(&1.role in ~w(user assistant) &&
            (&1.body not in [nil, ""] || &1.structured_data["draft_card"]))
      )
    end)
  end

  defp find_card(nil, _), do: nil

  defp find_card(thread, action_id) do
    thread.messages
    |> Enum.map(& &1.structured_data["draft_card"])
    |> Enum.find(&(&1 && &1["prepared_action_id"] == action_id))
  end

  defp put(socket, values),
    do: assign(socket, :workspace, Map.merge(socket.assigns.workspace, Map.new(values)))

  defp schedule_poll(socket) do
    state = socket.assigns.workspace
    cancel_timer(state)

    if state.thread && connected?(socket) do
      pulse = make_ref()
      interval = if state.thread.pending_run, do: 5_000, else: 30_000
      timer = Process.send_after(self(), {:workspace_poll, pulse}, interval)
      put(socket, timer: timer, pulse: pulse)
    else
      socket
    end
  end

  defp subscribe(socket) do
    state = socket.assigns.workspace
    key = if state.thread, do: {socket.assigns.current_user.id, state.thread.id}

    if key && key != state.subscription do
      unsubscribe(state)
      {user_id, thread_id} = key
      Progress.subscribe(user_id, thread_id)
      put(socket, subscription: key)
    else
      socket
    end
  end

  defp unsubscribe(%{subscription: {user_id, thread_id}}),
    do: Progress.unsubscribe(user_id, thread_id)

  defp unsubscribe(_), do: :ok

  defp stop_poll(socket) do
    cancel_timer(socket.assigns.workspace)
    put(socket, timer: nil, pulse: nil)
  end

  defp cancel_timer(%{timer: timer}) when is_reference(timer), do: Process.cancel_timer(timer)
  defp cancel_timer(_), do: :ok
end
