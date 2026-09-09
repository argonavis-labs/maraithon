defmodule MaraithonWeb.ChatLive do
  use MaraithonWeb, :live_view

  alias MaraithonWeb.{AssistantProgress, RunnerConversationComponents}
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
     |> assign(:stream_preview, nil)
     |> assign(:progress_thread_id, nil)
     |> assign(:awaiting_reply, false)
     |> assign(:reply_failed, false)
     |> assign(:polls_left, 0)
     |> assign(:message_form, to_form(%{"body" => ""}, as: :message))
     |> refresh_threads()}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, socket |> select_thread(params["thread_id"]) |> subscribe_progress()}
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
            socket =
              socket
              |> assign_reply_state(refreshed)
              |> assign(:polls_left, max(socket.assigns.polls_left - 1, 0))

            {:noreply, maybe_schedule_poll(socket)}

          {:error, _reason} ->
            {:noreply, assign(socket, :awaiting_reply, false)}
        end
    end
  end

  @impl true
  def handle_info({:assistant_preview, thread_id, preview}, socket) do
    if socket.assigns.thread && socket.assigns.thread.id == thread_id do
      {:noreply, assign(socket, :stream_preview, preview)}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:assistant_progress, thread_id}, socket) do
    if socket.assigns.thread && socket.assigns.thread.id == thread_id &&
         (not socket.assigns.awaiting_reply || socket.assigns.polls_left == 0) do
      handle_info(:poll_thread, assign(socket, :polls_left, @max_polls))
    else
      {:noreply, socket}
    end
  end

  defp subscribe_progress(socket) do
    thread_id = socket.assigns.thread && socket.assigns.thread.id
    previous = socket.assigns.progress_thread_id

    if connected?(socket) && thread_id != previous do
      if previous,
        do: Maraithon.AssistantChat.Progress.unsubscribe(socket.assigns.current_user.id, previous)

      if thread_id,
        do: Maraithon.AssistantChat.Progress.subscribe(socket.assigns.current_user.id, thread_id)

      socket |> assign(:progress_thread_id, thread_id) |> assign(:stream_preview, nil)
    else
      socket
    end
  end

  defp start_new_thread(socket, body) do
    user_id = socket.assigns.current_user.id
    title = body |> String.slice(0, 60) |> String.trim()

    with {:ok, thread} <- AssistantChat.create_thread(user_id, %{"title" => title}),
         {:ok, %{thread: thread}} <-
           AssistantChat.send_message(user_id, thread.id, %{
             "body" => body,
             "client_message_id" => Ecto.UUID.generate()
           }) do
      {:noreply,
       socket
       |> put_thread(thread)
       |> assign(:awaiting_reply, true)
       |> assign(:reply_failed, false)
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
    case AssistantChat.send_message(socket.assigns.current_user.id, thread_id, %{
           "body" => body,
           "client_message_id" => Ecto.UUID.generate()
         }) do
      {:ok, %{thread: thread}} ->
        {:noreply,
         socket
         |> put_thread(thread)
         |> assign(:awaiting_reply, true)
         |> assign(:reply_failed, false)
         |> assign(:polls_left, @max_polls)
         |> assign(:message_form, to_form(%{"body" => ""}, as: :message))
         |> maybe_schedule_poll()}

      {:error, :assistant_run_in_progress, _run, thread} ->
        {:noreply,
         socket
         |> put_thread(thread)
         |> assign(:awaiting_reply, true)
         |> assign(:reply_failed, false)
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

  defp select_thread(socket, nil) do
    socket
    |> put_thread(nil)
    |> assign(:awaiting_reply, false)
    |> assign(:reply_failed, false)
    |> assign(:polls_left, 0)
  end

  defp select_thread(socket, thread_id) do
    case AssistantChat.get_thread(socket.assigns.current_user.id, thread_id) do
      {:ok, thread} ->
        socket = assign_reply_state(socket, thread)

        socket
        |> assign(:polls_left, if(socket.assigns.awaiting_reply, do: @max_polls, else: 0))
        |> maybe_schedule_poll()

      {:error, _reason} ->
        socket
        |> put_flash(:error, "That conversation could not be found.")
        |> put_thread(nil)
    end
  end

  defp maybe_schedule_poll(socket) do
    socket = subscribe_progress(socket)

    if connected?(socket) and socket.assigns.awaiting_reply and socket.assigns.polls_left > 0 do
      Process.send_after(self(), :poll_thread, @poll_ms)
    end

    socket
  end

  defp assign_reply_state(socket, thread) do
    run = TelegramConversations.latest_run_for_conversation(thread.id)
    status = if run, do: run.status

    socket
    |> put_thread(thread)
    |> assign(:awaiting_reply, status in ["queued", "running", "waiting_confirmation"])
    |> assign(:reply_failed, status in ["failed", "degraded"])
  end

  # Project durable snapshots once. Stream events only overlay their text;
  # they must not re-query or decrypt the conversation for every fragment.
  defp put_thread(socket, thread) do
    conversation = if thread, do: AssistantProgress.project(thread).thread
    assign(socket, thread: thread, conversation: conversation)
  end

  defp thread_label(thread) do
    case thread.metadata do
      %{"title" => title} when is_binary(title) and title != "" -> title
      _other -> "Conversation"
    end
  end

  @impl true
  def render(assigns) do
    conversation =
      if assigns.conversation && assigns.stream_preview,
        do: AssistantProgress.apply_preview(assigns.conversation, assigns.stream_preview),
        else: assigns.conversation

    messages = if conversation, do: conversation.messages, else: []

    assigns =
      assigns
      |> assign(
        :messages,
        Enum.filter(
          messages,
          &(&1.role in ~w(user assistant) &&
              (&1.body not in [nil, ""] ||
                 get_in(&1, [:work_summary, "tool_calls"]) not in [nil, []]))
        )
      )
      |> assign(:active_run, conversation && conversation.pending_run)

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
            class="min-h-0 flex-1 space-y-6 overflow-y-auto p-4"
            role="log" aria-label="Conversation" tabindex="0"
            data-last-message={List.last(@messages) && List.last(@messages).id}
            phx-hook="RunnerConversation"
          >
            <div :if={@thread == nil} class="flex h-full flex-col items-center justify-center text-center">
              <p class="text-base font-semibold text-zinc-900">Chat with Maraithon</p>
              <p class="mt-1 max-w-sm text-sm text-zinc-500">
                Ask about your day, hand off a task, or work through anything your chief of staff
                has queued up. Conversations sync with the mobile app.
              </p>
            </div>

            <article :for={message <- @messages} id={"chat-message-#{message.id}"}>
              <RunnerConversationComponents.turn message={message} />
            </article>
            <RunnerConversationComponents.run
              :if={@active_run && @active_run.status in ~w(queued running)} run={@active_run} />
            <p :if={@active_run && @active_run.status == "waiting_confirmation"}
              role="status" class="text-sm text-zinc-500">Waiting for your review.</p>

            <.alert :if={@reply_failed} color="red" title="Maraithon couldn’t finish this reply.">
              Your message is saved. Send a new message to try again.
            </.alert>
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
