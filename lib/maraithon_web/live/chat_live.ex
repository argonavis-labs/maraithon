defmodule MaraithonWeb.ChatLive do
  use MaraithonWeb, :live_view

  alias Maraithon.AssistantChat
  alias Maraithon.TelegramConversations

  @poll_ms 2_000
  @max_polls 90
  @thread_limit 30

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:current_path, "/chat")
     |> assign(:awaiting_reply, false)
     |> assign(:polls_left, 0)
     |> assign(:message_form, to_form(%{"body" => ""}, as: :message))
     |> refresh_threads()}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, select_thread(socket, params["thread_id"])}
  end

  @impl true
  def handle_event("send_message", %{"message" => %{"body" => body}}, socket) do
    body = String.trim(body || "")

    cond do
      body == "" ->
        {:noreply, socket}

      socket.assigns.thread == nil ->
        start_new_thread(socket, body)

      true ->
        send_to_thread(socket, socket.assigns.thread.id, body)
    end
  end

  @impl true
  def handle_info(:poll_thread, socket) do
    case socket.assigns.thread do
      nil ->
        {:noreply, assign(socket, :awaiting_reply, false)}

      thread ->
        case AssistantChat.get_thread(socket.assigns.current_user.id, thread.id) do
          {:ok, refreshed} ->
            awaiting = active_run?(refreshed)

            socket =
              socket
              |> assign(:thread, refreshed)
              |> assign(:awaiting_reply, awaiting)
              |> assign(:polls_left, max(socket.assigns.polls_left - 1, 0))

            {:noreply, maybe_schedule_poll(socket)}

          {:error, _reason} ->
            {:noreply, assign(socket, :awaiting_reply, false)}
        end
    end
  end

  defp start_new_thread(socket, body) do
    user_id = socket.assigns.current_user.id
    title = body |> String.slice(0, 60) |> String.trim()

    with {:ok, thread} <- AssistantChat.create_thread(user_id, %{"title" => title}),
         {:ok, %{thread: thread}} <-
           AssistantChat.send_message(user_id, thread.id, %{"body" => body, "client_message_id" => Ecto.UUID.generate()}) do
      {:noreply,
       socket
       |> assign(:thread, thread)
       |> assign(:awaiting_reply, true)
       |> assign(:polls_left, @max_polls)
       |> assign(:message_form, to_form(%{"body" => ""}, as: :message))
       |> refresh_threads()
       |> maybe_schedule_poll()
       |> push_patch(to: ~p"/chat/#{thread.id}")}
    else
      _error ->
        {:noreply, put_flash(socket, :error, "Could not start that conversation.")}
    end
  end

  defp send_to_thread(socket, thread_id, body) do
    case AssistantChat.send_message(socket.assigns.current_user.id, thread_id, %{"body" => body, "client_message_id" => Ecto.UUID.generate()}) do
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

  defp refresh_threads(socket) do
    {:ok, threads} =
      AssistantChat.list_threads(socket.assigns.current_user.id, limit: @thread_limit)

    assign(socket, :threads, threads)
  end

  defp select_thread(socket, nil), do: assign(socket, :thread, nil)

  defp select_thread(socket, thread_id) do
    case AssistantChat.get_thread(socket.assigns.current_user.id, thread_id) do
      {:ok, thread} ->
        awaiting = active_run?(thread)

        socket
        |> assign(:thread, thread)
        |> assign(:awaiting_reply, awaiting)
        |> assign(:polls_left, if(awaiting, do: @max_polls, else: 0))
        |> maybe_schedule_poll()

      {:error, _reason} ->
        socket
        |> put_flash(:error, "That conversation could not be found.")
        |> assign(:thread, nil)
    end
  end

  defp maybe_schedule_poll(socket) do
    if connected?(socket) and socket.assigns.awaiting_reply and socket.assigns.polls_left > 0 do
      Process.send_after(self(), :poll_thread, @poll_ms)
    end

    socket
  end

  defp active_run?(thread) do
    not is_nil(TelegramConversations.active_run_for_conversation(thread.id))
  end

  defp visible_messages(nil), do: []

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

  defp thread_label(thread) do
    case thread.metadata do
      %{"title" => title} when is_binary(title) and title != "" -> title
      _other -> "Conversation"
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_path={@current_path} current_user={@current_user}>
      <div class="mx-auto flex h-[calc(100vh-10rem)] max-w-5xl gap-6 px-4 py-6 sm:px-6">
        <aside class="hidden w-64 shrink-0 flex-col md:flex">
          <.link
            patch={~p"/chat"}
            class="rounded-lg bg-zinc-900 px-3 py-2 text-center text-sm font-semibold text-white hover:bg-zinc-700"
          >
            New conversation
          </.link>

          <div class="mt-4 min-h-0 flex-1 space-y-1 overflow-y-auto">
            <.link
              :for={thread <- @threads}
              patch={~p"/chat/#{thread.id}"}
              class={[
                "block truncate rounded-lg px-3 py-2 text-sm",
                @thread && @thread.id == thread.id && "bg-zinc-100 font-medium text-zinc-900",
                !(@thread && @thread.id == thread.id) && "text-zinc-600 hover:bg-zinc-50"
              ]}
            >
              {thread_label(thread)}
            </.link>
          </div>
        </aside>

        <div class="flex min-w-0 flex-1 flex-col">
          <div
            id="chat-messages"
            class="flex-1 space-y-3 overflow-y-auto rounded-xl border border-zinc-200 bg-white p-4"
            phx-hook=".ChatScroll"
          >
            <div :if={@thread == nil} class="flex h-full flex-col items-center justify-center text-center">
              <p class="text-base font-semibold text-zinc-900">Chat with Maraithon</p>
              <p class="mt-1 max-w-sm text-sm text-zinc-500">
                Ask about your day, hand off a task, or work through anything your chief of staff
                has queued up. Conversations sync with the mobile app.
              </p>
            </div>

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

            <script :type={Phoenix.LiveView.ColocatedHook} name=".ChatScroll">
              export default {
                mounted() { this.el.scrollTop = this.el.scrollHeight },
                updated() { this.el.scrollTop = this.el.scrollHeight }
              }
            </script>
          </div>

          <.form
            for={@message_form}
            id="chat-form"
            phx-submit="send_message"
            class="mt-3 flex items-end gap-2"
          >
            <textarea
              id="chat-input"
              name="message[body]"
              rows="2"
              placeholder={
                if @thread,
                  do: "Message Maraithon…",
                  else: "Start a conversation with Maraithon…"
              }
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
      </div>
    </Layouts.app>
    """
  end
end
