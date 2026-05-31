defmodule MaraithonWeb.TodosLive do
  use MaraithonWeb, :live_view

  alias Maraithon.{ActionCards, BriefingSchedules, SourceLabels, Timezones}
  alias Maraithon.Todos
  alias Maraithon.Todos.{DecisionSignals, Todo}
  alias MaraithonWeb.TodoActionCopy

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
  @empty_state_filter_keys ~w(q status attention due source)
  @status_options [
    {"Active", "active"},
    {"Open", "open"},
    {"Snoozed", "snoozed"},
    {"Done", "done"},
    {"Dismissed", "dismissed"},
    {"All", "all"}
  ]
  @attention_options [
    {"Any attention", "all"},
    {"Needs action", "act_now"},
    {"Decisions", "decision"},
    {"Watching", "monitor"}
  ]
  @due_options [
    {"Any due date", "all"},
    {"Past due", "overdue"},
    {"Due today", "today"},
    {"Next 7 days", "week"},
    {"No due date", "no_due"}
  ]
  @source_options [
    {"All sources", "all"},
    {"Gmail", "gmail"},
    {"Calendar", "calendar"},
    {"Google Calendar", "google_calendar"},
    {"Slack", "slack"},
    {"Telegram", "telegram"},
    {"iMessage", "imessage"},
    {"Notes", "notes"},
    {"Reminders", "reminders"},
    {"Files", "files"},
    {"Browser History", "browser_history"},
    {"Voice Memos", "voice_memos"},
    {"GitHub", "github"},
    {"Added by you", "manual"}
  ]

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: "Open Work",
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
       selected_todo: nil,
       timezone_info: default_timezone_info()
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

  def handle_event("see_less_selected_todos", _params, socket) do
    {:noreply, apply_bulk_todo_action(socket, :see_less)}
  end

  def handle_event("complete_todo", %{"id" => todo_id}, socket) do
    case Todos.mark_done(current_user_id(socket), todo_id, note: "Completed from Work page.") do
      {:ok, _todo} ->
        {:noreply,
         socket
         |> refresh_todos()
         |> put_flash(:info, "Work item done.")}

      {:error, reason} ->
        {:noreply,
         socket
         |> refresh_todos()
         |> put_flash(:error, TodoActionCopy.error(:complete, reason))}
    end
  end

  def handle_event("dismiss_todo", %{"id" => todo_id}, socket) do
    case Todos.dismiss(current_user_id(socket), todo_id, note: "Dismissed from Work page.") do
      {:ok, _todo} ->
        {:noreply,
         socket
         |> refresh_todos()
         |> put_flash(:info, "Work item dismissed.")}

      {:error, reason} ->
        {:noreply,
         socket
         |> refresh_todos()
         |> put_flash(:error, TodoActionCopy.error(:dismiss, reason))}
    end
  end

  def handle_event("see_less_todo", %{"id" => todo_id}, socket) do
    selected? = socket.assigns.selected_todo_id == todo_id

    case Todos.see_less_like(current_user_id(socket), todo_id, source: "todos_page") do
      {:ok, _result} ->
        socket =
          socket
          |> refresh_todos()
          |> put_flash(:info, "Similar work will show up less often.")

        socket =
          if selected? do
            push_patch(socket, to: todos_path(socket.assigns.filters))
          else
            socket
          end

        {:noreply, socket}

      {:error, reason} ->
        {:noreply,
         socket
         |> refresh_todos()
         |> put_flash(:error, TodoActionCopy.error(:see_less, reason))}
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

  def handle_event("save_todo_next_action", %{"id" => todo_id, "todo" => params}, socket) do
    next_action = normalize_text(Map.get(params, "next_action"))

    cond do
      is_nil(next_action) ->
        {:noreply, put_flash(socket, :error, "Enter a next action before saving.")}

      String.length(next_action) < 4 ->
        {:noreply, put_flash(socket, :error, "Enter a next action with at least 4 characters.")}

      true ->
        case Todos.update_for_user(current_user_id(socket), todo_id, %{
               "next_action" => next_action
             }) do
          {:ok, _todo} ->
            {:noreply,
             socket
             |> refresh_todos()
             |> put_flash(:info, "Updated next action.")}

          {:error, reason} ->
            {:noreply,
             socket
             |> refresh_todos()
             |> put_flash(:error, TodoActionCopy.error(:update_next_action, reason))}
        end
    end
  end

  def handle_event("save_todo_next_action", _params, socket) do
    {:noreply, put_flash(socket, :error, "Enter a next action before saving.")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_path={@current_path} current_user={@current_user}>
      <div class="space-y-6">
        <.page_header
          title="Open Work"
          subtitle="A fast place to triage open obligations, follow-ups that need confirmation, personal commitments, and completed work."
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

            <.field label="Attention" for={@filter_form[:attention].id}>
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
                <h2 class="text-sm/6 font-semibold text-zinc-950">Work list</h2>
                <p class="text-sm/6 text-zinc-500">
                  <%= result_count_label(@todos, @total_count) %>
                </p>
              </div>
              <.badge color="zinc"><%= active_filter_label(@filters) %></.badge>
            </div>
          </:header>

          <div class={[
            "grid grid-cols-1 gap-4 py-4",
            @selected_todo && "xl:grid-cols-[minmax(0,1fr)_26rem]",
            MapSet.size(@selected_todo_ids) > 0 && "pb-24"
          ]}>
            <div class="min-w-0">
              <.todo_bulk_toolbar selected_todo_ids={@selected_todo_ids} />

              <.table>
                <.table_head>
                  <.table_row>
                    <.table_header class="w-10">
                      <input
                        type="checkbox"
                        aria-label="Select all work items"
                        checked={all_visible_todos_selected?(@todos, @selected_todo_ids)}
                        phx-click="toggle_all_todos"
                        class="size-4 rounded border-zinc-300 text-zinc-900 focus:ring-zinc-900"
                      />
                    </.table_header>
                    <.sortable_table_header filters={@filters} field="title" class="min-w-[22rem]">
                      Work item
                    </.sortable_table_header>
                    <.sortable_table_header filters={@filters} field="source">Source</.sortable_table_header>
                    <.sortable_table_header filters={@filters} field="status">Status</.sortable_table_header>
                    <.sortable_table_header filters={@filters} field="attention">Attention</.sortable_table_header>
                    <.sortable_table_header filters={@filters} field="priority">Urgency</.sortable_table_header>
                    <.sortable_table_header filters={@filters} field="due">Due</.sortable_table_header>
                    <.sortable_table_header filters={@filters} field="updated">Updated</.sortable_table_header>
                    <.table_header class="w-48 text-right">Actions</.table_header>
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
                      <div class="flex flex-wrap items-center gap-2">
                        <div class="font-medium text-zinc-950"><%= todo.title %></div>
                        <.badge :if={todo_decision_signal?(todo)} color="indigo">Decision</.badge>
                      </div>
                      <div :if={present?(todo.summary)} class="mt-1 line-clamp-2 text-sm/6 text-zinc-600">
                        <%= todo.summary %>
                      </div>
                      <div :if={present?(todo.next_action)} class="mt-1 line-clamp-2 text-sm/6 text-zinc-700">
                        <span class="font-medium text-zinc-950"><%= todo_next_action_label(todo) %>:</span> <%= todo.next_action %>
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
                    <.table_cell class="align-top">
                      <.badge color={priority_color(todo.priority)}>
                        <%= priority_label(todo.priority) %>
                      </.badge>
                    </.table_cell>
                    <.table_cell class="whitespace-normal align-top text-xs/5 text-zinc-500">
                      <%= format_datetime(todo.due_at, "No due date", @timezone_info) %>
                    </.table_cell>
                    <.table_cell class="whitespace-normal align-top text-xs/5 text-zinc-500">
                      <%= format_datetime(todo.updated_at, "Never", @timezone_info) %>
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
                        <.button
                          type="button"
                          phx-click="see_less_todo"
                          phx-value-id={todo.id}
                          onclick="event.stopPropagation()"
                          variant="plain"
                          class="text-xs text-zinc-500 hover:text-zinc-950"
                        >
                          Show less
                        </.button>
                      </div>
                    </.table_cell>
                  </.table_row>
                </.table_body>
              </.table>
            </div>

            <.todo_detail_panel
              :if={@selected_todo}
              todo={@selected_todo}
              filters={@filters}
              timezone_info={@timezone_info}
            />
          </div>
        </.panel>
      </div>
    </Layouts.app>
    """
  end

  defp refresh_todos(socket) do
    user_id = current_user_id(socket)
    timezone_info = user_timezone_info(user_id)
    query_opts = todo_query_opts(socket.assigns.filters, timezone_info)
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
      selected_todo: selected_todo,
      timezone_info: timezone_info
    )
  end

  attr :selected_todo_ids, :any, required: true

  defp todo_bulk_toolbar(assigns) do
    assigns = assign(assigns, :selected_count, MapSet.size(assigns.selected_todo_ids))

    ~H"""
    <div
      :if={@selected_count > 0}
      id="todo-bulk-actions"
      class="pointer-events-none fixed inset-x-3 bottom-[calc(1rem+env(safe-area-inset-bottom))] z-50 flex justify-center sm:inset-x-6 lg:left-64 lg:bottom-6"
    >
      <div class="pointer-events-auto flex max-w-[calc(100vw-1.5rem)] flex-wrap items-center justify-center gap-1.5 rounded-lg border border-zinc-950/20 bg-zinc-950/95 px-2.5 py-2 text-white shadow-xl ring-1 ring-white/10 backdrop-blur">
        <span class="rounded-md border border-white/10 bg-white/10 px-3 py-1.5 text-sm/6 font-semibold">
          <%= @selected_count %> selected
        </span>
        <button
          type="button"
          phx-click="clear_todo_selection"
          aria-label="Clear selection"
          class="rounded-md px-2 py-1.5 text-sm/6 text-zinc-300 hover:bg-white/10 hover:text-white focus:outline-none focus:ring-2 focus:ring-white/30"
        >
          ×
        </button>
        <span class="mx-0.5 hidden h-6 w-px bg-white/15 sm:block" aria-hidden="true"></span>
        <.button
          type="button"
          phx-click="complete_selected_todos"
          variant="plain"
          class="text-xs text-zinc-200 hover:bg-white/10 hover:text-white"
        >
          Done
        </.button>
        <.button
          type="button"
          phx-click="dismiss_selected_todos"
          variant="plain"
          class="text-xs text-zinc-200 hover:bg-white/10 hover:text-white"
        >
          Dismiss
        </.button>
        <.button
          type="button"
          phx-click="see_less_selected_todos"
          variant="plain"
          class="text-xs text-zinc-200 hover:bg-white/10 hover:text-white"
        >
          Show less
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
  attr :timezone_info, :map, required: true

  defp todo_detail_panel(assigns) do
    can_edit_next_action = todo_next_action_editable?(assigns.todo)
    decision_signal? = todo_decision_signal?(assigns.todo)

    assigns =
      assigns
      |> assign(:can_edit_next_action, can_edit_next_action)
      |> assign(:decision_signal?, decision_signal?)
      |> assign(:decision_review_fields, todo_decision_review_fields(assigns.todo))
      |> assign(
        :next_action_form,
        to_form(%{"next_action" => assigns.todo.next_action || ""}, as: :todo)
      )

    ~H"""
    <aside id="todo-detail" class="rounded-lg border border-zinc-950/10 bg-white px-4 py-4 shadow-sm">
      <div class="flex items-start justify-between gap-3">
        <div class="min-w-0">
          <div class="flex flex-wrap items-center gap-2">
            <.badge color={status_color(@todo.status)}><%= todo_status_label(@todo.status) %></.badge>
            <.badge color={attention_color(@todo.attention_mode)}>
              <%= attention_mode_label(@todo.attention_mode) %>
            </.badge>
            <.badge color={priority_color(@todo.priority)}>
              <%= priority_label(@todo.priority) %>
            </.badge>
            <.badge :if={@decision_signal?} color="indigo">Decision</.badge>
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

      <div :if={@decision_review_fields != []} class="mt-4 border-t border-zinc-950/10 pt-4">
        <p class="text-xs/5 font-medium text-zinc-500">Decision ready for review</p>
        <dl class="mt-2 divide-y divide-zinc-950/5">
          <div :for={field <- @decision_review_fields} class="grid grid-cols-1 gap-1 py-2">
            <dt class="text-xs/5 font-medium text-zinc-500"><%= field.label %></dt>
            <dd class="break-words text-sm/6 text-zinc-700"><%= field.value %></dd>
          </div>
        </dl>
      </div>

      <.form
        :if={@can_edit_next_action}
        for={@next_action_form}
        id={"todo-next-action-form-#{@todo.id}"}
        phx-submit="save_todo_next_action"
        phx-value-id={@todo.id}
        class="mt-4 border-t border-zinc-950/10 pt-4"
      >
        <.field label="Next action" for={"todo-next-action-#{@todo.id}"}>
          <.c_textarea
            id={"todo-next-action-#{@todo.id}"}
            name={@next_action_form[:next_action].name}
            value={@next_action_form[:next_action].value}
            rows={3}
            maxlength="1000"
            required
          />
        </.field>

        <div class="mt-3 flex justify-end">
          <.button type="submit" variant="outline" class="text-xs" phx-disable-with="Saving...">
            Save action
          </.button>
        </div>
      </.form>

      <dl class="mt-4 divide-y divide-zinc-950/5">
        <div :for={field <- todo_detail_fields(@todo, @can_edit_next_action, @timezone_info)} class="grid grid-cols-1 gap-1 py-3">
          <dt class="text-xs/5 font-medium text-zinc-500"><%= field.label %></dt>
          <dd class="break-words text-sm/6 text-zinc-700"><%= field.value %></dd>
        </div>
      </dl>

      <div :if={@can_edit_next_action} class="mt-4 flex flex-wrap justify-end gap-1 border-t border-zinc-950/10 pt-4">
        <.button type="button" phx-click="complete_todo" phx-value-id={@todo.id} variant="plain" class="text-xs text-zinc-600">
          Done
        </.button>
        <.button type="button" phx-click="dismiss_todo" phx-value-id={@todo.id} variant="plain" class="text-xs text-zinc-600">
          Dismiss
        </.button>
        <.button type="button" phx-click="see_less_todo" phx-value-id={@todo.id} variant="plain" class="text-xs text-zinc-600">
          Show less
        </.button>
      </div>
    </aside>
    """
  end

  defp todo_next_action_editable?(%Todo{status: status}), do: status in ~w(open snoozed)

  defp apply_bulk_todo_action(socket, action) do
    todo_ids = selected_visible_todo_ids(socket)

    if todo_ids == [] do
      put_flash(socket, :error, "Select at least one work item first.")
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

  defp run_todo_action(:see_less, user_id, todo_id, _note) do
    case Todos.see_less_like(user_id, todo_id, source: "todos_page_bulk") do
      {:ok, %{todo: todo}} -> {:ok, todo}
      {:error, reason} -> {:error, reason}
    end
  end

  defp bulk_todo_note(:complete), do: "Completed from Work bulk action."
  defp bulk_todo_note(:dismiss), do: "Dismissed from Work bulk action."
  defp bulk_todo_note(:see_less), do: "Dismissed from Work bulk see less action."

  defp bulk_todo_flash_kind(0, [_ | _]), do: :error
  defp bulk_todo_flash_kind(_updated_count, _errors), do: :info

  defp bulk_todo_flash(action, updated_count, errors) do
    base =
      case action do
        :complete -> "Marked #{pluralize_work_item(updated_count)} done"
        :dismiss -> "Dismissed #{pluralize_work_item(updated_count)}"
        :see_less -> "Similar work will show up less often"
      end

    case length(errors) do
      0 -> base
      error_count -> "#{base}; #{error_count} could not be updated"
    end
  end

  defp pluralize_work_item(1), do: "1 work item"
  defp pluralize_work_item(count), do: "#{count} work items"

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

  defp todo_query_opts(filters, timezone_info) do
    [
      limit: @page_limit,
      query: normalize_text(filters["q"]),
      statuses: status_filter(filters["status"]),
      attention_mode: attention_filter(filters["attention"]),
      decision_only?: decision_filter?(filters["attention"]),
      source: source_filter(filters["source"]),
      sort_by: filters["sort"],
      sort_dir: filters["dir"]
    ]
    |> Keyword.merge(due_filter(filters["due"], timezone_info))
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
  defp attention_filter("decision"), do: nil
  defp attention_filter(attention) when attention in ~w(act_now monitor), do: attention
  defp attention_filter(_attention), do: nil

  defp decision_filter?("decision"), do: true
  defp decision_filter?(_attention), do: false

  defp source_filter("all"), do: nil
  defp source_filter(source) when is_binary(source), do: source
  defp source_filter(_source), do: nil

  defp due_filter("overdue", _timezone_info), do: [due_before: DateTime.utc_now()]

  defp due_filter("today", timezone_info) do
    today = local_today(timezone_info)

    [
      due_after: local_boundary_to_utc(today, ~T[00:00:00], timezone_info),
      due_before: local_boundary_to_utc(today, ~T[23:59:59], timezone_info)
    ]
  end

  defp due_filter("week", _timezone_info) do
    now = DateTime.utc_now()
    week_out = now |> DateTime.add(7, :day)

    [due_after: now, due_before: week_out]
  end

  defp due_filter("no_due", _timezone_info), do: [due_nil?: true]
  defp due_filter(_due, _timezone_info), do: []

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
        normalize_choice(Map.get(params, "attention"), ~w(all act_now decision monitor), "all"),
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

  defp todo_detail_fields(%Todo{} = todo, next_action_editable?, timezone_info) do
    [
      %{label: "Source", value: todo_source_label(todo.source)},
      %{label: "Account", value: todo_source_account_value(todo)},
      %{label: "Summary", value: todo.summary},
      %{label: "Next action", value: if(next_action_editable?, do: nil, else: todo.next_action)},
      %{label: "Due", value: format_datetime(todo.due_at, nil, timezone_info)},
      %{label: "Snoozed until", value: format_datetime(todo.snoozed_until, nil, timezone_info)},
      %{label: "Updated", value: format_datetime(todo.updated_at, nil, timezone_info)},
      %{label: "Notes", value: todo.notes},
      %{label: "Action plan", value: todo.action_plan}
    ]
    |> Enum.reject(fn field -> blank?(field.value) end)
  end

  defp todo_decision_review_fields(%Todo{} = todo) do
    if todo_decision_signal?(todo) do
      card = ActionCards.for_todo(todo, include_disconnected: false)
      context = Map.get(card, "context_pack") || %{}

      core_fields = [
        %{label: "Decision needed", value: Map.get(card, "decision_prompt")},
        %{label: "Suggested move", value: Map.get(card, "next_best_action")},
        %{label: "Why this matters now", value: Map.get(card, "why_now")},
        %{label: "Source evidence", value: ActionCards.evidence_excerpt(card)},
        %{
          label: "Context checked",
          value: ActionCards.source_health_note(card) || todo_source_check_value(todo)
        },
        %{label: "Prepared action", value: ActionCards.prepared_action_hint(card)},
        %{label: "Who and thread", value: Map.get(context, "summary")}
      ]

      context_fields =
        card
        |> ActionCards.context_items()
        |> Enum.map(fn item -> %{label: item.label, value: item.value} end)

      (core_fields ++ context_fields)
      |> Enum.map(fn field -> %{field | value: normalize_context_value(field.value)} end)
      |> Enum.reject(fn field -> blank?(field.value) end)
      |> Enum.uniq_by(fn field -> {field.label, field.value} end)
      |> Enum.take(10)
    else
      []
    end
  end

  defp todo_source_check_value(%Todo{source: source}) do
    case todo_source_label(source) do
      nil -> nil
      "" -> nil
      label -> "Used #{label}."
    end
  end

  defp normalize_context_value(value) when is_binary(value), do: normalize_text(value)
  defp normalize_context_value(value) when is_integer(value), do: Integer.to_string(value)
  defp normalize_context_value(value) when is_float(value), do: Float.to_string(value)
  defp normalize_context_value(value) when is_boolean(value), do: to_string(value)
  defp normalize_context_value(_value), do: nil

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
      total_count > shown -> "Showing #{shown} of #{total_count} matching work items."
      total_count == 1 -> "1 work item shown."
      true -> "#{total_count} work items shown."
    end
  end

  defp active_filter_label(filters) do
    [
      option_label(@status_options, filters["status"]),
      option_label(@attention_options, filters["attention"]),
      option_label(@due_options, filters["due"]),
      option_label(@source_options, filters["source"])
    ]
    |> Enum.reject(&(&1 in [nil, "Any attention", "Any due date", "All sources"]))
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

  defp empty_message(%{"q" => query} = filters) do
    source_label = source_filter_label(filters)

    cond do
      present?(query) ->
        "No work matches that search."

      filters["attention"] == "decision" ->
        "No decisions are waiting in this filter."

      filters["due"] == "overdue" ->
        "No past-due work in this filter."

      filters["due"] == "today" ->
        "No work due today in this filter."

      filters["due"] == "week" ->
        "No work due in the next 7 days in this filter."

      filters["due"] == "no_due" ->
        "No unscheduled work in this filter."

      filters["status"] == "done" ->
        "No completed work in this filter."

      filters["status"] == "dismissed" ->
        "No dismissed work in this filter."

      filters["status"] == "snoozed" ->
        "No snoozed work in this filter."

      filters["status"] == "open" ->
        "No open work in this filter."

      filters["attention"] == "monitor" ->
        "No watched work in this filter."

      filters["attention"] == "act_now" ->
        "No action-needed work in this filter."

      source_label ->
        "No work from #{source_label} in this filter."

      default_filter_view?(filters) ->
        "Your open work list is clear. Add a follow-up manually, or Maraithon will surface commitments when the next move is clear."

      true ->
        "No work in this filter."
    end
  end

  defp source_filter_label(%{"source" => source}) when source not in [nil, "", "all"] do
    option_label(@source_options, source) || todo_source_label(source)
  end

  defp source_filter_label(_filters), do: nil

  defp default_filter_view?(filters) do
    Enum.all?(@empty_state_filter_keys, fn key ->
      Map.get(filters, key, Map.fetch!(@default_filters, key)) ==
        Map.fetch!(@default_filters, key)
    end)
  end

  defp status_color("open"), do: "emerald"
  defp status_color("snoozed"), do: "amber"
  defp status_color("done"), do: "blue"
  defp status_color("dismissed"), do: "zinc"
  defp status_color(_status), do: "zinc"

  defp attention_color("monitor"), do: "cyan"
  defp attention_color(_attention), do: "emerald"

  defp priority_color(priority) when is_integer(priority) and priority >= 90, do: "red"
  defp priority_color(priority) when is_integer(priority) and priority >= 75, do: "amber"
  defp priority_color(priority) when is_integer(priority) and priority >= 50, do: "blue"
  defp priority_color(_priority), do: "zinc"

  defp priority_label(priority) when is_integer(priority) and priority >= 90, do: "Critical"
  defp priority_label(priority) when is_integer(priority) and priority >= 75, do: "High"
  defp priority_label(priority) when is_integer(priority) and priority >= 50, do: "Normal"
  defp priority_label(_priority), do: "Low"

  defp todo_status_label("open"), do: "Open"
  defp todo_status_label("snoozed"), do: "Snoozed"
  defp todo_status_label("done"), do: "Done"
  defp todo_status_label("dismissed"), do: "Dismissed"
  defp todo_status_label(value), do: label(value)

  defp attention_mode_label("monitor"), do: "Watching"
  defp attention_mode_label(_attention), do: "Needs action"

  defp todo_decision_signal?(%Todo{} = todo), do: DecisionSignals.needs_decision?(todo)
  defp todo_decision_signal?(_todo), do: false

  defp todo_next_action_label(%Todo{} = todo) do
    if todo_decision_signal?(todo), do: "Suggested", else: "Next"
  end

  defp todo_source_label("gmail"), do: "Gmail"
  defp todo_source_label("google_calendar"), do: "Google Calendar"

  defp todo_source_label(source) when is_binary(source) and source != "",
    do: SourceLabels.label(source)

  defp todo_source_label(_source), do: "Maraithon"

  defp format_datetime(nil, fallback, _timezone_info), do: fallback

  defp format_datetime(%DateTime{} = datetime, _fallback, timezone_info) do
    timezone_info = normalize_timezone_info(timezone_info)
    offset = Timezones.offset_at(timezone_info.name, datetime, timezone_info.offset_hours)
    label = Timezones.label(timezone_info.name, offset)

    datetime
    |> DateTime.add(offset, :hour)
    |> Calendar.strftime("%b %-d, %Y at %-I:%M %p #{label}")
  end

  defp format_datetime(%NaiveDateTime{} = datetime, _fallback, timezone_info) do
    timezone_info = normalize_timezone_info(timezone_info)
    label = Timezones.label(timezone_info.name, timezone_info.offset_hours)
    Calendar.strftime(datetime, "%b %-d, %Y at %-I:%M %p #{label}")
  end

  defp format_datetime(value, _fallback, _timezone_info), do: to_string(value)

  defp user_timezone_info(user_id) when is_binary(user_id) do
    case BriefingSchedules.summarize_for_prompt(user_id) do
      %{timezone_name: timezone_name, timezone_offset_hours: offset_hours} ->
        normalize_timezone_info(%{name: timezone_name, offset_hours: offset_hours})

      _other ->
        default_timezone_info()
    end
  rescue
    _exception -> default_timezone_info()
  end

  defp user_timezone_info(_user_id), do: default_timezone_info()

  defp normalize_timezone_info(%{name: name, offset_hours: offset_hours}) do
    %{name: name, offset_hours: Timezones.normalize_offset(offset_hours)}
  end

  defp normalize_timezone_info(_timezone_info), do: default_timezone_info()

  defp default_timezone_info, do: %{name: nil, offset_hours: -5}

  defp local_today(timezone_info) do
    timezone_info = normalize_timezone_info(timezone_info)
    now = DateTime.utc_now()
    offset = Timezones.offset_at(timezone_info.name, now, timezone_info.offset_hours)

    now
    |> DateTime.add(offset, :hour)
    |> DateTime.to_date()
  end

  defp local_boundary_to_utc(%Date{} = date, %Time{} = time, timezone_info) do
    timezone_info = normalize_timezone_info(timezone_info)
    local_boundary = DateTime.new!(date, time, "Etc/UTC")

    offset =
      Timezones.offset_for_local(timezone_info.name, local_boundary, timezone_info.offset_hours)

    DateTime.add(local_boundary, -offset, :hour)
  end

  defp label(value) when is_atom(value), do: value |> Atom.to_string() |> label()

  defp label(value) when is_binary(value) do
    value
    |> String.replace("_", " ")
    |> String.trim()
    |> case do
      "" -> "Not set"
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
