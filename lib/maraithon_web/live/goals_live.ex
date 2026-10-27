defmodule MaraithonWeb.GoalsLive do
  use MaraithonWeb, :live_view

  alias Maraithon.Goals
  alias Maraithon.Goals.Goal
  alias MaraithonWeb.LocalTime

  @statuses ~w(active paused achieved archived all)
  @categories ~w(all work person health_fitness life)
  @sensitivities ~w(standard sensitive private)
  @visibilities ~w(full summary none)
  @cadences ~w(daily weekly monthly manual)
  @progress_states ~w(on_track at_risk blocked stale achieved unknown)
  @default_filters %{"q" => "", "status" => "active", "category" => "all"}
  @default_goal_params %{
    "title" => "",
    "category" => "work",
    "desired_outcome" => "",
    "why" => "",
    "success_metric" => "",
    "target_at" => "",
    "review_cadence" => "weekly",
    "priority" => "50",
    "sensitivity" => "standard",
    "proactive_visibility" => "summary"
  }
  @default_progress_params %{
    "summary" => "",
    "progress_state" => "unknown"
  }

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: "Goals",
       current_path: "/goals",
       filters: @default_filters,
       filter_form: to_form(@default_filters, as: :filters),
       goals: [],
       selected_goal: nil,
       selected_goal_id: nil,
       new_goal_form: new_goal_form(@default_goal_params),
       edit_goal_form: nil,
       progress_form: progress_form(@default_progress_params),
       new_goal_errors: %{},
       edit_goal_errors: %{},
       progress_errors: %{},
       statuses: @statuses,
       categories: @categories,
       sensitivities: @sensitivities,
       visibilities: @visibilities,
       cadences: @cadences,
       progress_states: @progress_states,
       timezone_info: LocalTime.timezone_info_for_user(current_user_id(socket))
     )}
  end

  @impl true
  def handle_params(params, uri, socket) do
    filters = normalize_filters(params)
    selected_goal_id = normalize_text(Map.get(params, "id"))

    socket =
      socket
      |> assign(:current_path, current_path_from_uri(uri))
      |> assign(:filters, filters)
      |> assign(:filter_form, to_form(filters, as: :filters))
      |> assign(:selected_goal_id, selected_goal_id)
      |> refresh_goals()

    {:noreply, socket}
  end

  @impl true
  def handle_event("update_filters", %{"filters" => filters}, socket) do
    {:noreply, push_patch(socket, to: goals_path(normalize_filters(filters)))}
  end

  def handle_event("clear_filters", _params, socket) do
    {:noreply, push_patch(socket, to: goals_path(@default_filters))}
  end

  def handle_event("select_goal", %{"id" => goal_id}, socket) do
    {:noreply, push_patch(socket, to: goals_path(socket.assigns.filters, %{"id" => goal_id}))}
  end

  def handle_event("create_goal", %{"goal" => params}, socket) do
    user_id = current_user_id(socket)
    params = normalize_goal_form_params(params)

    case Goals.create_goal(user_id, params) do
      {:ok, goal} ->
        {:noreply,
         socket
         |> assign(:new_goal_form, new_goal_form(@default_goal_params))
         |> assign(:new_goal_errors, %{})
         |> put_flash(:info, "Goal saved.")
         |> push_patch(to: goals_path(@default_filters, %{"id" => goal.id}))}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply,
         socket
         |> assign(:new_goal_form, new_goal_form(params))
         |> assign(:new_goal_errors, errors_on(changeset))
         |> put_flash(:error, "Check the goal details and try again.")}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Goal was not saved.")}
    end
  end

  def handle_event("update_goal", %{"goal" => params}, socket) do
    case socket.assigns.selected_goal do
      %Goal{} = goal ->
        params = normalize_goal_form_params(params)

        case Goals.update_goal(current_user_id(socket), goal.id, params) do
          {:ok, _goal} ->
            {:noreply,
             socket
             |> put_flash(:info, "Goal updated.")
             |> assign(:edit_goal_errors, %{})
             |> refresh_goals()}

          {:error, %Ecto.Changeset{} = changeset} ->
            {:noreply,
             socket
             |> assign(:edit_goal_form, edit_goal_form(params))
             |> assign(:edit_goal_errors, errors_on(changeset))
             |> put_flash(:error, "Check the goal details and try again.")}

          {:error, _reason} ->
            {:noreply, put_flash(socket, :error, "Goal was not updated.")}
        end

      nil ->
        {:noreply, put_flash(socket, :error, "Select a goal before editing it.")}
    end
  end

  def handle_event("archive_goal", %{"id" => goal_id}, socket) do
    case Goals.delete_goal(current_user_id(socket), goal_id) do
      {:ok, _goal} ->
        {:noreply,
         socket
         |> put_flash(:info, "Goal archived.")
         |> push_patch(to: goals_path(socket.assigns.filters))}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Goal was not archived.")}
    end
  end

  def handle_event("record_progress", %{"progress" => params}, socket) do
    case socket.assigns.selected_goal do
      %Goal{} = goal ->
        params = normalize_progress_params(params)

        case Goals.record_progress(current_user_id(socket), goal.id, params) do
          {:ok, _progress_update} ->
            {:noreply,
             socket
             |> assign(:progress_form, progress_form(@default_progress_params))
             |> assign(:progress_errors, %{})
             |> put_flash(:info, "Progress saved.")
             |> refresh_goals()}

          {:error, %Ecto.Changeset{} = changeset} ->
            {:noreply,
             socket
             |> assign(:progress_form, progress_form(params))
             |> assign(:progress_errors, errors_on(changeset))
             |> put_flash(:error, "Check the progress note and try again.")}

          {:error, _reason} ->
            {:noreply, put_flash(socket, :error, "Progress was not saved.")}
        end

      nil ->
        {:noreply, put_flash(socket, :error, "Select a goal before adding progress.")}
    end
  end

  def handle_event("review_goal", %{"id" => goal_id}, socket) do
    case Goals.review_goal_alignment(current_user_id(socket), goal_id: goal_id, trigger: "manual") do
      {:ok, _review_run} ->
        {:noreply,
         socket
         |> put_flash(:info, "Goal review recorded.")
         |> refresh_goals()}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Goal review was not recorded.")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_path={@current_path} current_user={@current_user}>
      <div class="space-y-6">
        <.page_header
          title="Goals"
          subtitle="Durable outcomes Maraithon should consider when it briefs, prioritizes, and saves next moves."
        />

        <.panel body_class="px-5 py-4">
          <.form
            for={@filter_form}
            id="goal-filters"
            phx-change="update_filters"
            phx-submit="update_filters"
            class="grid gap-4 md:grid-cols-[minmax(16rem,1fr)_10rem_12rem_auto]"
          >
            <.field label="Search" for={@filter_form[:q].id}>
              <.c_input
                id={@filter_form[:q].id}
                name={@filter_form[:q].name}
                value={@filter_form[:q].value}
                placeholder="Search goals"
              />
            </.field>
            <.field label="Status" for={@filter_form[:status].id}>
              <.c_select id={@filter_form[:status].id} name={@filter_form[:status].name} value={@filter_form[:status].value}>
                <option :for={status <- @statuses} value={status} selected={@filter_form[:status].value == status}>
                  <%= label(status) %>
                </option>
              </.c_select>
            </.field>
            <.field label="Category" for={@filter_form[:category].id}>
              <.c_select id={@filter_form[:category].id} name={@filter_form[:category].name} value={@filter_form[:category].value}>
                <option :for={category <- @categories} value={category} selected={@filter_form[:category].value == category}>
                  <%= category_label(category) %>
                </option>
              </.c_select>
            </.field>
            <div class="flex items-end">
              <.button type="button" variant="outline" phx-click="clear_filters">Reset</.button>
            </div>
          </.form>
        </.panel>

        <div class="grid gap-6 xl:grid-cols-[minmax(0,1fr)_24rem]">
          <div class="space-y-6">
            <.panel body_class="px-5 py-4">
              <:header>
                <div>
                  <h2 class="text-sm/6 font-semibold text-zinc-950">New goal</h2>
                  <p class="text-sm/6 text-zinc-500">Save the outcome Maraithon should keep in view.</p>
                </div>
              </:header>

              <.goal_form
                form={@new_goal_form}
                errors={@new_goal_errors}
                id="new-goal-form"
                dom_id="new-goal"
                submit="create_goal"
                submit_label="Save goal"
                categories={@categories -- ["all"]}
                sensitivities={@sensitivities}
                visibilities={@visibilities}
                cadences={@cadences}
              />
            </.panel>

            <.panel body_class="px-5 py-0">
              <:header>
                <div class="flex items-center justify-between gap-3">
                  <div>
                    <h2 class="text-sm/6 font-semibold text-zinc-950">Saved goals</h2>
                    <p class="text-sm/6 text-zinc-500"><%= length(@goals) %> goals shown</p>
                  </div>
                </div>
              </:header>

              <.table>
                <.table_head>
                  <.table_row>
                    <.table_header>Goal</.table_header>
                    <.table_header>Category</.table_header>
                    <.table_header>Status</.table_header>
                    <.table_header>Next review</.table_header>
                    <.table_header class="text-right">Linked work</.table_header>
                  </.table_row>
                </.table_head>
                <.table_body>
                  <.table_row :if={@goals == []}>
                    <.table_cell colspan="5" class="py-10 text-center text-sm/6 text-zinc-500">
                      <p class="font-medium text-zinc-700"><%= empty_title(@filters) %></p>
                      <p class="mt-1"><%= empty_body(@filters) %></p>
                    </.table_cell>
                  </.table_row>
                  <.table_row
                    :for={goal <- @goals}
                    id={"goal-#{goal.id}"}
                    phx-click="select_goal"
                    phx-value-id={goal.id}
                    class={goal_row_class(@selected_goal_id == goal.id)}
                  >
                    <.table_cell class="max-w-lg whitespace-normal">
                      <div class="font-medium text-zinc-950"><%= goal.title %></div>
                      <div class="mt-1 line-clamp-2 text-sm/6 text-zinc-500">
                        <%= goal.desired_outcome %>
                      </div>
                      <div :if={latest_progress(goal)} class="mt-2 text-xs/5 text-zinc-500">
                        <%= latest_progress(goal).summary %>
                      </div>
                    </.table_cell>
                    <.table_cell>
                      <.badge color={category_color(goal.category)}><%= category_label(goal.category) %></.badge>
                    </.table_cell>
                    <.table_cell>
                      <.badge color={status_color(goal.status)}><%= label(goal.status) %></.badge>
                    </.table_cell>
                    <.table_cell>
                      <span class={review_due?(goal) && "font-medium text-amber-700"}>
                        <%= format_datetime(goal.next_review_at, "Manual", @timezone_info) %>
                      </span>
                    </.table_cell>
                    <.table_cell class="text-right">
                      <%= goal_link_count(goal, "todo") %>
                    </.table_cell>
                  </.table_row>
                </.table_body>
              </.table>
            </.panel>
          </div>

          <div class="space-y-6">
            <.panel :if={!@selected_goal} body_class="px-5 py-6">
              <h2 class="text-sm/6 font-semibold text-zinc-950">No goal selected</h2>
              <p class="mt-1 text-sm/6 text-zinc-500">Choose a row to edit details, add progress, or run a review.</p>
            </.panel>

            <.panel :if={@selected_goal} id="goal-detail">
              <:header>
                <div class="flex items-start justify-between gap-3">
                  <div>
                    <h2 class="text-sm/6 font-semibold text-zinc-950"><%= @selected_goal.title %></h2>
                    <p class="text-sm/6 text-zinc-500"><%= category_label(@selected_goal.category) %> goal</p>
                  </div>
                  <.badge color={sensitivity_color(@selected_goal.sensitivity)}>
                    <%= label(@selected_goal.sensitivity) %>
                  </.badge>
                </div>
              </:header>

              <div class="space-y-6">
                <section>
                  <div class="flex items-center justify-between gap-3">
                    <h3 class="text-sm/6 font-medium text-zinc-950">Current next move</h3>
                    <.button
                      type="button"
                      variant="outline"
                      phx-click="review_goal"
                      phx-value-id={@selected_goal.id}
                    >
                      Review now
                    </.button>
                  </div>
                  <p class="mt-2 text-sm/6 text-zinc-600">
                    <%= next_move_copy(@selected_goal) %>
                  </p>
                </section>

                <section>
                  <h3 class="text-sm/6 font-medium text-zinc-950">Details</h3>
                  <.goal_form
                    form={@edit_goal_form}
                    errors={@edit_goal_errors}
                    id="edit-goal-form"
                    dom_id="edit-goal"
                    submit="update_goal"
                    submit_label="Update goal"
                    categories={@categories -- ["all"]}
                    sensitivities={@sensitivities}
                    visibilities={@visibilities}
                    cadences={@cadences}
                  />
                  <div class="mt-3">
                    <.button
                      type="button"
                      variant="outline"
                      phx-click="archive_goal"
                      phx-value-id={@selected_goal.id}
                    >
                      Archive goal
                    </.button>
                  </div>
                </section>

                <section>
                  <h3 class="text-sm/6 font-medium text-zinc-950">Progress</h3>
                  <.form
                    for={@progress_form}
                    id="goal-progress-form"
                    phx-submit="record_progress"
                    class="mt-3 space-y-3"
                  >
                    <.field label="Progress note" error={error_for(@progress_errors, :summary)}>
                      <.c_textarea
                        id={@progress_form[:summary].id}
                        name={@progress_form[:summary].name}
                        value={@progress_form[:summary].value}
                        rows={3}
                        maxlength="2000"
                        required
                      />
                    </.field>
                    <.field label="State" error={error_for(@progress_errors, :progress_state)}>
                      <.c_select
                        id={@progress_form[:progress_state].id}
                        name={@progress_form[:progress_state].name}
                        value={@progress_form[:progress_state].value}
                      >
                        <option :for={state <- @progress_states} value={state} selected={@progress_form[:progress_state].value == state}>
                          <%= label(state) %>
                        </option>
                      </.c_select>
                    </.field>
                    <.button type="submit">Save progress</.button>
                  </.form>

                  <ol class="mt-4 divide-y divide-zinc-950/5 rounded-lg border border-zinc-950/10">
                    <li :if={progress_updates(@selected_goal) == []} class="px-3 py-3 text-sm/6 text-zinc-500">
                      No progress recorded yet.
                    </li>
                    <li :for={update <- progress_updates(@selected_goal)} class="px-3 py-3 text-sm/6">
                      <div class="flex items-center justify-between gap-3">
                        <.badge color={progress_color(update.progress_state)}><%= label(update.progress_state) %></.badge>
                        <span class="text-xs/5 text-zinc-500"><%= format_datetime(update.occurred_at, "Recently", @timezone_info) %></span>
                      </div>
                      <p class="mt-2 text-zinc-700"><%= update.summary %></p>
                    </li>
                  </ol>
                </section>

                <section>
                  <h3 class="text-sm/6 font-medium text-zinc-950">Links and reviews</h3>
                  <dl class="mt-2 grid grid-cols-2 gap-3 text-sm/6">
                    <div class="rounded-lg border border-zinc-950/10 px-3 py-2">
                      <dt class="text-zinc-500">Work</dt>
                      <dd class="font-medium text-zinc-950"><%= goal_link_count(@selected_goal, "todo") %></dd>
                    </div>
                    <div class="rounded-lg border border-zinc-950/10 px-3 py-2">
                      <dt class="text-zinc-500">People</dt>
                      <dd class="font-medium text-zinc-950"><%= goal_link_count(@selected_goal, "person") %></dd>
                    </div>
                  </dl>
                  <ol class="mt-4 divide-y divide-zinc-950/5 rounded-lg border border-zinc-950/10">
                    <li :if={review_runs(@selected_goal) == []} class="px-3 py-3 text-sm/6 text-zinc-500">
                      No goal reviews recorded yet.
                    </li>
                    <li :for={run <- review_runs(@selected_goal)} class="px-3 py-3 text-sm/6">
                      <div class="flex items-center justify-between gap-3">
                        <.badge color={review_status_color(run.status)}><%= label(run.status) %></.badge>
                        <span class="text-xs/5 text-zinc-500"><%= format_datetime(run.started_at, "Recently", @timezone_info) %></span>
                      </div>
                      <p class="mt-1 text-zinc-600"><%= review_result_summary(run) %></p>
                    </li>
                  </ol>
                </section>
              </div>
            </.panel>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end

  attr :form, :any, required: true
  attr :errors, :map, required: true
  attr :id, :string, required: true
  attr :dom_id, :string, required: true
  attr :submit, :string, required: true
  attr :submit_label, :string, required: true
  attr :categories, :list, required: true
  attr :sensitivities, :list, required: true
  attr :visibilities, :list, required: true
  attr :cadences, :list, required: true

  defp goal_form(assigns) do
    ~H"""
    <.form for={@form} id={@id} phx-submit={@submit} class="space-y-4">
      <div class="grid gap-4 md:grid-cols-2">
        <.field label="Title" for={goal_field_id(@dom_id, :title)} error={error_for(@errors, :title)}>
          <.c_input
            id={goal_field_id(@dom_id, :title)}
            name={@form[:title].name}
            value={@form[:title].value}
            maxlength="240"
            required
          />
        </.field>
        <.field label="Category" for={goal_field_id(@dom_id, :category)} error={error_for(@errors, :category)}>
          <.c_select id={goal_field_id(@dom_id, :category)} name={@form[:category].name} value={@form[:category].value}>
            <option :for={category <- @categories} value={category} selected={@form[:category].value == category}>
              <%= category_label(category) %>
            </option>
          </.c_select>
        </.field>
      </div>

      <.field label="Desired outcome" for={goal_field_id(@dom_id, :desired_outcome)} error={error_for(@errors, :desired_outcome)}>
        <.c_textarea
          id={goal_field_id(@dom_id, :desired_outcome)}
          name={@form[:desired_outcome].name}
          value={@form[:desired_outcome].value}
          rows={3}
          maxlength="2000"
          required
        />
      </.field>

      <div class="grid gap-4 md:grid-cols-2">
        <.field label="Why" for={goal_field_id(@dom_id, :why)} error={error_for(@errors, :why)}>
          <.c_textarea
            id={goal_field_id(@dom_id, :why)}
            name={@form[:why].name}
            value={@form[:why].value}
            rows={3}
            maxlength="2000"
          />
        </.field>
        <.field label="Success metric" for={goal_field_id(@dom_id, :success_metric)} error={error_for(@errors, :success_metric)}>
          <.c_textarea
            id={goal_field_id(@dom_id, :success_metric)}
            name={@form[:success_metric].name}
            value={@form[:success_metric].value}
            rows={3}
            maxlength="2000"
          />
        </.field>
      </div>

      <div class="grid gap-4 md:grid-cols-2 xl:grid-cols-4">
        <.field label="Priority" for={goal_field_id(@dom_id, :priority)} error={error_for(@errors, :priority)}>
          <.c_input id={goal_field_id(@dom_id, :priority)} name={@form[:priority].name} type="number" min="0" max="100" value={@form[:priority].value} />
        </.field>
        <.field label="Review" for={goal_field_id(@dom_id, :review_cadence)} error={error_for(@errors, :review_cadence)}>
          <.c_select id={goal_field_id(@dom_id, :review_cadence)} name={@form[:review_cadence].name} value={@form[:review_cadence].value}>
            <option :for={cadence <- @cadences} value={cadence} selected={@form[:review_cadence].value == cadence}>
              <%= label(cadence) %>
            </option>
          </.c_select>
        </.field>
        <.field label="Sensitivity" for={goal_field_id(@dom_id, :sensitivity)} error={error_for(@errors, :sensitivity)}>
          <.c_select id={goal_field_id(@dom_id, :sensitivity)} name={@form[:sensitivity].name} value={@form[:sensitivity].value}>
            <option :for={sensitivity <- @sensitivities} value={sensitivity} selected={@form[:sensitivity].value == sensitivity}>
              <%= label(sensitivity) %>
            </option>
          </.c_select>
        </.field>
        <.field label="Visibility" for={goal_field_id(@dom_id, :proactive_visibility)} error={error_for(@errors, :proactive_visibility)}>
          <.c_select id={goal_field_id(@dom_id, :proactive_visibility)} name={@form[:proactive_visibility].name} value={@form[:proactive_visibility].value}>
            <option :for={visibility <- @visibilities} value={visibility} selected={@form[:proactive_visibility].value == visibility}>
              <%= label(visibility) %>
            </option>
          </.c_select>
        </.field>
      </div>

      <.field label="Target date" for={goal_field_id(@dom_id, :target_at)} error={error_for(@errors, :target_at)}>
        <.c_input id={goal_field_id(@dom_id, :target_at)} name={@form[:target_at].name} type="date" value={@form[:target_at].value} />
      </.field>

      <.button type="submit"><%= @submit_label %></.button>
    </.form>
    """
  end

  defp refresh_goals(socket) do
    user_id = current_user_id(socket)
    filters = socket.assigns.filters

    goals =
      Goals.list_goals(user_id,
        status: filters["status"],
        category: filters["category"],
        query: filters["q"],
        limit: 200
      )

    selected_goal =
      case socket.assigns.selected_goal_id do
        nil -> nil
        id -> Goals.get_goal(user_id, id)
      end

    socket
    |> assign(:goals, goals)
    |> assign(:selected_goal, selected_goal)
    |> assign(:edit_goal_form, edit_goal_form(goal_form_params(selected_goal)))
  end

  defp new_goal_form(params), do: to_form(params, as: :goal, id: "new_goal")
  defp edit_goal_form(params), do: to_form(params, as: :goal, id: "edit_goal")
  defp progress_form(params), do: to_form(params, as: :progress, id: "goal_progress")

  defp normalize_filters(params) do
    %{
      "q" => normalize_text(Map.get(params, "q")) || "",
      "status" => normalize_choice(Map.get(params, "status"), @statuses, "active"),
      "category" => normalize_choice(Map.get(params, "category"), @categories, "all")
    }
  end

  defp normalize_goal_form_params(params) do
    params
    |> Map.take(Map.keys(@default_goal_params))
    |> Map.update("priority", "50", &to_string/1)
    |> normalize_target_date()
  end

  defp normalize_progress_params(params) do
    params
    |> Map.take(Map.keys(@default_progress_params))
    |> Map.put_new("source", "manual")
  end

  defp normalize_target_date(%{"target_at" => value} = params) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} ->
        {:ok, datetime} = DateTime.new(date, ~T[12:00:00], "Etc/UTC")
        Map.put(params, "target_at", datetime)

      _other ->
        Map.delete(params, "target_at")
    end
  end

  defp normalize_target_date(params), do: params

  defp goal_form_params(nil), do: @default_goal_params

  defp goal_form_params(%Goal{} = goal) do
    %{
      "title" => goal.title,
      "category" => goal.category,
      "desired_outcome" => goal.desired_outcome,
      "why" => goal.why || "",
      "success_metric" => goal.success_metric || "",
      "target_at" => target_date_value(goal.target_at),
      "review_cadence" => goal.review_cadence,
      "priority" => to_string(goal.priority || 50),
      "sensitivity" => goal.sensitivity,
      "proactive_visibility" => goal.proactive_visibility,
      "status" => goal.status
    }
  end

  defp target_date_value(%DateTime{} = datetime),
    do: datetime |> DateTime.to_date() |> Date.to_iso8601()

  defp target_date_value(_value), do: ""

  defp progress_updates(%Goal{progress_updates: updates}) when is_list(updates), do: updates
  defp progress_updates(_goal), do: []

  defp review_runs(%Goal{review_runs: runs}) when is_list(runs), do: runs
  defp review_runs(_goal), do: []

  defp goal_links(%Goal{links: links}) when is_list(links), do: links
  defp goal_links(_goal), do: []

  defp latest_progress(%Goal{} = goal) do
    goal
    |> progress_updates()
    |> List.first()
  end

  defp goal_link_count(%Goal{} = goal, resource_type) do
    goal
    |> goal_links()
    |> Enum.count(&(&1.resource_type == resource_type))
  end

  defp next_move_copy(%Goal{} = goal) do
    work_count = goal_link_count(goal, "todo")

    cond do
      work_count > 0 ->
        "#{work_count} linked work #{plural(work_count, "item", "items")} saved for this goal."

      goal.status == "active" ->
        "No next move saved yet. Add progress or run a review when you want Maraithon to look for one."

      true ->
        "This goal is #{label(goal.status)}; proactive review is paused."
    end
  end

  defp review_result_summary(run) do
    result = run.result || %{}

    cond do
      is_integer(result["todos_count"]) and result["todos_count"] > 0 ->
        "#{result["todos_count"]} linked next #{plural(result["todos_count"], "move", "moves")} saved."

      is_integer(result["goals_checked"]) ->
        "#{result["goals_checked"]} #{plural(result["goals_checked"], "goal", "goals")} checked."

      true ->
        "Review run recorded."
    end
  end

  defp review_due?(%Goal{next_review_at: %DateTime{} = next_review_at, status: "active"}) do
    DateTime.compare(next_review_at, DateTime.utc_now()) in [:lt, :eq]
  end

  defp review_due?(_goal), do: false

  defp goal_row_class(true), do: "cursor-pointer bg-zinc-50 hover:bg-zinc-50"
  defp goal_row_class(_selected?), do: "cursor-pointer hover:bg-zinc-50"

  defp empty_title(filters) do
    if default_filters?(filters), do: "No goals saved yet.", else: "No goals match these filters."
  end

  defp empty_body(filters) do
    if default_filters?(filters) do
      "Add a work, person, health, or life goal so Maraithon can keep the right outcomes in view."
    else
      "Reset filters or search for a different outcome."
    end
  end

  defp default_filters?(filters) do
    normalize_text(filters["q"]) in [nil, ""] and filters["status"] == "active" and
      filters["category"] == "all"
  end

  defp label(value) when is_binary(value) do
    value
    |> String.replace("_", " ")
    |> String.capitalize()
  end

  defp label(value), do: to_string(value)

  defp category_label("health_fitness"), do: "Health and fitness"
  defp category_label("all"), do: "All categories"
  defp category_label(value), do: label(value)

  defp category_color("work"), do: "blue"
  defp category_color("person"), do: "purple"
  defp category_color("health_fitness"), do: "green"
  defp category_color("life"), do: "amber"
  defp category_color(_category), do: "zinc"

  defp status_color("active"), do: "green"
  defp status_color("paused"), do: "amber"
  defp status_color("achieved"), do: "blue"
  defp status_color("archived"), do: "zinc"
  defp status_color(_status), do: "zinc"

  defp sensitivity_color("standard"), do: "zinc"
  defp sensitivity_color("sensitive"), do: "amber"
  defp sensitivity_color("private"), do: "red"
  defp sensitivity_color(_sensitivity), do: "zinc"

  defp progress_color("on_track"), do: "green"
  defp progress_color("at_risk"), do: "amber"
  defp progress_color("blocked"), do: "red"
  defp progress_color("stale"), do: "zinc"
  defp progress_color("achieved"), do: "blue"
  defp progress_color(_state), do: "zinc"

  defp review_status_color("completed"), do: "green"
  defp review_status_color("partial"), do: "amber"
  defp review_status_color("failed"), do: "red"
  defp review_status_color(_status), do: "zinc"

  defp error_for(errors, field) when is_map(errors) do
    case Map.get(errors, field) || Map.get(errors, to_string(field)) do
      [message | _] -> message
      message when is_binary(message) -> message
      _other -> nil
    end
  end

  defp errors_on(%Ecto.Changeset{} = changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end

  defp format_datetime(value, fallback, timezone_info),
    do: LocalTime.format_datetime(value, fallback, timezone_info)

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

  defp plural(1, one, _many), do: one
  defp plural(_count, _one, many), do: many

  defp goal_field_id(dom_id, field), do: "#{dom_id}-#{field}"

  defp goals_path(filters, extra \\ %{}) do
    params =
      filters
      |> Enum.reject(fn
        {"q", ""} -> true
        {"status", "active"} -> true
        {"category", "all"} -> true
        {_key, nil} -> true
        _other -> false
      end)
      |> Map.new()
      |> Map.merge(extra)

    query = URI.encode_query(params)

    if query == "", do: "/goals", else: "/goals?" <> query
  end

  defp current_path_from_uri(uri) do
    uri
    |> URI.parse()
    |> Map.get(:path)
    |> case do
      nil -> "/goals"
      "" -> "/goals"
      path -> path
    end
  end

  defp current_user_id(socket), do: socket.assigns.current_user.id
end
