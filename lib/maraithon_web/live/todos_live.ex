defmodule MaraithonWeb.TodosLive do
  use MaraithonWeb, :live_view

  alias Maraithon.Todos
  alias Maraithon.Todos.Todo

  @page_limit 200
  @default_filters %{
    "q" => "",
    "status" => "active",
    "attention" => "all",
    "due" => "all",
    "source" => "all",
    "sort" => "rank",
    "dir" => "desc"
  }
  @status_options [
    {"Active", "active"},
    {"Open", "open"},
    {"Snoozed", "snoozed"},
    {"Done", "done"},
    {"Dismissed", "dismissed"},
    {"All", "all"}
  ]
  @attention_options [
    {"All modes", "all"},
    {"Needs action", "act_now"},
    {"Watching", "monitor"}
  ]
  @due_options [
    {"Any due date", "all"},
    {"Overdue", "overdue"},
    {"Due today", "today"},
    {"Next 7 days", "week"},
    {"No due date", "no_due"}
  ]
  @source_options [
    {"All sources", "all"},
    {"Gmail", "gmail"},
    {"Google Calendar", "calendar"},
    {"Slack", "slack"},
    {"Telegram", "telegram"},
    {"GitHub", "github"},
    {"Manual", "manual"}
  ]

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: "Todos",
       current_path: "/todos",
       filters: @default_filters,
       filter_form: to_form(@default_filters, as: :filters),
       status_options: @status_options,
       attention_options: @attention_options,
       due_options: @due_options,
       source_options: @source_options,
       todos: [],
       total_count: 0,
       selected_todo_ids: MapSet.new(),
       selected_todo_id: nil,
       selected_todo: nil
     )}
  end

  @impl true
  def handle_params(params, uri, socket) do
    filters = normalize_filters(params)
    selected_todo_id = normalize_text(Map.get(params, "todo_id"))

    socket =
      socket
      |> assign(:current_path, current_path_from_uri(uri))
      |> assign(:filters, filters)
      |> assign(:filter_form, to_form(filters, as: :filters))
      |> assign(:selected_todo_id, selected_todo_id)
      |> refresh_todos()

    {:noreply, socket}
  end

  @impl true
  def handle_event("update_filters", %{"filters" => filters}, socket) do
    {:noreply, push_patch(socket, to: todos_path(normalize_filters(filters)))}
  end

  def handle_event("clear_filters", _params, socket) do
    {:noreply, push_patch(socket, to: ~p"/todos")}
  end

  def handle_event("toggle_todo_selection", %{"id" => todo_id}, socket) do
    selected_todo_ids =
      if visible_todo_id?(socket, todo_id) do
        toggle_mapset_member(socket.assigns.selected_todo_ids, todo_id)
      else
        socket.assigns.selected_todo_ids
      end

    {:noreply, assign(socket, :selected_todo_ids, selected_todo_ids)}
  end

  def handle_event("toggle_all_todos", _params, socket) do
    visible_ids = visible_todo_ids(socket)

    selected_todo_ids =
      if all_visible_todos_selected?(socket.assigns.todos, socket.assigns.selected_todo_ids) do
        MapSet.difference(socket.assigns.selected_todo_ids, visible_ids)
      else
        MapSet.union(socket.assigns.selected_todo_ids, visible_ids)
      end

    {:noreply, assign(socket, :selected_todo_ids, selected_todo_ids)}
  end

  def handle_event("clear_todo_selection", _params, socket) do
    {:noreply, assign(socket, :selected_todo_ids, MapSet.new())}
  end

  def handle_event("complete_selected_todos", _params, socket) do
    {:noreply, apply_bulk_todo_action(socket, :complete)}
  end

  def handle_event("dismiss_selected_todos", _params, socket) do
    {:noreply, apply_bulk_todo_action(socket, :dismiss)}
  end

  def handle_event("complete_todo", %{"id" => todo_id}, socket) do
    case Todos.mark_done(current_user_id(socket), todo_id, note: "Completed from Todos page.") do
      {:ok, _todo} ->
        {:noreply,
         socket
         |> refresh_todos()
         |> put_flash(:info, "Marked todo done.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to complete todo: #{inspect(reason)}")}
    end
  end

  def handle_event("dismiss_todo", %{"id" => todo_id}, socket) do
    case Todos.dismiss(current_user_id(socket), todo_id, note: "Dismissed from Todos page.") do
      {:ok, _todo} ->
        {:noreply,
         socket
         |> refresh_todos()
         |> put_flash(:info, "Dismissed todo.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to dismiss todo: #{inspect(reason)}")}
    end
  end

  def handle_event("open_todo_detail", %{"id" => todo_id}, socket) do
    if visible_todo_id?(socket, todo_id) do
      {:noreply,
       push_patch(socket, to: todos_path(socket.assigns.filters, %{"todo_id" => todo_id}))}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_path={@current_path} current_user={@current_user}>
      <div class="space-y-6">
        <.page_header
          title="Todos"
          subtitle="A fast command surface for triaging open obligations, stale follow-ups, personal tasks, and completed work."
        >
          <:actions>
            <.button navigate="/dashboard" variant="outline">Dashboard</.button>
          </:actions>
        </.page_header>

        <.panel body_class="px-5 py-4">
          <.form
            for={@filter_form}
            id="todo-filters"
            phx-change="update_filters"
            phx-submit="update_filters"
            class="grid gap-4 md:grid-cols-2 xl:grid-cols-[minmax(16rem,1.5fr)_repeat(4,minmax(9rem,1fr))_auto]"
          >
            <.field label="Search" for={@filter_form[:q].id}>
              <.c_input
                id={@filter_form[:q].id}
                name={@filter_form[:q].name}
                value={@filter_form[:q].value}
                placeholder="Search title, next action, person, account, source"
                phx-debounce="250"
              />
            </.field>

            <.field label="Status" for={@filter_form[:status].id}>
              <.c_select id={@filter_form[:status].id} name={@filter_form[:status].name}>
                <option :for={{label, value} <- @status_options} value={value} selected={@filters["status"] == value}>
                  <%= label %>
                </option>
              </.c_select>
            </.field>

            <.field label="Mode" for={@filter_form[:attention].id}>
              <.c_select id={@filter_form[:attention].id} name={@filter_form[:attention].name}>
                <option :for={{label, value} <- @attention_options} value={value} selected={@filters["attention"] == value}>
                  <%= label %>
                </option>
              </.c_select>
            </.field>

            <.field label="Due" for={@filter_form[:due].id}>
              <.c_select id={@filter_form[:due].id} name={@filter_form[:due].name}>
                <option :for={{label, value} <- @due_options} value={value} selected={@filters["due"] == value}>
                  <%= label %>
                </option>
              </.c_select>
            </.field>

            <.field label="Source" for={@filter_form[:source].id}>
              <.c_select id={@filter_form[:source].id} name={@filter_form[:source].name}>
                <option :for={{label, value} <- @source_options} value={value} selected={@filters["source"] == value}>
                  <%= label %>
                </option>
              </.c_select>
            </.field>

            <div class="flex items-end">
              <.button type="button" variant="outline" phx-click="clear_filters">Reset</.button>
            </div>
          </.form>
        </.panel>

        <.panel body_class="px-5 py-0">
          <:header>
            <div class="flex flex-wrap items-center justify-between gap-3">
              <div>
                <h2 class="text-sm/6 font-semibold text-zinc-950">Todo list</h2>
                <p class="text-sm/6 text-zinc-500">
                  <%= result_count_label(@todos, @total_count) %>
                </p>
              </div>
              <.badge color="zinc"><%= active_filter_label(@filters) %></.badge>
            </div>
          </:header>

          <div class={["grid grid-cols-1 gap-4 py-4", @selected_todo && "xl:grid-cols-[minmax(0,1fr)_26rem]"]}>
            <div class="min-w-0">
              <.todo_bulk_toolbar selected_todo_ids={@selected_todo_ids} />

              <.table>
                <.table_head>
                  <.table_row>
                    <.table_header class="w-10">
                      <input
                        type="checkbox"
                        aria-label="Select all todos"
                        checked={all_visible_todos_selected?(@todos, @selected_todo_ids)}
                        phx-click="toggle_all_todos"
                        class="size-4 rounded border-zinc-300 text-zinc-900 focus:ring-zinc-900"
                      />
                    </.table_header>
                    <.sortable_table_header filters={@filters} field="title" class="min-w-[22rem]">
                      Todo
                    </.sortable_table_header>
                    <.sortable_table_header filters={@filters} field="source">Source</.sortable_table_header>
                    <.sortable_table_header filters={@filters} field="status">Status</.sortable_table_header>
                    <.sortable_table_header filters={@filters} field="attention">Mode</.sortable_table_header>
                    <.sortable_table_header filters={@filters} field="priority">Priority</.sortable_table_header>
                    <.sortable_table_header filters={@filters} field="due">Due</.sortable_table_header>
                    <.sortable_table_header filters={@filters} field="updated">Updated</.sortable_table_header>
                    <.table_header class="w-36 text-right">Actions</.table_header>
                  </.table_row>
                </.table_head>
                <.table_body>
                  <.table_row :if={@todos == []}>
                    <.table_cell colspan="9" class="py-10 text-center text-sm/6 text-zinc-500">
                      <%= empty_message(@filters) %>
                    </.table_cell>
                  </.table_row>

                  <.table_row
                    :for={todo <- @todos}
                    id={"todo-#{todo.id}"}
                    phx-click="open_todo_detail"
                    phx-value-id={todo.id}
                    class={todo_row_class(todo, @selected_todo_ids, @selected_todo_id)}
                  >
                    <.table_cell class="w-10 align-top">
                      <input
                        type="checkbox"
                        aria-label={"Select #{todo.title}"}
                        checked={MapSet.member?(@selected_todo_ids, todo.id)}
                        phx-click="toggle_todo_selection"
                        phx-value-id={todo.id}
                        onclick="event.stopPropagation()"
                        class="size-4 rounded border-zinc-300 text-zinc-900 focus:ring-zinc-900"
                      />
                    </.table_cell>
                    <.table_cell class="max-w-xl whitespace-normal align-top">
                      <div class="font-medium text-zinc-950"><%= todo.title %></div>
                      <div :if={present?(todo.summary)} class="mt-1 line-clamp-2 text-sm/6 text-zinc-600">
                        <%= todo.summary %>
                      </div>
                      <div :if={present?(todo.next_action)} class="mt-1 line-clamp-2 text-sm/6 text-zinc-700">
                        <span class="font-medium text-zinc-950">Next:</span> <%= todo.next_action %>
                      </div>
                    </.table_cell>
                    <.table_cell class="whitespace-normal align-top">
                      <div class="text-sm/6 font-medium text-zinc-950"><%= todo_source_label(todo.source) %></div>
                      <div :if={todo_source_account_value(todo)} class="mt-1 text-xs/5 text-zinc-500">
                        <%= todo_source_account_value(todo) %>
                      </div>
                    </.table_cell>
                    <.table_cell class="align-top">
                      <.badge color={status_color(todo.status)}><%= todo_status_label(todo.status) %></.badge>
                    </.table_cell>
                    <.table_cell class="align-top">
                      <.badge color={attention_color(todo.attention_mode)}>
                        <%= attention_mode_label(todo.attention_mode) %>
                      </.badge>
                    </.table_cell>
                    <.table_cell class="align-top text-sm/6 text-zinc-700"><%= todo.priority %></.table_cell>
                    <.table_cell class="whitespace-normal align-top text-xs/5 text-zinc-500">
                      <%= format_datetime(todo.due_at, "No due date") %>
                    </.table_cell>
                    <.table_cell class="whitespace-normal align-top text-xs/5 text-zinc-500">
                      <%= format_datetime(todo.updated_at, "Never") %>
                    </.table_cell>
                    <.table_cell class="align-top text-right">
                      <div class="flex shrink-0 items-center justify-end gap-1">
                        <.button
                          type="button"
                          phx-click="complete_todo"
                          phx-value-id={todo.id}
                          onclick="event.stopPropagation()"
                          variant="plain"
                          class="text-xs text-zinc-500 hover:text-zinc-950"
                        >
                          Done
                        </.button>
                        <.button
                          type="button"
                          phx-click="dismiss_todo"
                          phx-value-id={todo.id}
                          onclick="event.stopPropagation()"
                          variant="plain"
                          class="text-xs text-zinc-500 hover:text-zinc-950"
                        >
                          Dismiss
                        </.button>
                      </div>
                    </.table_cell>
                  </.table_row>
                </.table_body>
              </.table>
            </div>

            <.todo_detail_panel :if={@selected_todo} todo={@selected_todo} filters={@filters} />
          </div>
        </.panel>
      </div>
    </Layouts.app>
    """
  end

  defp refresh_todos(socket) do
    user_id = current_user_id(socket)
    query_opts = todo_query_opts(socket.assigns.filters)
    todos = Todos.list_for_user(user_id, query_opts)
    total_count = Todos.count_for_user(user_id, Keyword.drop(query_opts, [:limit]))
    visible_ids = todos |> Enum.map(& &1.id) |> MapSet.new()
    selected_todo_ids = MapSet.intersection(socket.assigns.selected_todo_ids, visible_ids)
    selected_todo = selected_visible_todo(user_id, socket.assigns.selected_todo_id, visible_ids)

    assign(socket,
      todos: todos,
      total_count: total_count || 0,
      selected_todo_ids: selected_todo_ids,
      selected_todo_id: selected_todo && selected_todo.id,
      selected_todo: selected_todo
    )
  end

  attr :selected_todo_ids, :any, required: true

  defp todo_bulk_toolbar(assigns) do
    assigns = assign(assigns, :selected_count, MapSet.size(assigns.selected_todo_ids))

    ~H"""
    <div
      :if={@selected_count > 0}
      id="todo-bulk-actions"
      class="mb-3 flex flex-wrap items-center justify-between gap-3 rounded-lg border border-zinc-950/10 bg-zinc-50 px-3 py-2"
    >
      <div>
        <p class="text-sm/6 font-medium text-zinc-950"><%= @selected_count %> selected</p>
        <p class="text-xs/5 text-zinc-500">Apply an action to the visible selected todos.</p>
      </div>
      <div class="flex flex-wrap items-center gap-1">
        <.button type="button" phx-click="complete_selected_todos" variant="plain" class="text-xs text-zinc-600">
          Mark done
        </.button>
        <.button type="button" phx-click="dismiss_selected_todos" variant="plain" class="text-xs text-zinc-600">
          Dismiss
        </.button>
        <.button type="button" phx-click="clear_todo_selection" variant="plain" class="text-xs text-zinc-500">
          Clear
        </.button>
      </div>
    </div>
    """
  end

  attr :filters, :map, required: true
  attr :field, :string, required: true
  attr :class, :string, default: nil
  slot :inner_block, required: true

  defp sortable_table_header(assigns) do
    assigns =
      assigns
      |> assign(:next_dir, next_sort_dir(assigns.filters, assigns.field))
      |> assign(:indicator, sort_indicator(assigns.filters, assigns.field))

    ~H"""
    <.table_header class={@class}>
      <.link
        patch={todos_path(@filters, %{"sort" => @field, "dir" => @next_dir})}
        class="inline-flex items-center gap-1 text-zinc-500 hover:text-zinc-950"
      >
        <%= render_slot(@inner_block) %>
        <span :if={@indicator != ""} class="text-[10px]/4 text-zinc-400"><%= @indicator %></span>
      </.link>
    </.table_header>
    """
  end

  attr :todo, :any, required: true
  attr :filters, :map, required: true

  defp todo_detail_panel(assigns) do
    ~H"""
    <aside id="todo-detail" class="rounded-lg border border-zinc-950/10 bg-white px-4 py-4 shadow-sm">
      <div class="flex items-start justify-between gap-3">
        <div class="min-w-0">
          <div class="flex flex-wrap items-center gap-2">
            <.badge color={status_color(@todo.status)}><%= todo_status_label(@todo.status) %></.badge>
            <.badge color={attention_color(@todo.attention_mode)}>
              <%= attention_mode_label(@todo.attention_mode) %>
            </.badge>
            <span class="text-xs/5 text-zinc-500">priority <%= @todo.priority %></span>
          </div>
          <h3 class="mt-2 text-base/7 font-semibold text-zinc-950"><%= @todo.title %></h3>
        </div>
        <.link
          patch={todos_path(@filters)}
          class="rounded-md px-2 py-1 text-xs/5 font-medium text-zinc-500 hover:bg-zinc-950/5 hover:text-zinc-950"
        >
          Close
        </.link>
      </div>

      <dl class="mt-4 divide-y divide-zinc-950/5">
        <div :for={field <- todo_detail_fields(@todo)} class="grid grid-cols-1 gap-1 py-3">
          <dt class="text-xs/5 font-medium text-zinc-500"><%= field.label %></dt>
          <dd class="break-words text-sm/6 text-zinc-700"><%= field.value %></dd>
        </div>
      </dl>

      <div :if={todo_metadata_pairs(@todo) != []} class="mt-4 border-t border-zinc-950/10 pt-4">
        <p class="text-xs/5 font-medium text-zinc-500">Source metadata</p>
        <dl class="mt-2 space-y-2">
          <div :for={field <- todo_metadata_pairs(@todo)} class="grid grid-cols-[7rem_minmax(0,1fr)] gap-2">
            <dt class="text-xs/5 text-zinc-500"><%= field.label %></dt>
            <dd class="break-words text-xs/5 text-zinc-700"><%= field.value %></dd>
          </div>
        </dl>
      </div>
    </aside>
    """
  end

  defp apply_bulk_todo_action(socket, action) do
    todo_ids = selected_visible_todo_ids(socket)

    if todo_ids == [] do
      put_flash(socket, :error, "Select at least one todo first.")
    else
      {updated_count, errors} =
        Enum.reduce(todo_ids, {0, []}, fn todo_id, {count, errors} ->
          case run_todo_action(action, current_user_id(socket), todo_id, bulk_todo_note(action)) do
            {:ok, _todo} -> {count + 1, errors}
            {:error, reason} -> {count, [{todo_id, reason} | errors]}
          end
        end)

      socket =
        socket
        |> assign(:selected_todo_ids, MapSet.new())
        |> refresh_todos()

      put_flash(
        socket,
        bulk_todo_flash_kind(updated_count, errors),
        bulk_todo_flash(action, updated_count, errors)
      )
    end
  end

  defp run_todo_action(:complete, user_id, todo_id, note),
    do: Todos.mark_done(user_id, todo_id, note: note)

  defp run_todo_action(:dismiss, user_id, todo_id, note),
    do: Todos.dismiss(user_id, todo_id, note: note)

  defp bulk_todo_note(:complete), do: "Completed from Todos bulk action."
  defp bulk_todo_note(:dismiss), do: "Dismissed from Todos bulk action."

  defp bulk_todo_flash_kind(0, [_ | _]), do: :error
  defp bulk_todo_flash_kind(_updated_count, _errors), do: :info

  defp bulk_todo_flash(action, updated_count, errors) do
    base =
      case action do
        :complete -> "Marked #{pluralize_todo(updated_count)} done"
        :dismiss -> "Dismissed #{pluralize_todo(updated_count)}"
      end

    case length(errors) do
      0 -> base
      error_count -> "#{base}; #{error_count} could not be updated"
    end
  end

  defp pluralize_todo(1), do: "1 todo"
  defp pluralize_todo(count), do: "#{count} todos"

  defp selected_visible_todo_ids(socket) do
    socket.assigns.selected_todo_ids
    |> MapSet.intersection(visible_todo_ids(socket))
    |> MapSet.to_list()
  end

  defp visible_todo_id?(socket, todo_id) when is_binary(todo_id) do
    MapSet.member?(visible_todo_ids(socket), todo_id)
  end

  defp visible_todo_id?(_socket, _todo_id), do: false

  defp visible_todo_ids(socket) do
    socket.assigns.todos
    |> Enum.map(& &1.id)
    |> MapSet.new()
  end

  defp all_visible_todos_selected?([], _selected_todo_ids), do: false

  defp all_visible_todos_selected?(todos, selected_todo_ids) when is_list(todos) do
    visible_ids = todos |> Enum.map(& &1.id) |> MapSet.new()
    MapSet.subset?(visible_ids, selected_todo_ids)
  end

  defp all_visible_todos_selected?(_todos, _selected_todo_ids), do: false

  defp toggle_mapset_member(mapset, value) do
    if MapSet.member?(mapset, value) do
      MapSet.delete(mapset, value)
    else
      MapSet.put(mapset, value)
    end
  end

  defp selected_visible_todo(_user_id, nil, _visible_ids), do: nil
  defp selected_visible_todo(_user_id, "", _visible_ids), do: nil

  defp selected_visible_todo(user_id, todo_id, visible_ids)
       when is_binary(user_id) and is_binary(todo_id) do
    with true <- MapSet.member?(visible_ids, todo_id),
         %Todo{} = todo <- Todos.get_for_user(user_id, todo_id) do
      todo
    else
      _ -> nil
    end
  end

  defp selected_visible_todo(_user_id, _todo_id, _visible_ids), do: nil

  defp todo_query_opts(filters) do
    [
      limit: @page_limit,
      query: normalize_text(filters["q"]),
      statuses: status_filter(filters["status"]),
      attention_mode: attention_filter(filters["attention"]),
      source: source_filter(filters["source"]),
      sort_by: filters["sort"],
      sort_dir: filters["dir"]
    ]
    |> Keyword.merge(due_filter(filters["due"]))
    |> Enum.reject(fn
      {_key, nil} -> true
      {_key, ""} -> true
      {_key, []} -> true
      _entry -> false
    end)
  end

  defp status_filter("active"), do: ["open", "snoozed"]
  defp status_filter("all"), do: nil
  defp status_filter(status) when status in ~w(open snoozed done dismissed), do: [status]
  defp status_filter(_status), do: ["open", "snoozed"]

  defp attention_filter("all"), do: nil
  defp attention_filter(attention) when attention in ~w(act_now monitor), do: attention
  defp attention_filter(_attention), do: nil

  defp source_filter("all"), do: nil
  defp source_filter(source) when is_binary(source), do: source
  defp source_filter(_source), do: nil

  defp due_filter("overdue"), do: [due_before: DateTime.utc_now()]

  defp due_filter("today") do
    today = Date.utc_today()

    [
      due_after: DateTime.new!(today, ~T[00:00:00], "Etc/UTC"),
      due_before: DateTime.new!(today, ~T[23:59:59], "Etc/UTC")
    ]
  end

  defp due_filter("week") do
    now = DateTime.utc_now()
    week_out = now |> DateTime.add(7, :day)

    [due_before: week_out]
  end

  defp due_filter("no_due"), do: [due_nil?: true]
  defp due_filter(_due), do: []

  defp normalize_filters(params) when is_map(params) do
    %{
      "q" => normalize_text(Map.get(params, "q")) || "",
      "status" =>
        normalize_choice(
          Map.get(params, "status"),
          ~w(active open snoozed done dismissed all),
          "active"
        ),
      "attention" =>
        normalize_choice(Map.get(params, "attention"), ~w(all act_now monitor), "all"),
      "due" => normalize_choice(Map.get(params, "due"), ~w(all overdue today week no_due), "all"),
      "source" => normalize_source(Map.get(params, "source")),
      "sort" =>
        normalize_choice(
          Map.get(params, "sort"),
          ~w(rank title source status attention priority due updated),
          "rank"
        ),
      "dir" => normalize_choice(Map.get(params, "dir"), ~w(asc desc), "desc")
    }
  end

  defp normalize_filters(_params), do: @default_filters

  defp normalize_choice(value, allowed, fallback) when is_binary(value) do
    value = String.trim(value)
    if value in allowed, do: value, else: fallback
  end

  defp normalize_choice(_value, _allowed, fallback), do: fallback

  defp normalize_source(value) when is_binary(value) do
    case String.trim(value) do
      "" -> "all"
      source -> source
    end
  end

  defp normalize_source(_value), do: "all"

  defp todos_path(filters, extra_params \\ %{}) do
    query =
      filters
      |> Map.merge(extra_params)
      |> Enum.reject(fn {key, value} ->
        blank?(value) or Map.get(@default_filters, key) == value
      end)
      |> Enum.into(%{})

    if map_size(query) == 0, do: ~p"/todos", else: ~p"/todos?#{query}"
  end

  defp current_path_from_uri(uri) do
    uri
    |> URI.parse()
    |> Map.get(:path)
    |> case do
      nil -> "/todos"
      "" -> "/todos"
      path -> path
    end
  rescue
    _ -> "/todos"
  end

  defp next_sort_dir(%{"sort" => field, "dir" => "asc"}, field), do: "desc"
  defp next_sort_dir(_filters, _field), do: "asc"

  defp sort_indicator(%{"sort" => field, "dir" => "asc"}, field), do: "^"
  defp sort_indicator(%{"sort" => field, "dir" => "desc"}, field), do: "v"
  defp sort_indicator(_filters, _field), do: ""

  defp todo_row_class(%Todo{} = todo, selected_todo_ids, selected_todo_id) do
    [
      "cursor-pointer transition-colors hover:bg-zinc-950/[0.025]",
      MapSet.member?(selected_todo_ids, todo.id) && "bg-blue-50/70",
      selected_todo_id == todo.id && "outline outline-1 -outline-offset-1 outline-zinc-950/10"
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" ")
  end

  defp todo_detail_fields(%Todo{} = todo) do
    [
      %{label: "Source", value: todo_source_label(todo.source)},
      %{label: "Account", value: todo_source_account_value(todo)},
      %{label: "Summary", value: todo.summary},
      %{label: "Next action", value: todo.next_action},
      %{label: "Due", value: format_datetime(todo.due_at, nil)},
      %{label: "Snoozed until", value: format_datetime(todo.snoozed_until, nil)},
      %{label: "Updated", value: format_datetime(todo.updated_at, nil)},
      %{label: "Notes", value: todo.notes},
      %{label: "Action plan", value: todo.action_plan}
    ]
    |> Enum.reject(fn field -> blank?(field.value) end)
  end

  defp todo_metadata_pairs(%Todo{} = todo) do
    (todo.metadata || %{})
    |> Enum.map(fn {key, value} ->
      %{
        label: label(key),
        value: metadata_value(value)
      }
    end)
    |> Enum.reject(fn field -> blank?(field.value) end)
    |> Enum.take(10)
  end

  defp metadata_value(value) when is_binary(value), do: normalize_text(value)
  defp metadata_value(value) when is_integer(value), do: Integer.to_string(value)
  defp metadata_value(value) when is_float(value), do: Float.to_string(value)
  defp metadata_value(value) when is_boolean(value), do: to_string(value)
  defp metadata_value(_value), do: nil

  defp todo_source_account_value(%Todo{} = todo) do
    metadata = todo.metadata || %{}

    metadata_account =
      todo.source_account_label ||
        fetch_map_value(metadata, "account") ||
        fetch_map_value(metadata, "account_email") ||
        fetch_map_value(metadata, "mailbox") ||
        fetch_map_value(metadata, "workspace_name") ||
        fetch_map_value(metadata, "google_account_email")

    normalize_text(metadata_account)
  end

  defp fetch_map_value(map, key) when is_map(map) and is_binary(key) do
    case Map.fetch(map, key) do
      {:ok, value} ->
        value

      :error ->
        Enum.find_value(map, fn
          {map_key, value} when is_atom(map_key) ->
            if Atom.to_string(map_key) == key, do: value

          _ ->
            nil
        end)
    end
  end

  defp fetch_map_value(_map, _key), do: nil

  defp result_count_label(todos, total_count) do
    shown = length(todos)

    cond do
      total_count > shown -> "Showing #{shown} of #{total_count} matching todos."
      total_count == 1 -> "1 todo shown."
      true -> "#{total_count} todos shown."
    end
  end

  defp active_filter_label(filters) do
    [
      option_label(@status_options, filters["status"]),
      option_label(@attention_options, filters["attention"]),
      option_label(@due_options, filters["due"]),
      option_label(@source_options, filters["source"])
    ]
    |> Enum.reject(&(&1 in [nil, "All modes", "Any due date", "All sources"]))
    |> case do
      [] -> "Default view"
      labels -> Enum.join(labels, " / ")
    end
  end

  defp option_label(options, value) do
    Enum.find_value(options, fn
      {label, ^value} -> label
      _option -> nil
    end)
  end

  defp empty_message(%{"q" => query}) do
    if present?(query), do: "No todos match this search.", else: "No todos match these filters."
  end

  defp status_color("open"), do: "emerald"
  defp status_color("snoozed"), do: "amber"
  defp status_color("done"), do: "blue"
  defp status_color("dismissed"), do: "zinc"
  defp status_color(_status), do: "zinc"

  defp attention_color("monitor"), do: "cyan"
  defp attention_color(_attention), do: "emerald"

  defp todo_status_label("open"), do: "Open"
  defp todo_status_label("snoozed"), do: "Snoozed"
  defp todo_status_label("done"), do: "Done"
  defp todo_status_label("dismissed"), do: "Dismissed"
  defp todo_status_label(value), do: label(value)

  defp attention_mode_label("monitor"), do: "Watching"
  defp attention_mode_label(_attention), do: "Needs action"

  defp todo_source_label("gmail"), do: "Gmail"
  defp todo_source_label("calendar"), do: "Google Calendar"
  defp todo_source_label("google_calendar"), do: "Google Calendar"
  defp todo_source_label("slack"), do: "Slack"
  defp todo_source_label("github"), do: "GitHub"
  defp todo_source_label("telegram"), do: "Telegram"
  defp todo_source_label(source) when is_binary(source) and source != "", do: label(source)
  defp todo_source_label(_source), do: "System"

  defp format_datetime(nil, fallback), do: fallback

  defp format_datetime(%DateTime{} = datetime, _fallback) do
    Calendar.strftime(datetime, "%Y-%m-%d %H:%M UTC")
  end

  defp format_datetime(%NaiveDateTime{} = datetime, _fallback) do
    Calendar.strftime(datetime, "%Y-%m-%d %H:%M")
  end

  defp format_datetime(value, _fallback), do: to_string(value)

  defp label(value) when is_atom(value), do: value |> Atom.to_string() |> label()

  defp label(value) when is_binary(value) do
    value
    |> String.replace("_", " ")
    |> String.trim()
    |> case do
      "" -> "Unknown"
      text -> String.capitalize(text)
    end
  end

  defp label(value), do: to_string(value)

  defp current_user_id(socket), do: socket.assigns.current_user.id

  defp normalize_text(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      text -> text
    end
  end

  defp normalize_text(_value), do: nil

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(nil), do: false
  defp present?(_value), do: true

  defp blank?(value), do: not present?(value)
end
