defmodule MaraithonWeb.TodoChatLive do
  use MaraithonWeb, :live_view

  alias Maraithon.AssistantChat
  alias Maraithon.TelegramConversations
  alias Maraithon.Todos

  @poll_ms 2_000
  @max_polls 90

  @impl true
  def mount(%{"todo_id" => todo_id}, _session, socket) do
    user_id = socket.assigns.current_user.id
    todo = Todos.get_for_user(user_id, todo_id)

    cond do
      is_nil(todo) ->
        {:ok,
         socket
         |> put_flash(:error, "That work item could not be found.")
         |> push_navigate(to: ~p"/todos")}

      true ->
        case AssistantChat.get_or_create_todo_thread(user_id, todo.id) do
          {:ok, %{thread: thread}} ->
            socket =
              socket
              |> assign(:current_path, "/todos")
              |> assign(:todo, todo)
              |> assign(:thread, thread)
              |> assign(:polls_left, 0)
              |> assign(:awaiting_reply, active_run?(thread))
              |> assign(:message_form, to_form(%{"body" => ""}, as: :message))

            {:ok, maybe_schedule_poll(socket)}

          {:error, _reason} ->
            {:ok,
             socket
             |> put_flash(:error, "Could not open a chat for that work item.")
             |> push_navigate(to: ~p"/todos")}
        end
    end
  end

  @impl true
  def handle_event("send_message", %{"message" => %{"body" => body}}, socket) do
    body = String.trim(body || "")

    if body == "" do
      {:noreply, socket}
    else
      user_id = socket.assigns.current_user.id

      case AssistantChat.send_message(user_id, socket.assigns.thread.id, %{"body" => body, "client_message_id" => Ecto.UUID.generate()}) do
        {:ok, %{thread: thread}} ->
          {:noreply,
           socket
           |> assign(:thread, thread)
           |> assign(:awaiting_reply, true)
           |> assign(:polls_left, @max_polls)
           |> assign(:message_form, to_form(%{"body" => ""}, as: :message))
           |> maybe_schedule_poll()}

        {:error, :assistant_run_in_progress, _run, thread} ->
          {:noreply,
           socket
           |> assign(:thread, thread)
           |> assign(:awaiting_reply, true)
           |> assign(:polls_left, @max_polls)
           |> maybe_schedule_poll()}

        {:error, _reason} ->
          {:noreply, put_flash(socket, :error, "Could not send that message.")}
      end
    end
  end

  @impl true
  def handle_info(:poll_thread, socket) do
    user_id = socket.assigns.current_user.id

    case AssistantChat.get_thread(user_id, socket.assigns.thread.id) do
      {:ok, thread} ->
        awaiting = active_run?(thread)

        socket =
          socket
          |> assign(:thread, thread)
          |> assign(:awaiting_reply, awaiting)
          |> assign(:polls_left, max(socket.assigns.polls_left - 1, 0))

        {:noreply, maybe_schedule_poll(socket)}

      {:error, _reason} ->
        {:noreply, assign(socket, :awaiting_reply, false)}
    end
  end

  defp maybe_schedule_poll(socket) do
    if socket.assigns.awaiting_reply and socket.assigns.polls_left > 0 do
      Process.send_after(self(), :poll_thread, @poll_ms)
      socket
    else
      socket
    end
  end

  defp active_run?(thread) do
    not is_nil(TelegramConversations.active_run_for_conversation(thread.id))
  end

  defp visible_messages(thread) do
    thread
    |> turns()
    |> Enum.filter(fn turn ->
      turn.role in ["user", "assistant"] and is_binary(turn.text) and
        String.trim(turn.text) != ""
    end)
    |> Enum.sort_by(& &1.inserted_at, {:asc, DateTime})
  end

  defp turns(%{turns: turns}) when is_list(turns), do: turns
  defp turns(thread), do: Maraithon.Repo.preload(thread, :turns).turns || []

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_path={@current_path} current_user={@current_user}>
      <div class="mx-auto flex h-[calc(100vh-10rem)] max-w-3xl flex-col px-4 py-6 sm:px-6">
      <div class="flex items-start justify-between gap-3">
        <div class="min-w-0">
          <p class="text-xs font-semibold uppercase tracking-wide text-zinc-500">Work item chat</p>
          <h1 class="mt-1 truncate text-lg font-semibold text-zinc-900">{@todo.title}</h1>
          <p :if={@todo.next_action} class="mt-0.5 line-clamp-2 text-sm text-zinc-500">
            {@todo.next_action}
          </p>
        </div>
        <.link
          navigate={~p"/todos?todo_id=#{@todo.id}"}
          class="shrink-0 rounded-md px-2 py-1 text-xs font-medium text-zinc-500 hover:bg-zinc-950/5 hover:text-zinc-950"
        >
          Back to work
        </.link>
      </div>

      <div
        id="todo-chat-messages"
        class="mt-4 flex-1 space-y-3 overflow-y-auto rounded-xl border border-zinc-200 bg-white p-4"
        phx-hook=".ScrollToBottom"
      >
        <p :if={visible_messages(@thread) == []} class="py-8 text-center text-sm text-zinc-400">
          Ask anything about this work item — context is already loaded.
        </p>

        <div
          :for={message <- visible_messages(@thread)}
          class={["flex", message.role == "user" && "justify-end"]}
        >
          <div class={[
            "max-w-[85%] whitespace-pre-wrap rounded-2xl px-4 py-2 text-sm leading-6",
            message.role == "user" && "bg-zinc-900 text-white",
            message.role != "user" && "bg-zinc-100 text-zinc-800"
          ]}>
            {message.text}
          </div>
        </div>

        <div :if={@awaiting_reply} class="flex items-center gap-2 text-xs text-zinc-400">
          <span class="inline-block size-2 animate-pulse rounded-full bg-zinc-400"></span>
          Maraithon is working on it…
        </div>

        <script :type={Phoenix.LiveView.ColocatedHook} name=".ScrollToBottom">
          export default {
            mounted() { this.el.scrollTop = this.el.scrollHeight },
            updated() { this.el.scrollTop = this.el.scrollHeight }
          }
        </script>
      </div>

      <.form
        for={@message_form}
        id="todo-chat-form"
        phx-submit="send_message"
        class="mt-3 flex items-end gap-2"
      >
        <textarea
          id="todo-chat-input"
          name="message[body]"
          rows="2"
          placeholder="Message Maraithon about this work item…"
          class="flex-1 resize-none rounded-xl border border-zinc-300 px-3 py-2 text-sm focus:border-zinc-500 focus:outline-none focus:ring-0"
        ><%= Phoenix.HTML.Form.input_value(@message_form, :body) %></textarea>
        <button
          type="submit"
          disabled={@awaiting_reply}
          class="rounded-xl bg-zinc-900 px-4 py-2.5 text-sm font-semibold text-white hover:bg-zinc-700 disabled:opacity-40"
        >
          Send
        </button>
      </.form>
      </div>
    </Layouts.app>
    """
  end
end
