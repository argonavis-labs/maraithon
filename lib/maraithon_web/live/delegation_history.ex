defmodule MaraithonWeb.DelegationHistory do
  use MaraithonWeb, :live_component
  alias Maraithon.Delegations.History
  alias MaraithonWeb.LocalTime

  @impl true
  def mount(socket),
    do:
      {:ok,
       assign(socket,
         open?: false,
         busy?: false,
         history: nil,
         entries: [],
         error: nil,
         before: nil,
         requested_before: nil
       )}

  @impl true
  def update(attrs, socket) do
    {:ok,
     socket
     |> assign(attrs)
     |> assign_new(:timezone, fn -> LocalTime.timezone_info_for_user(attrs.user_id) end)}
  end

  @impl true
  def handle_event("toggle", _, socket) do
    socket = assign(socket, open?: not socket.assigns.open?)

    socket =
      if socket.assigns.open? and is_nil(socket.assigns.history),
        do: load(socket, nil),
        else: socket

    {:noreply, socket}
  end

  def handle_event("refresh", _, socket), do: {:noreply, load(socket, nil)}
  def handle_event("older", _, socket), do: {:noreply, load(socket, socket.assigns.before)}

  defp load(%{assigns: %{busy?: true}} = socket, _), do: socket

  defp load(socket, before) do
    user = socket.assigns.user_id
    id = socket.assigns.delegation_id

    socket
    |> assign(busy?: true, error: nil, requested_before: before)
    |> start_async(:history, fn -> History.fetch(user, id, before) end)
  end

  @impl true
  def handle_async(:history, {:ok, {:ok, history}}, socket) do
    entries =
      if socket.assigns.requested_before,
        do: Enum.uniq_by(socket.assigns.entries ++ history.entries, & &1.id),
        else: history.entries

    {:noreply,
     assign(socket, history: history, entries: entries, before: history.next_before, busy?: false)}
  end

  def handle_async(:history, _, socket),
    do:
      {:noreply,
       assign(socket,
         busy?: false,
         error: "Conversation history couldn't load. Try refreshing it."
       )}

  @impl true
  def render(assigns) do
    ~H"""
    <div id={@id}>
      <.button variant="plain" phx-click="toggle" phx-target={@myself} aria-expanded={@open?}>
        Conversation history
      </.button>
      <div :if={@open?} class="mt-2 space-y-3">
        <div class="flex justify-end">
          <.button variant="plain" phx-click="refresh" phx-target={@myself} disabled={@busy?}>Refresh history</.button>
        </div>
        <div :if={@history} class="space-y-2">
          <p :if={@history.outcome} class="text-sm/6 text-zinc-700">{@history.outcome}</p>
          <.source_links links={@history.evidence} />
          <details :if={@history.facts != []}>
            <summary class="cursor-pointer text-sm/6 font-medium">Saved facts ({length(@history.facts)})</summary>
            <ul class="divide-y divide-zinc-950/10">
              <li :for={fact <- @history.facts} class="space-y-1 py-2">
                <p class="text-sm/6 text-zinc-700">{fact.text}</p>
                <time class="text-xs/5 text-zinc-500" datetime={fact.recorded_at}>{LocalTime.format_datetime(fact.recorded_at, "", @timezone)}</time>
                <.source_links links={fact.links} />
              </li>
            </ul>
          </details>
        </div>
        <ol class="divide-y divide-zinc-950/10" aria-label="Conversation activity, newest first">
          <li :for={entry <- @entries} id={"history-#{entry.id}"} class="space-y-1 py-2">
            <p class="text-sm/6 font-medium text-zinc-950">{entry.title}</p>
            <time class="text-xs/5 text-zinc-500" datetime={entry.occurred_at}>{LocalTime.format_datetime(entry.occurred_at, "", @timezone)}</time>
            <p :if={entry.detail} class="text-sm/6 text-zinc-700">{entry.detail}</p>
            <.source_links links={entry.links} />
          </li>
        </ol>
        <p :if={@history && @entries == []} class="text-sm/6 text-zinc-500">No conversation activity yet.</p>
        <p :if={@busy?} role="status" class="text-sm/6 text-zinc-500">Loading history…</p>
        <p :if={@error} role="alert" class="text-sm/6 text-red-700">{@error}</p>
        <.button :if={@before} variant="plain" phx-click="older" phx-target={@myself} disabled={@busy?}>Older activity</.button>
      </div>
    </div>
    """
  end

  attr :links, :list, required: true

  defp source_links(assigns) do
    ~H"""
    <div :if={@links != []} class="flex flex-wrap gap-x-3 gap-y-1">
      <a :for={link <- @links} href={link.url} target="_blank" rel="noopener noreferrer" class="text-sm/6 text-zinc-600 underline">{link.label}</a>
    </div>
    """
  end
end
