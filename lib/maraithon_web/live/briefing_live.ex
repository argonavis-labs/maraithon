defmodule MaraithonWeb.BriefingLive do
  use MaraithonWeb, :live_view

  alias Maraithon.Briefs
  alias Maraithon.Briefs.Digest
  alias Maraithon.Briefs.Markdown
  alias Maraithon.Todos
  alias Maraithon.UserIdentity

  @history_limit 14

  @impl true
  def mount(_params, _session, socket) do
    {:ok, socket |> assign(:current_path, "/briefing") |> assign_identity_onboarding() |> refresh()}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, assign_selected_brief(socket, params["brief_id"])}
  end

  @impl true
  def handle_event("complete_todo", %{"id" => todo_id}, socket) do
    user_id = socket.assigns.current_user.id

    case Todos.mark_done(user_id, todo_id, note: "Completed from the morning briefing.") do
      {:ok, _todo} -> {:noreply, refresh(socket)}
      {:error, _reason} -> {:noreply, put_flash(socket, :error, "Could not complete that item.")}
    end
  end

  def handle_event("dismiss_todo", %{"id" => todo_id}, socket) do
    user_id = socket.assigns.current_user.id

    case Todos.dismiss(user_id, todo_id, note: "Dismissed from the morning briefing.") do
      {:ok, _todo} -> {:noreply, refresh(socket)}
      {:error, _reason} -> {:noreply, put_flash(socket, :error, "Could not dismiss that item.")}
    end
  end

  def handle_event("confirm_identity", %{"identity" => params}, socket) do
    user_id = socket.assigns.current_user.id

    phones =
      (params["phones"] || "")
      |> String.split([",", "\n", ";"], trim: true)
      |> Enum.map(&String.trim/1)

    case UserIdentity.confirm(user_id, %{
           display_name: params["display_name"],
           emails: socket.assigns.identity_prefill.emails,
           phones: phones
         }) do
      {:ok, _profile} ->
        {:noreply,
         socket
         |> assign(:identity_confirmed?, true)
         |> put_flash(:info, "Identity saved. Maraithon now knows which messages are yours.")}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Could not save identity details.")}
    end
  end

  defp assign_identity_onboarding(socket) do
    user_id = socket.assigns.current_user.id
    confirmed? = UserIdentity.confirmed?(user_id)

    socket
    |> assign(:identity_confirmed?, confirmed?)
    |> assign(
      :identity_prefill,
      if(confirmed?, do: %{display_name: nil, emails: [], phones: []}, else: UserIdentity.onboarding_prefill(user_id))
    )
  end

  defp refresh(socket) do
    user_id = socket.assigns.current_user.id

    briefs =
      user_id
      |> Briefs.list_recent_for_user(limit: @history_limit * 2)
      |> Enum.filter(&(&1.cadence == "morning"))
      |> Enum.take(@history_limit)

    socket
    |> assign(:briefs, briefs)
    |> assign(:latest_brief, List.first(briefs))
    |> assign(:selected_brief, socket.assigns[:selected_brief] || List.first(briefs))
    |> assign(:groups, Digest.groups_for_user(user_id))
  end

  defp assign_selected_brief(socket, nil) do
    assign(socket, :selected_brief, socket.assigns[:latest_brief])
  end

  defp assign_selected_brief(socket, brief_id) do
    selected =
      Enum.find(socket.assigns.briefs, &(&1.id == brief_id)) ||
        Briefs.get_for_user(socket.assigns.current_user.id, brief_id) ||
        socket.assigns[:latest_brief]

    assign(socket, :selected_brief, selected)
  end

  defp today?(nil), do: false

  defp today?(brief) do
    case brief.scheduled_for || brief.inserted_at do
      %DateTime{} = at -> DateTime.to_date(at) == Date.utc_today()
      _other -> false
    end
  end

  defp brief_date_label(brief) do
    at = brief.scheduled_for || brief.inserted_at

    case at do
      %DateTime{} = datetime ->
        date = DateTime.to_date(datetime)

        cond do
          date == Date.utc_today() -> "Today"
          date == Date.add(Date.utc_today(), -1) -> "Yesterday"
          true -> Calendar.strftime(date, "%A, %b %-d")
        end

      _other ->
        ""
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_path={@current_path} current_user={@current_user}>
      <div class="mx-auto max-w-3xl px-4 py-8 sm:px-6">
      <section
        :if={not @identity_confirmed?}
        class="mb-8 rounded-xl border border-zinc-200 bg-white p-6"
      >
        <h2 class="text-sm font-semibold text-zinc-900">Confirm who you are</h2>
        <p class="mt-1 text-sm text-zinc-600">
          Maraithon uses this to tell your own messages apart from people contacting you —
          especially in group chats. Connected accounts are filled in; add your phone number.
        </p>

        <form phx-submit="confirm_identity" class="mt-4 space-y-4">
          <div>
            <label for="identity-name" class="block text-xs font-semibold text-zinc-700">Your name</label>
            <input
              id="identity-name"
              type="text"
              name="identity[display_name]"
              value={@identity_prefill.display_name}
              class="mt-1 block w-full rounded-lg border border-zinc-300 px-3 py-2 text-sm"
            />
          </div>

          <div :if={@identity_prefill.emails != []}>
            <span class="block text-xs font-semibold text-zinc-700">Your emails (from connected accounts)</span>
            <div class="mt-1 flex flex-wrap gap-2">
              <span
                :for={email <- @identity_prefill.emails}
                class="rounded-md bg-zinc-100 px-2 py-1 text-xs text-zinc-700"
              >
                {email}
              </span>
            </div>
          </div>

          <div>
            <label for="identity-phones" class="block text-xs font-semibold text-zinc-700">
              Your phone numbers
            </label>
            <input
              id="identity-phones"
              type="text"
              name="identity[phones]"
              value={Enum.join(@identity_prefill.phones, ", ")}
              placeholder="e.g. 416-555-0123, 647-555-0456"
              class="mt-1 block w-full rounded-lg border border-zinc-300 px-3 py-2 text-sm"
            />
            <p class="mt-1 text-xs text-zinc-500">
              Detected from messages you've sent; correct or add as needed.
            </p>
          </div>

          <button
            type="submit"
            class="rounded-lg bg-zinc-900 px-4 py-2 text-sm font-semibold text-white hover:bg-zinc-800"
          >
            Confirm identity
          </button>
        </form>
      </section>

      <div class="flex items-baseline justify-between">
        <div>
          <p class="text-xs font-semibold uppercase tracking-wide text-zinc-500">Morning briefing</p>
          <h1 class="mt-1 text-2xl font-semibold text-zinc-900">
            {if @selected_brief, do: @selected_brief.title, else: "No briefing yet"}
          </h1>
        </div>
        <span :if={@selected_brief} class="text-sm text-zinc-500">
          {brief_date_label(@selected_brief)}
        </span>
      </div>

      <div :if={@selected_brief} class="mt-4 rounded-xl border border-zinc-200 bg-white p-6">
        <p class="text-sm font-medium text-zinc-700">{@selected_brief.summary}</p>
        <div class="mt-4 text-sm leading-6 text-zinc-600">
          {Phoenix.HTML.raw(Markdown.to_html(@selected_brief.body))}
        </div>
      </div>

      <div :if={@selected_brief == nil} class="mt-4 rounded-xl border border-dashed border-zinc-300 bg-white p-8 text-center text-sm text-zinc-500">
        Your first morning briefing will appear here after the next scheduled run.
      </div>

      <p
        :if={@selected_brief != nil and @selected_brief == @latest_brief and not today?(@selected_brief)}
        class="mt-3 text-sm text-zinc-500"
      >
        No briefing yet today — this is your most recent one. The next briefing arrives on the morning schedule.
      </p>

      <div :if={@selected_brief == @latest_brief} class="mt-8 space-y-8">
        <h2 class="text-xs font-semibold uppercase tracking-wide text-zinc-500">
          Your open work right now
        </h2>
        <section :for={group <- @groups}>
          <div class="flex items-center gap-2">
            <h2 class="text-sm font-semibold text-zinc-900">{group.title}</h2>
            <span class="text-xs text-zinc-400">{length(group.entries)}</span>
          </div>

          <ul class="mt-3 divide-y divide-zinc-100 rounded-xl border border-zinc-200 bg-white">
            <li :for={entry <- group.entries} class="flex items-start gap-4 px-4 py-3">
              <div class="min-w-0 flex-1">
                <p class="truncate text-sm font-medium text-zinc-900">{entry.card["headline"]}</p>
                <p class="mt-0.5 line-clamp-2 text-sm text-zinc-600">
                  {entry.card["next_best_action"]}
                </p>
                <p :if={entry.card["draft_preview"]} class="mt-1 line-clamp-2 text-sm italic text-zinc-500">
                  “{entry.card["draft_preview"]}”
                </p>
              </div>
              <div class="flex shrink-0 items-center gap-2 pt-0.5">
                <button
                  phx-click="complete_todo"
                  phx-value-id={entry.todo.id}
                  class="rounded-md border border-zinc-200 px-2.5 py-1 text-xs font-semibold text-zinc-700 hover:bg-zinc-50"
                >
                  Done
                </button>
                <button
                  phx-click="dismiss_todo"
                  phx-value-id={entry.todo.id}
                  class="rounded-md px-2 py-1 text-xs font-medium text-zinc-400 hover:text-zinc-600"
                >
                  Dismiss
                </button>
              </div>
            </li>
          </ul>
        </section>

        <p :if={@groups == []} class="rounded-xl border border-dashed border-zinc-300 bg-white p-6 text-center text-sm text-zinc-500">
          Nothing needs your attention right now. Enjoy the quiet morning.
        </p>
      </div>

      <section :if={length(@briefs) > 1} class="mt-10">
        <h2 class="text-sm font-semibold text-zinc-900">Previous briefings</h2>
        <ul class="mt-3 divide-y divide-zinc-100 rounded-xl border border-zinc-200 bg-white">
          <li :for={brief <- Enum.drop(@briefs, 1)}>
            <.link
              patch={~p"/briefing?brief_id=#{brief.id}"}
              class="flex items-center justify-between px-4 py-3 hover:bg-zinc-50"
            >
              <div class="min-w-0">
                <p class="truncate text-sm font-medium text-zinc-900">{brief.title}</p>
                <p class="truncate text-sm text-zinc-500">{brief.summary}</p>
              </div>
              <span class="ml-4 shrink-0 text-xs text-zinc-400">{brief_date_label(brief)}</span>
            </.link>
          </li>
        </ul>
      </section>
      </div>
    </Layouts.app>
    """
  end
end
