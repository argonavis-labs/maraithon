defmodule MaraithonWeb.BriefingLive do
  use MaraithonWeb, :live_view

  alias Maraithon.Briefs
  alias Maraithon.Briefs.Digest
  alias Maraithon.Briefs.Markdown
  alias Maraithon.Timezones
  alias Maraithon.Todos
  alias Maraithon.UserIdentity
  alias MaraithonWeb.LocalTime

  @history_limit 14

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:current_path, "/briefing")
     |> assign(:page_title, "Daily brief")
     |> assign_identity_onboarding()
     |> refresh()}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, assign_selected_brief(socket, params["brief_id"])}
  end

  @impl true
  def handle_event(event, %{"id" => todo_id}, socket)
      when event in ~w(complete_todo dismiss_todo) do
    user_id = socket.assigns.current_user.id

    {update, note, failure} =
      case event do
        "complete_todo" ->
          {&Todos.mark_done/3, "Completed from the morning briefing.",
           "Could not complete that item."}

        "dismiss_todo" ->
          {&Todos.dismiss/3, "Dismissed from the morning briefing.",
           "Could not dismiss that item."}
      end

    case update.(user_id, todo_id,
           note: note,
           actor_type: "user",
           actor_id: user_id,
           actor_label: "User",
           source: "web_briefing"
         ) do
      {:ok, _todo} -> {:noreply, refresh(socket)}
      {:error, _reason} -> {:noreply, put_flash(socket, :error, failure)}
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
      if(confirmed?,
        do: %{display_name: nil, emails: [], phones: []},
        else: UserIdentity.onboarding_prefill(user_id)
      )
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
    |> assign(:timezone_info, LocalTime.timezone_info_for_user(user_id))
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

  defp today?(brief, timezone_info),
    do: brief_date(brief, timezone_info) == local_date(DateTime.utc_now(), timezone_info)

  defp brief_date(brief, timezone_info),
    do: local_date(brief.scheduled_for || brief.inserted_at, timezone_info)

  defp brief_date_label(brief, timezone_info) do
    case brief_date(brief, timezone_info) do
      %Date{} = date ->
        today = local_date(DateTime.utc_now(), timezone_info)

        cond do
          date == today -> "Today"
          date == Date.add(today, -1) -> "Yesterday"
          true -> Calendar.strftime(date, "%A, %b %-d")
        end

      _other ->
        ""
    end
  end

  defp local_date(%DateTime{} = datetime, timezone_info) do
    offset = Timezones.offset_at(timezone_info.name, datetime, timezone_info.offset_hours)
    datetime |> DateTime.add(offset, :hour) |> DateTime.to_date()
  end

  defp local_date(_, _), do: nil

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_path={@current_path} current_user={@current_user}>
      <div class="mx-auto max-w-3xl px-4 py-8 sm:px-6">
      <.page_header title="Daily brief" subtitle="Your priorities, prepared for the day ahead." class="mb-6">
        <:actions>
          <.button :if={@selected_brief && @latest_brief && @selected_brief.id != @latest_brief.id}
            patch={~p"/briefing"} variant="outline">Latest brief</.button>
        </:actions>
      </.page_header>
      <section
        :if={not @identity_confirmed?}
        class="mb-8 rounded-xl border border-zinc-200 bg-white p-6"
      >
        <h2 class="text-sm font-semibold text-zinc-900">Confirm who you are</h2>
        <p class="mt-1 text-sm text-zinc-600">
          Maraithon uses this to tell your own messages apart from people contacting you,
          especially in group chats. Connected accounts are filled in; add your phone number.
        </p>

        <form phx-submit="confirm_identity" class="mt-4 space-y-4">
          <div>
            <label for="identity-name" class="block text-xs font-semibold text-zinc-700">Your name</label>
            <.c_input
              id="identity-name"
              type="text"
              name="identity[display_name]"
              value={@identity_prefill.display_name}
              class="mt-1"
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
            <.c_input
              id="identity-phones"
              type="text"
              name="identity[phones]"
              value={Enum.join(@identity_prefill.phones, ", ")}
              placeholder="e.g. 416-555-0123, 647-555-0456"
              class="mt-1"
            />
            <p class="mt-1 text-xs text-zinc-500">
              Detected from messages you've sent; correct or add as needed.
            </p>
          </div>

          <.button type="submit" phx-disable-with="Saving…">
            Confirm identity
          </.button>
        </form>
      </section>

      <div class="flex flex-wrap items-baseline justify-between gap-3">
        <div>
          <p class="text-xs font-semibold uppercase tracking-wide text-zinc-500">Morning briefing</p>
          <h2 class="mt-1 text-xl font-semibold text-zinc-900">
            {if @selected_brief, do: @selected_brief.title, else: "No briefing yet"}
          </h2>
        </div>
        <span :if={@selected_brief} class="text-sm text-zinc-500">
          {brief_date_label(@selected_brief, @timezone_info)}
        </span>
      </div>

      <div :if={@selected_brief} class="mt-4 rounded-xl border border-zinc-200 bg-white p-6">
        <p class="text-sm font-medium text-zinc-700">{@selected_brief.summary}</p>
        <div class="runner-brief-body mt-4 text-sm leading-6 text-zinc-600">
          {Phoenix.HTML.raw(Markdown.to_html(@selected_brief.body))}
        </div>
      </div>

      <div :if={@selected_brief == nil} class="mt-4 rounded-xl border border-dashed border-zinc-300 bg-white p-8 text-center text-sm text-zinc-500">
        Your first morning briefing will appear here after the next scheduled run.
      </div>

      <p
        :if={@selected_brief != nil and @selected_brief == @latest_brief and not today?(@selected_brief, @timezone_info)}
        class="mt-3 text-sm text-zinc-500"
      >
        No briefing yet today. This is your most recent one. The next briefing arrives on the morning schedule.
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
            <li :for={entry <- group.entries} class="flex flex-col items-start gap-3 px-4 py-3 sm:flex-row sm:gap-4">
              <div class="min-w-0 flex-1">
                <.link navigate={~p"/todos/#{entry.todo.id}"} class="task-title-link block break-words text-sm">
                  {entry.card["headline"]}
                </.link>
                <p class="mt-0.5 line-clamp-2 text-sm text-zinc-600">
                  {entry.card["next_best_action"]}
                </p>
                <p :if={entry.card["draft_preview"]} class="mt-1 line-clamp-2 text-sm italic text-zinc-500">
                  “{entry.card["draft_preview"]}”
                </p>
              </div>
              <div class="flex shrink-0 items-center gap-2 self-end pt-0.5 sm:self-start">
                <.button
                  phx-click="complete_todo"
                  phx-value-id={entry.todo.id}
                  variant="outline"
                  aria-label={"Mark #{entry.card["headline"]} done"}
                  phx-disable-with="Saving…"
                >
                  Done
                </.button>
                <.button
                  phx-click="dismiss_todo"
                  phx-value-id={entry.todo.id}
                  variant="plain"
                  aria-label={"Dismiss #{entry.card["headline"]}"}
                  phx-disable-with="Saving…"
                >
                  Dismiss
                </.button>
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
              <span class="ml-4 shrink-0 text-xs text-zinc-400">{brief_date_label(brief, @timezone_info)}</span>
            </.link>
          </li>
        </ul>
      </section>
      </div>
    </Layouts.app>
    """
  end
end
