defmodule MaraithonWeb.MemoriesLive do
  use MaraithonWeb, :live_view

  import Ecto.Query

  alias Maraithon.Memory
  alias Maraithon.Memory.{Event, Item}
  alias Maraithon.Repo

  @statuses ~w(active superseded archived rejected all)
  @kinds ~w(all fact preference relevance_feedback instruction relationship project workflow correction system_note)
  @scopes ~w(all user system agent project)
  @default_filters %{"q" => "", "status" => "active", "kind" => "all", "scope" => "all"}

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: "Memory",
       current_path: "/operator/memories",
       filters: @default_filters,
       filter_form: to_form(@default_filters, as: :filters),
       memories: [],
       selected_memory: nil,
       selected_events: [],
       supersession_chain: [],
       statuses: @statuses,
       kinds: @kinds,
       scopes: @scopes
     )}
  end

  @impl true
  def handle_params(params, uri, socket) do
    filters = normalize_filters(params)
    selected_id = normalize_text(Map.get(params, "id"))

    socket =
      socket
      |> assign(:current_path, current_path_from_uri(uri))
      |> assign(:filters, filters)
      |> assign(:filter_form, to_form(filters, as: :filters))
      |> refresh_memories(selected_id)

    {:noreply, socket}
  end

  @impl true
  def handle_event("update_filters", %{"filters" => filters}, socket) do
    {:noreply, push_patch(socket, to: memories_path(normalize_filters(filters)))}
  end

  def handle_event("clear_filters", _params, socket) do
    {:noreply, push_patch(socket, to: memories_path(@default_filters))}
  end

  def handle_event("select_memory", %{"id" => id}, socket) do
    {:noreply, push_patch(socket, to: memories_path(socket.assigns.filters, id))}
  end

  def handle_event("archive_memory", %{"id" => id}, socket) do
    case Memory.forget(current_user_id(socket), id, source: "operator_ui", status: "archived") do
      {:ok, _item} ->
        {:noreply,
         socket
         |> put_flash(:info, "Memory archived")
         |> refresh_memories(nil)}

      {:error, :memory_not_found} ->
        {:noreply,
         socket
         |> put_flash(:error, "Memory not found")
         |> refresh_memories(nil)}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to archive memory: #{inspect(reason)}")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_path={@current_path} current_user={@current_user}>
      <div class="space-y-6">
        <.page_header
          title="Memory"
          subtitle="Durable context Maraithon can recall, update, supersede, and audit."
        />

        <.panel body_class="px-5 py-4">
          <.form
            for={@filter_form}
            id="memory-filters"
            phx-change="update_filters"
            phx-submit="update_filters"
            class="grid gap-4 md:grid-cols-[minmax(16rem,1fr)_10rem_10rem_10rem_auto]"
          >
            <.field label="Search" for={@filter_form[:q].id}>
              <.c_input
                id={@filter_form[:q].id}
                name={@filter_form[:q].name}
                value={@filter_form[:q].value}
                placeholder="Search memories"
              />
            </.field>
            <.field label="Status" for={@filter_form[:status].id}>
              <.c_select
                id={@filter_form[:status].id}
                name={@filter_form[:status].name}
                value={@filter_form[:status].value}
              >
                <option :for={status <- @statuses} value={status}><%= label(status) %></option>
              </.c_select>
            </.field>
            <.field label="Kind" for={@filter_form[:kind].id}>
              <.c_select
                id={@filter_form[:kind].id}
                name={@filter_form[:kind].name}
                value={@filter_form[:kind].value}
              >
                <option :for={kind <- @kinds} value={kind}><%= label(kind) %></option>
              </.c_select>
            </.field>
            <.field label="Scope" for={@filter_form[:scope].id}>
              <.c_select
                id={@filter_form[:scope].id}
                name={@filter_form[:scope].name}
                value={@filter_form[:scope].value}
              >
                <option :for={scope <- @scopes} value={scope}><%= label(scope) %></option>
              </.c_select>
            </.field>
            <div class="flex items-end">
              <.button type="button" variant="outline" phx-click="clear_filters">Reset</.button>
            </div>
          </.form>
        </.panel>

        <.panel body_class="px-5 py-0">
          <:header>
            <div class="flex items-center justify-between gap-3">
              <div>
                <h2 class="text-sm/6 font-semibold text-zinc-950">Durable memories</h2>
                <p class="text-sm/6 text-zinc-500"><%= length(@memories) %> shown</p>
              </div>
            </div>
          </:header>
          <.table>
            <.table_head>
              <.table_row>
                <.table_header>Kind</.table_header>
                <.table_header>Memory</.table_header>
                <.table_header>Source</.table_header>
                <.table_header>Status</.table_header>
                <.table_header class="text-right">Actions</.table_header>
              </.table_row>
            </.table_head>
            <.table_body>
              <.table_row :if={@memories == []}>
                <.table_cell colspan="5" class="py-10 text-center text-sm/6 text-zinc-500">
                  No memories match these filters.
                </.table_cell>
              </.table_row>
              <.table_row
                :for={memory <- @memories}
                id={"memory-#{memory.id}"}
                phx-click="select_memory"
                phx-value-id={memory.id}
                class="cursor-pointer hover:bg-zinc-50"
              >
                <.table_cell>
                  <.badge color={kind_color(memory.kind)}><%= label(memory.kind) %></.badge>
                </.table_cell>
                <.table_cell class="max-w-lg whitespace-normal">
                  <div class="font-medium text-zinc-950"><%= memory.title %></div>
                  <div class="mt-1 line-clamp-2 text-sm/6 text-zinc-500">
                    <%= memory.summary || memory.content %>
                  </div>
                  <div :if={memory.supersedes_id || memory.superseded_by_id} class="mt-2 text-xs/5 text-zinc-500">
                    Supersession chain
                  </div>
                </.table_cell>
                <.table_cell>
                  <div class="text-sm/6 text-zinc-950"><%= memory.source %></div>
                  <div :if={memory.source_ref_type || memory.source_ref_id} class="text-xs/5 text-zinc-500">
                    <%= compact_source_ref(memory) %>
                  </div>
                </.table_cell>
                <.table_cell>
                  <.badge color={status_color(memory.status)}><%= label(memory.status) %></.badge>
                  <div class="mt-1 text-xs/5 text-zinc-500">
                    <%= confidence_label(memory.confidence) %>
                  </div>
                </.table_cell>
                <.table_cell class="text-right">
                  <.button
                    :if={memory.status == "active"}
                    type="button"
                    variant="outline"
                    phx-click="archive_memory"
                    phx-value-id={memory.id}
                  >
                    Archive
                  </.button>
                </.table_cell>
              </.table_row>
            </.table_body>
          </.table>
        </.panel>

        <.panel :if={@selected_memory} id="memory-detail">
          <:header>
            <div class="flex flex-wrap items-start justify-between gap-3">
              <div>
                <h2 class="text-sm/6 font-semibold text-zinc-950"><%= @selected_memory.title %></h2>
                <p class="text-sm/6 text-zinc-500"><%= compact_source_ref(@selected_memory) %></p>
              </div>
              <.badge color={status_color(@selected_memory.status)}>
                <%= label(@selected_memory.status) %>
              </.badge>
            </div>
          </:header>

          <div class="grid gap-6 lg:grid-cols-[minmax(0,1fr)_20rem]">
            <div class="space-y-6">
              <section>
                <h3 class="text-sm/6 font-medium text-zinc-950">Content</h3>
                <p class="mt-2 whitespace-pre-wrap text-sm/6 text-zinc-700"><%= @selected_memory.content %></p>
              </section>

              <section :if={evidence(@selected_memory) != []}>
                <h3 class="text-sm/6 font-medium text-zinc-950">Evidence</h3>
                <ul class="mt-2 divide-y divide-zinc-950/5 rounded-lg border border-zinc-950/10">
                  <li :for={entry <- evidence(@selected_memory)} class="px-3 py-2 text-sm/6">
                    <div class="font-medium text-zinc-950"><%= entry["source"] %></div>
                    <div class="text-zinc-600"><%= entry["quote"] %></div>
                  </li>
                </ul>
              </section>

              <section>
                <h3 class="text-sm/6 font-medium text-zinc-950">Supersession chain</h3>
                <ol class="mt-2 divide-y divide-zinc-950/5 rounded-lg border border-zinc-950/10">
                  <li :for={memory <- @supersession_chain} class="px-3 py-2 text-sm/6">
                    <div class="flex items-center justify-between gap-3">
                      <span class="font-medium text-zinc-950"><%= memory.title %></span>
                      <.badge color={status_color(memory.status)}><%= label(memory.status) %></.badge>
                    </div>
                    <p class="mt-1 text-zinc-600"><%= memory.summary || memory.content %></p>
                  </li>
                </ol>
              </section>
            </div>

            <aside class="space-y-6">
              <section>
                <h3 class="text-sm/6 font-medium text-zinc-950">Provenance</h3>
                <.description_list class="mt-2">
                  <.description_term>Importance</.description_term>
                  <.description_details><%= @selected_memory.importance %></.description_details>
                  <.description_term>Confidence</.description_term>
                  <.description_details><%= confidence_label(@selected_memory.confidence) %></.description_details>
                  <.description_term>Last used</.description_term>
                  <.description_details><%= format_datetime(@selected_memory.last_used_at) %></.description_details>
                  <.description_term>Decay</.description_term>
                  <.description_details><%= format_datetime(@selected_memory.decay_at) %></.description_details>
                </.description_list>
              </section>

              <section>
                <h3 class="text-sm/6 font-medium text-zinc-950">Events</h3>
                <ol class="mt-2 divide-y divide-zinc-950/5 rounded-lg border border-zinc-950/10">
                  <li :for={event <- @selected_events} class="px-3 py-2 text-sm/6">
                    <div class="font-medium text-zinc-950"><%= label(event.event_type) %></div>
                    <div class="text-xs/5 text-zinc-500"><%= format_datetime(event.inserted_at) %></div>
                  </li>
                </ol>
              </section>
            </aside>
          </div>
        </.panel>
      </div>
    </Layouts.app>
    """
  end

  defp refresh_memories(socket, selected_id) do
    user_id = current_user_id(socket)
    filters = socket.assigns.filters

    memories =
      user_id
      |> Memory.list_items(memory_opts(filters))
      |> Enum.sort_by(&{status_rank(&1.status), &1.kind, &1.title})

    selected_memory =
      selected_id && Memory.get_item_for_user(user_id, selected_id)

    selected_memory =
      cond do
        selected_memory -> selected_memory
        memories == [] -> nil
        true -> nil
      end

    chain = supersession_chain(user_id, selected_memory)
    events = memory_events(user_id, chain)

    assign(socket,
      memories: memories,
      selected_memory: selected_memory,
      supersession_chain: chain,
      selected_events: events
    )
  end

  defp memory_opts(filters) do
    [
      limit: 100,
      query: normalize_text(filters["q"]),
      status: normalize_filter(filters["status"]),
      kind: normalize_filter(filters["kind"]),
      scope: normalize_filter(filters["scope"])
    ]
  end

  defp normalize_filters(params) do
    %{
      "q" => normalize_text(Map.get(params, "q")) || "",
      "status" => normalize_choice(Map.get(params, "status"), @statuses, "active"),
      "kind" => normalize_choice(Map.get(params, "kind"), @kinds, "all"),
      "scope" => normalize_choice(Map.get(params, "scope"), @scopes, "all")
    }
  end

  defp normalize_filter("all"), do: nil
  defp normalize_filter(""), do: nil
  defp normalize_filter(value), do: value

  defp memories_path(filters, selected_id \\ nil) do
    query =
      filters
      |> Enum.reject(fn {_key, value} -> value in [nil, "", "all"] end)
      |> Enum.into(%{})
      |> maybe_put("id", selected_id)

    if map_size(query) == 0, do: ~p"/operator/memories", else: ~p"/operator/memories?#{query}"
  end

  defp supersession_chain(_user_id, nil), do: []

  defp supersession_chain(user_id, %Item{} = memory) do
    previous = collect_chain(user_id, memory.supersedes_id, :supersedes_id, [])
    next = collect_chain(user_id, memory.superseded_by_id, :superseded_by_id, [])

    Enum.reverse(previous) ++ [memory] ++ next
  end

  defp collect_chain(_user_id, nil, _field, acc), do: acc
  defp collect_chain(_user_id, _id, _field, acc) when length(acc) >= 10, do: acc

  defp collect_chain(user_id, id, field, acc) do
    case Memory.get_item_for_user(user_id, id) do
      %Item{} = item ->
        next_id = Map.get(item, field)
        collect_chain(user_id, next_id, field, [item | acc])

      nil ->
        acc
    end
  end

  defp memory_events(_user_id, []), do: []

  defp memory_events(user_id, chain) do
    memory_ids = Enum.map(chain, & &1.id)

    Event
    |> where([event], event.user_id == ^user_id and event.memory_id in ^memory_ids)
    |> order_by([event], desc: event.inserted_at)
    |> limit(25)
    |> Repo.all()
  end

  defp evidence(%Item{} = item) do
    case Map.get(item.metadata || %{}, "evidence") do
      evidence when is_list(evidence) -> Enum.filter(evidence, &evidence_entry?/1)
      evidence when is_map(evidence) -> if evidence_entry?(evidence), do: [evidence], else: []
      _other -> []
    end
  end

  defp evidence_entry?(entry) when is_map(entry) do
    is_binary(entry["quote"]) and is_binary(entry["source"])
  end

  defp evidence_entry?(_entry), do: false

  defp status_rank("active"), do: 0
  defp status_rank("superseded"), do: 1
  defp status_rank("archived"), do: 2
  defp status_rank("rejected"), do: 3
  defp status_rank(_status), do: 4

  defp status_color("active"), do: "green"
  defp status_color("superseded"), do: "amber"
  defp status_color("archived"), do: "zinc"
  defp status_color("rejected"), do: "red"
  defp status_color(_status), do: "zinc"

  defp kind_color("preference"), do: "blue"
  defp kind_color("relevance_feedback"), do: "amber"
  defp kind_color("correction"), do: "purple"
  defp kind_color(_kind), do: "zinc"

  defp label(value) when is_binary(value) do
    value
    |> String.replace("_", " ")
    |> String.capitalize()
  end

  defp label(value), do: to_string(value)

  defp compact_source_ref(%Item{} = item) do
    [item.source_ref_type, item.source_ref_id]
    |> Enum.reject(&blank?/1)
    |> Enum.join(":")
    |> case do
      "" -> item.source || "manual"
      value -> value
    end
  end

  defp confidence_label(nil), do: "0%"

  defp confidence_label(value) when is_float(value) or is_integer(value) do
    "#{round(value * 100)}%"
  end

  defp format_datetime(nil), do: "Never"

  defp format_datetime(%DateTime{} = datetime) do
    Calendar.strftime(datetime, "%Y-%m-%d %H:%M UTC")
  end

  defp format_datetime(value), do: to_string(value)

  defp normalize_choice(value, allowed, default) do
    value = normalize_text(value) || default
    if value in allowed, do: value, else: default
  end

  defp normalize_text(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      text -> text
    end
  end

  defp normalize_text(_value), do: nil

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp current_path_from_uri(uri) do
    uri
    |> URI.parse()
    |> Map.get(:path)
    |> case do
      nil -> "/operator/memories"
      "" -> "/operator/memories"
      path -> path
    end
  end

  defp current_user_id(socket), do: socket.assigns.current_user.id

  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(nil), do: true
  defp blank?(_value), do: false
end
