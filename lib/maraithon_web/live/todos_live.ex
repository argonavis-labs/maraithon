defmodule MaraithonWeb.TodosLive do
  use MaraithonWeb, :live_view

  alias Maraithon.{ActionCards, BriefingSchedules, Projects, SourceLabels, Timezones}
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
    "project" => "all",
    "agent" => "all",
    "sort" => "rank",
    "dir" => "desc"
  }
  @default_new_todo_params %{
    "title" => "",
    "next_action" => "",
    "due_at" => "",
    "priority" => "50",
    "project_id" => "",
    "notes" => ""
  }
  @empty_state_filter_keys ~w(q status attention due source project agent)
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
  @agent_options [
    {"Any helper", "all"},
    {"Maraithon can help", "can_help"},
    {"Needs you", "needs_you"}
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
  @priority_options [
    {"Normal", "50"},
    {"High", "75"},
    {"Critical", "90"}
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
       agent_options: @agent_options,
       due_options: @due_options,
       source_options: @source_options,
       priority_options: @priority_options,
       new_todo_form: to_form(@default_new_todo_params, as: :todo),
       new_todo_errors: %{},
       new_project_form: to_form(%{"name" => ""}, as: :project),
       projects: [],
       project_options: [{"Inbox", ""}],
       project_filter_options: [{"All projects", "all"}, {"Inbox", "inbox"}],
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

    if selected_todo_id do
      _ =
        Todos.record_user_opened(current_user_id(socket), selected_todo_id,
          actor_type: "user",
          source: "todos_detail"
        )
    end

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

  def handle_event("assign_todo_project", %{"assignment" => params}, socket) do
    todo_id = normalize_text(params["todo_id"])
    project_id = normalize_text(params["project_id"])

    user_id = current_user_id(socket)

    case Todos.update_for_user(
           user_id,
           todo_id,
           %{"project_id" => project_id},
           todo_action_opts(user_id, "Project changed from todo detail.")
         ) do
      {:ok, _todo} ->
        {:noreply, socket |> refresh_todos() |> put_flash(:info, "Project updated.")}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Project could not be updated.")}
    end
  end

  def handle_event("create_project", %{"project" => %{"name" => name}}, socket) do
    case normalize_text(name) do
      nil ->
        {:noreply, put_flash(socket, :error, "Enter a project name.")}

      project_name ->
        case Projects.create_project(current_user_id(socket), %{"name" => project_name}) do
          {:ok, project} ->
            {:noreply,
             socket
             |> assign(:new_project_form, to_form(%{"name" => ""}, as: :project))
             |> refresh_todos()
             |> put_flash(:info, "#{project.name} created.")}

          {:error, %Ecto.Changeset{}} ->
            {:noreply, put_flash(socket, :error, "That project could not be created.")}

          {:error, _reason} ->
            {:noreply, put_flash(socket, :error, "Project creation failed. Try again.")}
        end
    end
  end

  def handle_event("create_todo", %{"todo" => params}, socket) do
    params = normalize_new_todo_params(params)
    user_id = current_user_id(socket)

    case build_manual_todo_attrs(user_id, params, socket.assigns.timezone_info) do
      {:ok, attrs} ->
        case Todos.upsert_many(
               user_id,
               [attrs],
               todo_action_opts(user_id, "Added from todo list.")
             ) do
          {:ok, [todo]} ->
            {:noreply,
             socket
             |> assign(:new_todo_form, to_form(@default_new_todo_params, as: :todo))
             |> assign(:new_todo_errors, %{})
             |> put_flash(:info, "Todo added.")
             |> push_patch(to: todo_detail_path(@default_filters, todo.id))}

          {:error, reason} ->
            {:noreply,
             socket
             |> assign(:new_todo_form, to_form(params, as: :todo))
             |> assign(:new_todo_errors, %{})
             |> refresh_todos()
             |> put_flash(:error, TodoActionCopy.error(:create, reason))}
        end

      {:error, errors} ->
        {:noreply,
         socket
         |> assign(:new_todo_form, to_form(params, as: :todo))
         |> assign(:new_todo_errors, errors)
         |> put_flash(:error, "Check the follow-up details and try again.")}
    end
  end

  def handle_event("create_todo", _params, socket) do
    {:noreply, put_flash(socket, :error, "Enter a follow-up before adding it.")}
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
    user_id = current_user_id(socket)

    case Todos.mark_done(user_id, todo_id, todo_action_opts(user_id, "Completed from Work page.")) do
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
    user_id = current_user_id(socket)

    case Todos.dismiss(user_id, todo_id, todo_action_opts(user_id, "Dismissed from Work page.")) do
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
    user_id = current_user_id(socket)

    case Todos.see_less_like(
           user_id,
           todo_id,
           Keyword.put(todo_actor_opts(user_id), :source, "todos_page")
         ) do
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
      {:noreply, push_patch(socket, to: todo_detail_path(socket.assigns.filters, todo_id))}
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
        user_id = current_user_id(socket)

        case Todos.update_for_user(
               user_id,
               todo_id,
               %{"next_action" => next_action},
               todo_action_opts(user_id, "Next action updated from todo detail.")
             ) do
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
      <%= if @selected_todo do %>
        <.todo_detail_panel
          todo={@selected_todo}
          filters={@filters}
          project_options={@project_options}
          timezone_info={@timezone_info}
        />
      <% else %>
        <div class="space-y-4">
          <.page_header title="Todos" />

          <details class="group">
            <summary class="inline-flex cursor-pointer list-none items-center gap-6 rounded-lg border border-zinc-950/10 bg-white px-3 py-2 text-sm/6 font-medium text-zinc-700 hover:text-zinc-950">
              Add a todo
              <span class="text-zinc-400 group-open:rotate-45" aria-hidden="true">+</span>
            </summary>
            <div class="mt-3">
              <.panel body_class="px-5 py-4">
          <:header>
            <div class="flex flex-wrap items-end justify-between gap-3">
              <h2 class="text-sm/6 font-semibold text-zinc-950">New todo</h2>
              <.form for={@new_project_form} id="new-project-form" phx-submit="create_project" class="flex items-center gap-2">
                <.c_input
                  id={@new_project_form[:name].id}
                  name={@new_project_form[:name].name}
                  value={@new_project_form[:name].value}
                  placeholder="New project"
                  maxlength="160"
                />
                <.button type="submit" variant="outline" phx-disable-with="Adding...">Add project</.button>
              </.form>
            </div>
          </:header>

          <.form
            for={@new_todo_form}
            id="new-todo-form"
            phx-submit="create_todo"
            class="grid gap-4 lg:grid-cols-[minmax(12rem,1fr)_minmax(14rem,1.2fr)_11rem_12rem_9rem_auto]"
          >
            <.field
              label="Work item"
              for={@new_todo_form[:title].id}
              error={new_todo_error(@new_todo_errors, "title")}
            >
              <.c_input
                id={@new_todo_form[:title].id}
                name={@new_todo_form[:title].name}
                value={@new_todo_form[:title].value}
                placeholder="What needs to be done?"
                maxlength="240"
                required
              />
            </.field>

            <.field
              label="Next action"
              for={@new_todo_form[:next_action].id}
              error={new_todo_error(@new_todo_errors, "next_action")}
            >
              <.c_input
                id={@new_todo_form[:next_action].id}
                name={@new_todo_form[:next_action].name}
                value={@new_todo_form[:next_action].value}
                placeholder="Send reply, decide owner, confirm ETA"
                maxlength="1000"
                required
              />
            </.field>

            <.field label="Project" for={@new_todo_form[:project_id].id}>
              <.c_select
                id={@new_todo_form[:project_id].id}
                name={@new_todo_form[:project_id].name}
              >
                <option
                  :for={{label, value} <- @project_options}
                  value={value}
                  selected={@new_todo_form[:project_id].value == value}
                >
                  <%= label %>
                </option>
              </.c_select>
            </.field>

            <.field
              label="Due"
              for={@new_todo_form[:due_at].id}
              error={new_todo_error(@new_todo_errors, "due_at")}
            >
              <.c_input
                id={@new_todo_form[:due_at].id}
                name={@new_todo_form[:due_at].name}
                type="datetime-local"
                value={@new_todo_form[:due_at].value}
              />
            </.field>

            <.field label="Urgency" for={@new_todo_form[:priority].id}>
              <.c_select id={@new_todo_form[:priority].id} name={@new_todo_form[:priority].name}>
                <option :for={{label, value} <- @priority_options} value={value} selected={@new_todo_form[:priority].value == value}>
                  <%= label %>
                </option>
              </.c_select>
            </.field>

            <div class="flex items-end">
              <.button type="submit" phx-disable-with="Adding...">Add</.button>
            </div>

            <.field label="Notes" for={@new_todo_form[:notes].id} class="lg:col-span-5">
              <.c_textarea
                id={@new_todo_form[:notes].id}
                name={@new_todo_form[:notes].name}
                value={@new_todo_form[:notes].value}
                rows={2}
                maxlength="8000"
                placeholder="Context, source, or reply constraints"
              />
            </.field>
          </.form>
        </.panel>

            </div>
          </details>

          <details class="group">
            <summary class="inline-flex cursor-pointer list-none items-center gap-3 rounded-lg border border-zinc-950/10 bg-white px-3 py-2 text-sm/6 font-medium text-zinc-700 hover:text-zinc-950">
              Search and filter
              <span class="text-xs/5 text-zinc-500"><%= active_filter_label(@filters) %></span>
            </summary>
            <div class="mt-3">
              <.panel body_class="px-5 py-4">
          <.form
            for={@filter_form}
            id="todo-filters"
            phx-change="update_filters"
            phx-submit="update_filters"
            class="grid gap-4 md:grid-cols-2 xl:grid-cols-[minmax(14rem,1.5fr)_repeat(6,minmax(8rem,1fr))_auto]"
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

            <.field label="Project" for={@filter_form[:project].id}>
              <.c_select id={@filter_form[:project].id} name={@filter_form[:project].name}>
                <option
                  :for={{label, value} <- @project_filter_options}
                  value={value}
                  selected={@filters["project"] == value}
                >
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

            <.field label="Help" for={@filter_form[:agent].id}>
              <.c_select id={@filter_form[:agent].id} name={@filter_form[:agent].name}>
                <option
                  :for={{label, value} <- @agent_options}
                  value={value}
                  selected={@filters["agent"] == value}
                >
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

            </div>
          </details>

        <.panel body_class="px-5 py-0">
          <:header>
            <div class="flex flex-wrap items-center justify-between gap-3">
              <p class="text-sm/6 text-zinc-500"><%= result_count_label(@todos, @total_count) %></p>
              <.badge color="zinc"><%= active_filter_label(@filters) %></.badge>
            </div>
          </:header>

          <div class={[
            "min-w-0 py-2",
            MapSet.size(@selected_todo_ids) > 0 && "pb-24"
          ]}>
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
                    <.sortable_table_header filters={@filters} field="title" class="min-w-[20rem]">
                      Todo
                    </.sortable_table_header>
                    <.table_header class="min-w-40">Context</.table_header>
                    <.sortable_table_header filters={@filters} field="due" class="min-w-32">
                      Due
                    </.sortable_table_header>
                    <.table_header class="w-24 text-right">Action</.table_header>
                  </.table_row>
                </.table_head>
                <.table_body>
                  <.table_row :if={@todos == []}>
                    <.table_cell colspan="5" class="py-10 text-center text-sm/6 text-zinc-500">
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
                    <.table_cell class="max-w-2xl whitespace-normal align-top">
                      <div class="flex flex-wrap items-center gap-2">
                        <div class="font-medium text-zinc-950"><%= todo.title %></div>
                        <.badge :if={todo.status != "open"} color={status_color(todo.status)}>
                          <%= todo_status_label(todo.status) %>
                        </.badge>
                        <.badge :if={todo_decision_signal?(todo)} color="indigo">Decision</.badge>
                        <.badge :if={todo.priority >= 75} color={priority_color(todo.priority)}>
                          <%= priority_label(todo.priority) %>
                        </.badge>
                      </div>
                      <p :if={present?(todo.next_action)} class="mt-1 line-clamp-1 text-sm/6 text-zinc-600">
                        <span class="font-medium text-zinc-800"><%= todo_next_action_label(todo) %>:</span>
                        <%= todo.next_action %>
                      </p>
                    </.table_cell>
                    <.table_cell class="whitespace-normal align-top">
                      <div class="text-sm/6 text-zinc-700"><%= todo_project_name(todo, @projects) %></div>
                      <div class="mt-1 flex flex-wrap items-center gap-1.5">
                        <span class="text-xs/5 text-zinc-500"><%= todo_source_label(todo.source) %></span>
                        <.badge color={agent_actionability_color(todo.agent_actionability)}>
                          <%= agent_actionability_label(todo) %>
                        </.badge>
                      </div>
                    </.table_cell>
                    <.table_cell class="whitespace-normal align-top text-xs/5 text-zinc-500">
                      <%= format_datetime(todo.due_at, "No due date", @timezone_info) %>
                    </.table_cell>
                    <.table_cell class="align-top text-right">
                      <.button
                        :if={todo.status in ["open", "snoozed"]}
                        type="button"
                        phx-click="complete_todo"
                        phx-value-id={todo.id}
                        onclick="event.stopPropagation()"
                        variant="plain"
                        class="text-xs text-zinc-500 hover:text-zinc-950"
                      >
                        Done
                      </.button>
                    </.table_cell>
                  </.table_row>
                </.table_body>
              </.table>
          </div>
        </.panel>
        </div>
      <% end %>
    </Layouts.app>
    """
  end

  defp refresh_todos(socket) do
    user_id = current_user_id(socket)
    timezone_info = user_timezone_info(user_id)
    projects = Projects.list_projects(user_id: user_id, status: "active")
    project_options = [{"Inbox", ""} | Enum.map(projects, &{&1.name, &1.id})]

    project_filter_options =
      [{"All projects", "all"}, {"Inbox", "inbox"} | Enum.map(projects, &{&1.name, &1.id})]

    query_opts = todo_query_opts(socket.assigns.filters, timezone_info)
    todos = Todos.list_for_user(user_id, query_opts)
    total_count = Todos.count_for_user(user_id, Keyword.drop(query_opts, [:limit]))
    visible_ids = todos |> Enum.map(& &1.id) |> MapSet.new()
    selected_todo_ids = MapSet.intersection(socket.assigns.selected_todo_ids, visible_ids)
    selected_todo = selected_todo_for_user(user_id, socket.assigns.selected_todo_id)

    assign(socket,
      projects: projects,
      project_options: project_options,
      project_filter_options: project_filter_options,
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
      class="pointer-events-none fixed inset-x-3 bottom-[calc(1rem+env(safe-area-inset-bottom))] z-50 flex justify-center sm:inset-x-6 lg:bottom-6"
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
  attr :project_options, :list, required: true
  attr :timezone_info, :map, required: true

  defp todo_detail_panel(assigns) do
    can_edit_next_action = todo_next_action_editable?(assigns.todo)

    assigns =
      assigns
      |> assign(:can_edit_next_action, can_edit_next_action)
      |> assign(:decision_signal?, todo_decision_signal?(assigns.todo))
      |> assign(:guidance_fields, todo_guidance_fields(assigns.todo))
      |> assign(
        :supporting_fields,
        todo_supporting_fields(assigns.todo, can_edit_next_action, assigns.timezone_info)
      )
      |> assign(
        :next_action_form,
        to_form(%{"next_action" => assigns.todo.next_action || ""}, as: :todo)
      )

    ~H"""
    <div id="todo-detail" class="mx-auto max-w-4xl space-y-5">
      <.link
        patch={todos_path(@filters)}
        class="inline-flex items-center gap-1 text-sm/6 font-medium text-zinc-500 hover:text-zinc-950"
      >
        <span aria-hidden="true">←</span> Back to todos
      </.link>

      <header class="border-b border-zinc-950/10 pb-5">
        <div class="flex flex-wrap items-center gap-2">
          <.badge color={status_color(@todo.status)}><%= todo_status_label(@todo.status) %></.badge>
          <.badge color={attention_color(@todo.attention_mode)}>
            <%= attention_mode_label(@todo.attention_mode) %>
          </.badge>
          <.badge :if={@decision_signal?} color="indigo">Decision</.badge>
          <.badge :if={@todo.priority >= 75} color={priority_color(@todo.priority)}>
            <%= priority_label(@todo.priority) %>
          </.badge>
        </div>
        <h1 class="mt-3 text-2xl/8 font-semibold tracking-tight text-zinc-950"><%= @todo.title %></h1>
        <p :if={present?(@todo.summary)} class="mt-2 max-w-3xl text-sm/6 text-zinc-600">
          <%= @todo.summary %>
        </p>
      </header>

      <div class="grid gap-5 lg:grid-cols-[minmax(0,1fr)_17rem]">
        <div class="space-y-5">
          <.panel body_class="px-5 py-5">
            <:header>
              <div>
                <h2 class="text-sm/6 font-semibold text-zinc-950">How to solve this</h2>
                <p class="text-sm/6 text-zinc-500">Start with the next concrete move, then use the supporting evidence below.</p>
              </div>
            </:header>

            <dl :if={@guidance_fields != []} class="divide-y divide-zinc-950/5">
              <div :for={field <- @guidance_fields} class="py-3 first:pt-0 last:pb-0">
                <dt class="text-xs/5 font-medium text-zinc-500"><%= field.label %></dt>
                <dd class="mt-1 whitespace-pre-wrap break-words text-sm/6 text-zinc-800"><%= field.value %></dd>
              </div>
            </dl>

            <p :if={@guidance_fields == []} class="text-sm/6 text-zinc-600">
              Add a clear next action, or ask Maraithon to work through the todo with you.
            </p>

            <.form
              :if={@can_edit_next_action}
              for={@next_action_form}
              id={"todo-next-action-form-#{@todo.id}"}
              phx-submit="save_todo_next_action"
              phx-value-id={@todo.id}
              class="mt-5 border-t border-zinc-950/10 pt-4"
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
                  Save next action
                </.button>
              </div>
            </.form>

            <div class="mt-5 border-t border-zinc-950/10 pt-4">
              <.button navigate={~p"/todos/#{@todo.id}/chat"}>Ask Maraithon</.button>
              <p :if={@todo.agent_action_requires_approval} class="mt-2 text-xs/5 text-zinc-500">
                Maraithon will ask for confirmation before any external action.
              </p>
            </div>
          </.panel>

          <.panel :if={@supporting_fields != []} body_class="px-5 py-2">
            <:header>
              <h2 class="text-sm/6 font-semibold text-zinc-950">Supporting details</h2>
            </:header>
            <dl class="divide-y divide-zinc-950/5">
              <div :for={field <- @supporting_fields} class="py-3">
                <dt class="text-xs/5 font-medium text-zinc-500"><%= field.label %></dt>
                <dd class="mt-1 whitespace-pre-wrap break-words text-sm/6 text-zinc-700"><%= field.value %></dd>
              </div>
            </dl>
          </.panel>
        </div>

        <aside class="space-y-4">
          <.panel body_class="px-4 py-4">
            <:header>
              <h2 class="text-sm/6 font-semibold text-zinc-950">Todo</h2>
            </:header>

            <div>
              <p class="text-xs/5 font-medium text-zinc-500">Project</p>
              <form id={"todo-project-form-#{@todo.id}"} phx-change="assign_todo_project" class="mt-1">
                <input type="hidden" name="assignment[todo_id]" value={@todo.id} />
                <.c_select id={"todo-project-#{@todo.id}"} name="assignment[project_id]">
                  <option
                    :for={{label, value} <- @project_options}
                    value={value}
                    selected={(@todo.project_id || "") == value}
                  >
                    <%= label %>
                  </option>
                </.c_select>
              </form>
            </div>

            <div class="mt-4 border-t border-zinc-950/10 pt-4">
              <p class="text-xs/5 font-medium text-zinc-500">Who can help</p>
              <div class="mt-2">
                <.badge color={agent_actionability_color(@todo.agent_actionability)}>
                  <%= agent_actionability_label(@todo) %>
                </.badge>
              </div>
            </div>

            <div :if={@can_edit_next_action} class="mt-4 grid gap-2 border-t border-zinc-950/10 pt-4">
              <.button type="button" phx-click="complete_todo" phx-value-id={@todo.id}>
                Mark done
              </.button>
              <div class="flex justify-center gap-1">
                <.button type="button" phx-click="dismiss_todo" phx-value-id={@todo.id} variant="plain" class="text-xs text-zinc-600">
                  Dismiss
                </.button>
                <.button type="button" phx-click="see_less_todo" phx-value-id={@todo.id} variant="plain" class="text-xs text-zinc-600">
                  Show less
                </.button>
              </div>
            </div>
          </.panel>
        </aside>
      </div>
    </div>
    """
  end

  defp todo_guidance_fields(%Todo{} = todo) do
    action_card_fields = todo_decision_review_fields(todo)

    primary =
      action_card_fields
      |> Enum.filter(
        &(&1.label in ["Decision", "Recommended move", "Suggested reply", "Prepared action"])
      )
      |> Enum.map(fn
        %{label: "Decision"} = field -> %{field | label: "What requires action"}
        %{label: "Recommended move"} = field -> %{field | label: "Recommended next move"}
        field -> field
      end)

    fallback = [
      %{label: "Next action", value: todo.next_action},
      %{label: "Action plan", value: todo.action_plan}
    ]

    (primary ++ fallback)
    |> Enum.reject(&blank?(&1.value))
    |> Enum.uniq_by(& &1.value)
    |> Enum.take(6)
  end

  defp todo_supporting_fields(%Todo{} = todo, next_action_editable?, timezone_info) do
    context =
      todo
      |> todo_decision_review_fields()
      |> Enum.reject(
        &(&1.label in ["Decision", "Recommended move", "Suggested reply", "Prepared action"])
      )

    details =
      todo
      |> todo_detail_fields(next_action_editable?, timezone_info)
      |> Enum.reject(&(&1.label in ["Next action", "Action plan", "Summary"]))

    (context ++ details)
    |> Enum.reject(&blank?(&1.value))
    |> Enum.uniq_by(fn field -> {field.label, field.value} end)
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
    do: Todos.mark_done(user_id, todo_id, todo_action_opts(user_id, note))

  defp run_todo_action(:dismiss, user_id, todo_id, note),
    do: Todos.dismiss(user_id, todo_id, todo_action_opts(user_id, note))

  defp run_todo_action(:see_less, user_id, todo_id, _note) do
    case Todos.see_less_like(
           user_id,
           todo_id,
           Keyword.put(todo_actor_opts(user_id), :source, "todos_page_bulk")
         ) do
      {:ok, %{todo: todo}} -> {:ok, todo}
      {:error, reason} -> {:error, reason}
    end
  end

  defp todo_action_opts(user_id, note), do: Keyword.put(todo_actor_opts(user_id), :note, note)

  defp todo_actor_opts(user_id),
    do: [actor_type: "user", actor_id: user_id, actor_label: "User"]

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

  defp normalize_new_todo_params(params) when is_map(params) do
    %{
      "title" => normalize_text(Map.get(params, "title")) || "",
      "next_action" => normalize_text(Map.get(params, "next_action")) || "",
      "due_at" => normalize_text(Map.get(params, "due_at")) || "",
      "priority" => normalize_new_todo_priority(Map.get(params, "priority")),
      "project_id" => normalize_text(Map.get(params, "project_id")) || "",
      "notes" => normalize_text(Map.get(params, "notes")) || ""
    }
  end

  defp normalize_new_todo_params(_params), do: @default_new_todo_params

  defp build_manual_todo_attrs(user_id, params, timezone_info) do
    title = normalize_text(params["title"])
    next_action = normalize_text(params["next_action"])
    notes = normalize_text(params["notes"])
    due_at_result = parse_new_todo_due_at(params["due_at"], timezone_info)

    errors =
      %{}
      |> maybe_put_text_error("title", title, "Enter a work item with at least 4 characters.")
      |> maybe_put_text_error(
        "next_action",
        next_action,
        "Enter a next action with at least 4 characters."
      )
      |> maybe_put_due_error(due_at_result)

    if map_size(errors) == 0 do
      {:ok,
       %{
         "source" => "manual",
         "kind" => "general",
         "title" => title,
         "summary" => manual_todo_summary(notes, next_action),
         "next_action" => next_action,
         "due_at" => elem(due_at_result, 1),
         "notes" => notes,
         "priority" => String.to_integer(params["priority"]),
         "project_id" => normalize_text(params["project_id"]),
         "dedupe_key" => "manual:web:#{Ecto.UUID.generate()}",
         "metadata" => %{
           "created_from" => "todos_web",
           "created_by_user_id" => user_id
         }
       }}
    else
      {:error, errors}
    end
  end

  defp manual_todo_summary(notes, _next_action) when is_binary(notes), do: notes
  defp manual_todo_summary(_notes, next_action), do: next_action

  defp maybe_put_text_error(errors, key, value, message) do
    if is_binary(value) and String.length(value) >= 4 do
      errors
    else
      Map.put(errors, key, message)
    end
  end

  defp maybe_put_due_error(errors, {:error, _reason}) do
    Map.put(errors, "due_at", "Enter a valid due date and time.")
  end

  defp maybe_put_due_error(errors, {:ok, _due_at}), do: errors

  defp new_todo_error(errors, key) when is_map(errors), do: Map.get(errors, key)
  defp new_todo_error(_errors, _key), do: nil

  defp normalize_new_todo_priority(value) when value in ~w(50 75 90), do: value
  defp normalize_new_todo_priority(_value), do: "50"

  defp parse_new_todo_due_at(nil, _timezone_info), do: {:ok, nil}
  defp parse_new_todo_due_at("", _timezone_info), do: {:ok, nil}

  defp parse_new_todo_due_at(value, timezone_info) when is_binary(value) do
    value
    |> normalize_datetime_local_value()
    |> NaiveDateTime.from_iso8601()
    |> case do
      {:ok, naive_datetime} -> {:ok, local_naive_to_utc(naive_datetime, timezone_info)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp parse_new_todo_due_at(_value, _timezone_info), do: {:error, :invalid_due_at}

  defp normalize_datetime_local_value(value) do
    value = String.trim(value)

    if Regex.match?(~r/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}$/, value) do
      value <> ":00"
    else
      value
    end
  end

  defp local_naive_to_utc(%NaiveDateTime{} = naive_datetime, timezone_info) do
    timezone_info = normalize_timezone_info(timezone_info)

    local_datetime =
      DateTime.new!(
        NaiveDateTime.to_date(naive_datetime),
        NaiveDateTime.to_time(naive_datetime),
        "Etc/UTC"
      )

    offset =
      Timezones.offset_for_local(timezone_info.name, local_datetime, timezone_info.offset_hours)

    DateTime.add(local_datetime, -offset, :hour)
  end

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

  defp selected_todo_for_user(_user_id, nil), do: nil
  defp selected_todo_for_user(_user_id, ""), do: nil

  defp selected_todo_for_user(user_id, todo_id)
       when is_binary(user_id) and is_binary(todo_id) do
    case Todos.get_for_user(user_id, todo_id) do
      %Todo{} = todo -> todo
      _other -> nil
    end
  end

  defp selected_todo_for_user(_user_id, _todo_id), do: nil

  defp todo_query_opts(filters, timezone_info) do
    [
      limit: @page_limit,
      query: normalize_text(filters["q"]),
      statuses: status_filter(filters["status"]),
      attention_mode: attention_filter(filters["attention"]),
      decision_only?: decision_filter?(filters["attention"]),
      source: source_filter(filters["source"]),
      project_id: project_filter(filters["project"]),
      agent_actionability: agent_filter(filters["agent"]),
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

  defp project_filter(value) when value in [nil, "", "all"], do: nil
  defp project_filter("inbox"), do: "inbox"

  defp project_filter(value) when is_binary(value) do
    case Ecto.UUID.cast(value) do
      {:ok, uuid} -> uuid
      :error -> nil
    end
  end

  defp project_filter(_value), do: nil

  defp agent_filter("can_help"), do: "can_help"
  defp agent_filter("needs_you"), do: "needs_you"
  defp agent_filter(_value), do: nil

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
      "project" => normalize_project_filter(Map.get(params, "project")),
      "agent" => normalize_choice(Map.get(params, "agent"), ~w(all can_help needs_you), "all"),
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

  defp normalize_project_filter(value) when value in [nil, ""], do: "all"
  defp normalize_project_filter(value) when value in ["all", "inbox"], do: value

  defp normalize_project_filter(value) when is_binary(value) do
    case Ecto.UUID.cast(String.trim(value)) do
      {:ok, uuid} -> uuid
      :error -> "all"
    end
  end

  defp normalize_project_filter(_value), do: "all"

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

  defp todo_detail_path(filters, todo_id) do
    query =
      filters
      |> Enum.reject(fn {key, value} ->
        blank?(value) or Map.get(@default_filters, key) == value
      end)
      |> Enum.into(%{})

    if map_size(query) == 0,
      do: ~p"/todos/#{todo_id}",
      else: ~p"/todos/#{todo_id}?#{query}"
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
      %{label: "Suggested project", value: todo_project_suggestion(todo)},
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

  # Context renders for every open todo, not only decision-flagged ones —
  # the detail panel is the web counterpart of the mobile work-item view.
  defp todo_decision_review_fields(%Todo{} = todo) do
    if todo.status in ["open", "snoozed"] or todo_decision_signal?(todo) do
      card = ActionCards.for_todo(todo, include_disconnected: true)
      context = Map.get(card, "context_pack") || %{}

      core_fields = [
        %{label: "Decision", value: Map.get(card, "decision_prompt")},
        %{label: "Recommended move", value: Map.get(card, "next_best_action")},
        %{label: "Suggested reply", value: ActionCards.draft_preview(card)},
        %{label: "Why now", value: Map.get(card, "why_now")},
        %{label: "What this is based on", value: ActionCards.evidence_excerpt(card)},
        %{
          label: "Sources checked",
          value: ActionCards.source_health_note(card) || todo_source_check_value(todo)
        },
        %{label: "Prepared action", value: ActionCards.prepared_action_hint(card)},
        %{label: "Person and thread", value: Map.get(context, "summary")}
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

  defp todo_project_suggestion(%Todo{metadata: metadata}) when is_map(metadata) do
    case fetch_map_value(metadata, "project_suggestion") do
      suggestion when is_map(suggestion) ->
        name = fetch_map_value(suggestion, "name")
        evidence = fetch_map_value(suggestion, "evidence")

        [name, evidence]
        |> Enum.filter(&present?/1)
        |> Enum.join(" — ")
        |> normalize_text()

      _other ->
        nil
    end
  end

  defp todo_project_suggestion(_todo), do: nil

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
      option_label(@source_options, filters["source"]),
      project_filter_label(filters["project"]),
      option_label(@agent_options, filters["agent"])
    ]
    |> Enum.reject(&(&1 in [nil, "Any attention", "Any due date", "All sources", "Any helper"]))
    |> case do
      [] -> "Default view"
      labels -> Enum.join(labels, " / ")
    end
  end

  defp project_filter_label("all"), do: nil
  defp project_filter_label("inbox"), do: "Inbox"
  defp project_filter_label(value) when is_binary(value), do: "Project"
  defp project_filter_label(_value), do: nil

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

  defp todo_project_name(%Todo{project_id: nil}, _projects), do: "Inbox"

  defp todo_project_name(%Todo{project_id: project_id}, projects) do
    case Enum.find(projects, &(&1.id == project_id)) do
      nil -> "Project unavailable"
      project -> project.name
    end
  end

  defp agent_actionability_label(%Todo{agent_action_label: label})
       when is_binary(label) and label != "",
       do: label

  defp agent_actionability_label(%Todo{agent_actionability: "can_prepare"}),
    do: "Maraithon can prepare"

  defp agent_actionability_label(%Todo{agent_actionability: "can_execute"}),
    do: "Maraithon can execute"

  defp agent_actionability_label(_todo), do: "Needs you"

  defp agent_actionability_color("can_prepare"), do: "blue"
  defp agent_actionability_color("can_execute"), do: "emerald"
  defp agent_actionability_color(_value), do: "zinc"

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
    if todo_decision_signal?(todo), do: "Recommended", else: "Next"
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
