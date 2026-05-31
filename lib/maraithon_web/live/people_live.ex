defmodule MaraithonWeb.PeopleLive do
  use MaraithonWeb, :live_view

  alias Maraithon.{BriefingSchedules, Crm, Timezones}
  alias Maraithon.Crm.Person
  alias Maraithon.Crm.RelationshipPresentation
  alias Maraithon.Crm.RelationshipPresets
  alias Maraithon.Memory

  @default_filters %{"q" => ""}
  @default_family_member_form %{
    "display_name" => "",
    "preset" => "child",
    "contact_hint" => "",
    "communication_frequency" => "",
    "preferred_communication_method" => "",
    "todo_policy" => "family_logistics_only",
    "push_policy" => "time_sensitive_only",
    "notes" => ""
  }
  @default_family_proxy_form %{
    "display_name" => "",
    "preset" => "school_contact",
    "proxy_for_person_id" => "",
    "contact_hint" => "",
    "preferred_communication_method" => "",
    "todo_policy" => "family_logistics_only",
    "push_policy" => "time_sensitive_only",
    "notes" => ""
  }
  @family_member_presets ~w(spouse_partner child parent sibling extended_family)
  @family_proxy_presets ~w(
    school_contact
    coach_activity_contact
    family_event_organizer
    coparenting_contact
    household_service
    medical_provider
  )
  @todo_policy_options [
    %{value: "family_logistics_only", label: "Logistics only"},
    %{value: "quiet_relationship_support", label: "Quiet support"},
    %{value: "opt_in_rhythm", label: "Opt-in rhythm"}
  ]
  @push_policy_options [
    %{value: "time_sensitive_only", label: "Time-sensitive only"},
    %{value: "digest_only", label: "Digest only"},
    %{value: "never_push", label: "No notifications"}
  ]

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: "People",
       current_path: "/operator/people",
       filters: @default_filters,
       filter_form: to_form(@default_filters, as: :filters),
       people: [],
       family_context_people: [],
       family_onboarding_mode: nil,
       family_member_form: to_form(@default_family_member_form, as: :family_member),
       family_proxy_form: to_form(@default_family_proxy_form, as: :family_proxy),
       selected_person_ids: MapSet.new(),
       selected_person_id: nil,
       selected_person: nil,
       timezone_info: default_timezone_info(),
       bulk_action_menu_open?: false,
       bulk_action_mode: nil,
       bulk_action_anchor: nil,
       bulk_merge_form: to_form(%{"surviving_person_id" => ""}, as: :merge)
     )}
  end

  @impl true
  def handle_params(params, uri, socket) do
    filters = normalize_filters(params)
    selected_person_id = normalize_text(Map.get(params, "person_id"))

    socket =
      socket
      |> assign(:current_path, current_path_from_uri(uri))
      |> assign(:filters, filters)
      |> assign(:filter_form, to_form(filters, as: :filters))
      |> assign(:selected_person_id, selected_person_id)
      |> refresh_people()

    {:noreply, socket}
  end

  @impl true
  def handle_event("update_filters", %{"filters" => filters}, socket) do
    {:noreply, push_patch(socket, to: people_path(normalize_filters(filters)))}
  end

  def handle_event("clear_filters", _params, socket) do
    {:noreply, push_patch(socket, to: ~p"/operator/people")}
  end

  def handle_event("toggle_person_selection", %{"id" => person_id}, socket) do
    selected_person_ids =
      if visible_person_id?(socket, person_id) do
        toggle_mapset_member(socket.assigns.selected_person_ids, person_id)
      else
        socket.assigns.selected_person_ids
      end

    {:noreply, assign_people_selection(socket, selected_person_ids)}
  end

  def handle_event("toggle_all_people", _params, socket) do
    visible_ids = visible_person_ids(socket)

    selected_person_ids =
      if all_visible_people_selected?(socket.assigns.people, socket.assigns.selected_person_ids) do
        MapSet.difference(socket.assigns.selected_person_ids, visible_ids)
      else
        MapSet.union(socket.assigns.selected_person_ids, visible_ids)
      end

    {:noreply, assign_people_selection(socket, selected_person_ids)}
  end

  def handle_event("clear_people_selection", _params, socket) do
    {:noreply, assign_people_selection(socket, MapSet.new())}
  end

  def handle_event("toggle_people_bulk_menu", params, socket) do
    if MapSet.size(socket.assigns.selected_person_ids) > 0 do
      anchor = bulk_action_anchor(Map.get(params, "anchor"), "bottom")

      menu_open? =
        not (socket.assigns.bulk_action_menu_open? and
               socket.assigns.bulk_action_anchor == anchor)

      {:noreply,
       socket
       |> assign(:bulk_action_menu_open?, menu_open?)
       |> assign(:bulk_action_mode, nil)
       |> assign(:bulk_action_anchor, if(menu_open?, do: anchor, else: nil))}
    else
      {:noreply, socket}
    end
  end

  def handle_event("choose_people_bulk_action", %{"action" => "merge"} = params, socket) do
    if MapSet.size(socket.assigns.selected_person_ids) >= 2 do
      {:noreply,
       assign_bulk_action(socket, "merge", bulk_action_anchor(Map.get(params, "anchor")))}
    else
      {:noreply, put_flash(socket, :error, "Select at least two people to merge.")}
    end
  end

  def handle_event("choose_people_bulk_action", %{"action" => "delete"} = params, socket) do
    if MapSet.size(socket.assigns.selected_person_ids) > 0 do
      {:noreply,
       assign_bulk_action(socket, "delete", bulk_action_anchor(Map.get(params, "anchor")))}
    else
      {:noreply, socket}
    end
  end

  def handle_event("choose_people_bulk_action", _params, socket) do
    {:noreply, socket}
  end

  def handle_event("cancel_people_bulk_action", _params, socket) do
    {:noreply, assign_bulk_action(socket, nil)}
  end

  def handle_event("show_people_onboarding", %{"mode" => mode}, socket) do
    {:noreply, assign(socket, :family_onboarding_mode, family_onboarding_mode(mode))}
  end

  def handle_event("cancel_people_onboarding", _params, socket) do
    {:noreply, reset_family_onboarding(socket)}
  end

  def handle_event("create_family_member", %{"family_member" => params}, socket) do
    user_id = current_user_id(socket)

    socket =
      case family_member_attrs(params) do
        {:ok, attrs} ->
          case Crm.upsert_person(user_id, attrs) do
            {:ok, person} ->
              write_family_context_memory(user_id, person)

              socket
              |> put_flash(:info, "Added #{person.display_name} to family context.")
              |> reset_family_onboarding()
              |> refresh_people()

            {:error, reason} ->
              put_flash(socket, :error, onboarding_error(reason))
          end

        {:error, reason} ->
          socket
          |> put_flash(:error, onboarding_error(reason))
          |> assign(:family_onboarding_mode, "member")
          |> assign(:family_member_form, to_family_member_form(params))
      end

    {:noreply, socket}
  end

  def handle_event("create_family_proxy", %{"family_proxy" => params}, socket) do
    user_id = current_user_id(socket)

    socket =
      case family_proxy_attrs(user_id, params) do
        {:ok, attrs} ->
          case Crm.upsert_person(user_id, attrs) do
            {:ok, person} ->
              write_family_context_memory(user_id, person)

              socket
              |> put_flash(:info, "Added #{person.display_name} as family-related context.")
              |> reset_family_onboarding()
              |> refresh_people()

            {:error, reason} ->
              put_flash(socket, :error, onboarding_error(reason))
          end

        {:error, reason} ->
          socket
          |> put_flash(:error, onboarding_error(reason))
          |> assign(:family_onboarding_mode, "proxy")
          |> assign(:family_proxy_form, to_family_proxy_form(params))
      end

    {:noreply, socket}
  end

  def handle_event("open_person_detail", %{"id" => person_id}, socket) do
    if visible_person_id?(socket, person_id) do
      {:noreply,
       push_patch(socket, to: people_path(socket.assigns.filters, %{"person_id" => person_id}))}
    else
      {:noreply, socket}
    end
  end

  def handle_event("save_relationship", %{"relationship" => params}, socket) do
    user_id = current_user_id(socket)

    socket =
      case relationship_attrs(user_id, params) do
        {:ok, attrs} ->
          case Crm.upsert_person(user_id, attrs) do
            {:ok, person} ->
              if family_context_person?(person), do: write_family_context_memory(user_id, person)

              socket
              |> put_flash(:info, "Updated relationship for #{person.display_name}.")
              |> refresh_people()

            {:error, reason} ->
              put_flash(socket, :error, relationship_error(reason))
          end

        {:error, reason} ->
          put_flash(socket, :error, relationship_error(reason))
      end

    {:noreply, socket}
  end

  def handle_event("merge_selected_people", %{"merge" => params}, socket) do
    user_id = current_user_id(socket)
    selected_ids = selected_visible_person_ids(socket)
    surviving_id = normalize_text(Map.get(params, "surviving_person_id"))

    socket =
      case merge_selected_people(user_id, selected_ids, surviving_id) do
        {:ok, survivor, merged_count} ->
          socket
          |> assign(:selected_person_ids, MapSet.new())
          |> put_flash(:info, bulk_merge_flash(survivor, merged_count))
          |> push_patch(to: people_path(socket.assigns.filters, %{"person_id" => survivor.id}))

        {:error, reason} ->
          put_flash(socket, :error, merge_error(reason))
      end

    {:noreply, socket}
  end

  def handle_event("delete_selected_people", _params, socket) do
    user_id = current_user_id(socket)
    selected_ids = selected_visible_person_ids(socket)

    socket =
      case delete_selected_people(user_id, selected_ids) do
        {:ok, deleted_count} ->
          socket
          |> put_flash(:info, delete_people_flash(deleted_count))
          |> assign(:selected_person_ids, MapSet.new())
          |> assign(:selected_person_id, nil)
          |> assign(:selected_person, nil)
          |> assign_bulk_action(nil)
          |> push_patch(to: people_path(socket.assigns.filters))

        {:error, reason} ->
          put_flash(socket, :error, delete_error(reason))
      end

    {:noreply, socket}
  end

  def handle_event("merge_people", %{"merge" => params}, socket) do
    user_id = current_user_id(socket)
    surviving_id = normalize_text(Map.get(params, "surviving_person_id"))
    merged_id = normalize_text(Map.get(params, "merged_person_id"))

    socket =
      case merge_people_from_params(user_id, surviving_id, merged_id) do
        {:ok, surviving, merged} ->
          socket
          |> put_flash(:info, "Merged #{merged.display_name} into #{surviving.display_name}.")
          |> refresh_people()

        {:error, reason} ->
          put_flash(socket, :error, merge_error(reason))
      end

    {:noreply, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_path={@current_path} current_user={@current_user}>
      <div class="space-y-6">
        <.page_header
          title="People"
          subtitle="Relationships Maraithon has learned from connected work and conversations."
        />

        <.family_onboarding
          family_context_people={@family_context_people}
          family_onboarding_mode={@family_onboarding_mode}
          family_member_form={@family_member_form}
          family_proxy_form={@family_proxy_form}
        />

        <.panel body_class="px-5 py-4">
          <.form
            for={@filter_form}
            id="people-filters"
            phx-change="update_filters"
            phx-submit="update_filters"
            class="grid gap-4 md:grid-cols-[minmax(16rem,1fr)_auto]"
          >
            <.field label="Search" for={@filter_form[:q].id}>
              <.c_input
                id={@filter_form[:q].id}
                name={@filter_form[:q].name}
                value={@filter_form[:q].value}
                placeholder="Search people"
              />
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
                <h2 class="text-sm/6 font-semibold text-zinc-950">Relationships</h2>
                <p class="text-sm/6 text-zinc-500">
                  <%= length(@people) %> shown. Select duplicates to merge, or open a person to manage context.
                </p>
              </div>
              <.badge color="zinc">Active</.badge>
            </div>
          </:header>

          <div class={[
            "grid grid-cols-1 gap-4 py-4",
            @selected_person && "xl:grid-cols-[minmax(0,1fr)_26rem]",
            MapSet.size(@selected_person_ids) > 0 && "pb-28"
          ]}>
            <div class="min-w-0">
              <.table>
                <.table_head>
                  <.table_row>
                    <.table_header class="w-10">
                      <input
                        type="checkbox"
                        aria-label="Select all people"
                        checked={all_visible_people_selected?(@people, @selected_person_ids)}
                        phx-click="toggle_all_people"
                        class="size-4 rounded border-zinc-300 text-zinc-900 focus:ring-zinc-900"
                      />
                    </.table_header>
                    <.table_header>Person</.table_header>
                    <.table_header>Relationship</.table_header>
                    <.table_header>Activity</.table_header>
                    <.table_header>Relationship health</.table_header>
                    <.table_header>Status</.table_header>
                  </.table_row>
                </.table_head>
                <.table_body>
                  <.table_row :if={@people == []}>
                    <.table_cell colspan="6" class="py-10 text-center text-sm/6 text-zinc-500">
                      <%= empty_message(@filters) %>
                    </.table_cell>
                  </.table_row>

                  <.table_row
                    :for={person <- @people}
                    id={"person-#{person.id}"}
                    phx-click="open_person_detail"
                    phx-value-id={person.id}
                    class={person_row_class(person, @selected_person_ids, @selected_person_id)}
                  >
                    <.table_cell class="w-10 align-top">
                      <input
                        type="checkbox"
                        aria-label={"Select #{person.display_name}"}
                        checked={MapSet.member?(@selected_person_ids, person.id)}
                        phx-click="toggle_person_selection"
                        phx-value-id={person.id}
                        onclick="event.stopPropagation()"
                        class="size-4 rounded border-zinc-300 text-zinc-900 focus:ring-zinc-900"
                      />
                    </.table_cell>
                    <.table_cell class="max-w-lg whitespace-normal align-top">
                      <div class="font-medium text-zinc-950"><%= person.display_name %></div>
                      <div class="mt-1 text-sm/6 text-zinc-500"><%= contact_preview(person) %></div>
                      <div :if={present?(person.notes)} class="mt-1 line-clamp-1 text-sm/6 text-zinc-600">
                        <%= person.notes %>
                      </div>
                    </.table_cell>
                    <.table_cell class="whitespace-normal align-top">
                      <div class="text-sm/6 text-zinc-950"><%= fallback(person.relationship, "Relationship not set") %></div>
                      <div class="mt-1 flex flex-wrap items-center gap-2 text-xs/5 text-zinc-500">
                        <span><%= communication_frequency(person) %></span>
                        <span :if={present?(person.preferred_communication_method)} aria-hidden="true">·</span>
                        <span :if={present?(person.preferred_communication_method)}>
                          <%= label(person.preferred_communication_method) %>
                        </span>
                      </div>
                    </.table_cell>
                    <.table_cell class="whitespace-normal align-top">
                      <div class="text-sm/6 text-zinc-950"><%= format_datetime(person.last_interaction_at, @timezone_info) %></div>
                      <div class="mt-1 text-xs/5 text-zinc-500">
                        <%= interaction_label(person.interaction_count) %>
                      </div>
                    </.table_cell>
                    <.table_cell class="align-top">
                      <div class="text-sm/6 text-zinc-950">
                        <%= RelationshipPresentation.health_label(person.relationship_strength) %>
                      </div>
                      <div class="mt-1 text-xs/5 text-zinc-500">
                        <%= RelationshipPresentation.warmth_label(person.affinity_score) %>
                      </div>
                    </.table_cell>
                    <.table_cell class="align-top">
                      <.badge color={status_color(person.status)}><%= label(person.status) %></.badge>
                    </.table_cell>
                  </.table_row>
                </.table_body>
              </.table>
            </div>

            <.person_detail_panel :if={@selected_person} person={@selected_person} filters={@filters} timezone_info={@timezone_info} />
          </div>
        </.panel>

        <.people_bulk_action_bar
          people={@people}
          selected_person_ids={@selected_person_ids}
          menu_open?={@bulk_action_menu_open? && @bulk_action_anchor == "bottom"}
          action_mode={anchored_action_mode(@bulk_action_mode, @bulk_action_anchor, "bottom")}
          bulk_merge_form={@bulk_merge_form}
        />
      </div>
    </Layouts.app>
    """
  end

  defp refresh_people(socket) do
    user_id = current_user_id(socket)
    timezone_info = user_timezone_info(user_id)

    people =
      Crm.list_people(user_id,
        query: normalize_text(socket.assigns.filters["q"]),
        limit: 100
      )

    family_context_people = Crm.list_family_context(user_id, limit: 100)
    visible_ids = people |> Enum.map(& &1.id) |> MapSet.new()
    selected_person_ids = MapSet.intersection(socket.assigns.selected_person_ids, visible_ids)
    has_selection? = MapSet.size(selected_person_ids) > 0

    assign(socket,
      people: people,
      family_context_people: family_context_people,
      selected_person_ids: selected_person_ids,
      bulk_action_menu_open?: has_selection? && socket.assigns.bulk_action_menu_open?,
      bulk_action_mode: if(has_selection?, do: socket.assigns.bulk_action_mode, else: nil),
      bulk_action_anchor: if(has_selection?, do: socket.assigns.bulk_action_anchor, else: nil),
      selected_person: selected_person_for_user(user_id, socket.assigns.selected_person_id),
      timezone_info: timezone_info
    )
  end

  attr :family_context_people, :list, required: true
  attr :family_onboarding_mode, :string, default: nil
  attr :family_member_form, :any, required: true
  attr :family_proxy_form, :any, required: true

  defp family_onboarding(assigns) do
    assigns =
      assigns
      |> assign(
        :family_member_count,
        Enum.count(assigns.family_context_people, &family_member?/1)
      )
      |> assign(:family_proxy_count, Enum.count(assigns.family_context_people, &family_proxy?/1))

    ~H"""
    <.panel id="people-family-onboarding" body_class="px-5 py-4">
      <div class="flex flex-wrap items-start justify-between gap-4">
        <div class="min-w-0">
          <div class="flex flex-wrap items-center gap-2">
            <h2 class="text-sm/6 font-semibold text-zinc-950">Family context</h2>
            <.badge color={if @family_context_people == [], do: "amber", else: "blue"}>
              <%= family_context_summary(@family_member_count, @family_proxy_count) %>
            </.badge>
          </div>
          <p class="mt-1 max-w-3xl text-sm/6 text-zinc-500">
            Tell Maraithon who is family so it can separate family logistics from work follow-ups.
          </p>
        </div>
        <div class="flex flex-wrap items-center gap-2">
          <.button
            type="button"
            variant={if @family_onboarding_mode == "member", do: "solid", else: "outline"}
            phx-click="show_people_onboarding"
            phx-value-mode="member"
          >
            Add family member
          </.button>
          <.button
            type="button"
            variant={if @family_onboarding_mode == "proxy", do: "solid", else: "outline"}
            phx-click="show_people_onboarding"
            phx-value-mode="proxy"
          >
            Add school or household contact
          </.button>
        </div>
      </div>

      <div :if={@family_context_people != []} class="mt-4 border-t border-zinc-950/10 pt-4">
        <.table>
          <.table_head>
            <.table_row>
              <.table_header>Person</.table_header>
              <.table_header>Role</.table_header>
              <.table_header>Handling</.table_header>
              <.table_header>Notifications</.table_header>
            </.table_row>
          </.table_head>
          <.table_body>
            <.table_row
              :for={person <- @family_context_people}
              id={"family-context-#{person.id}"}
              phx-click="open_person_detail"
              phx-value-id={person.id}
              class="cursor-pointer transition-colors hover:bg-zinc-950/[0.025]"
            >
              <.table_cell class="max-w-lg whitespace-normal align-top">
                <div class="font-medium text-zinc-950"><%= person.display_name %></div>
                <div class="mt-1 text-xs/5 text-zinc-500"><%= contact_preview(person) %></div>
              </.table_cell>
              <.table_cell class="whitespace-normal align-top">
                <div class="flex flex-wrap items-center gap-2">
                  <.badge color={if family_member?(person), do: "blue", else: "zinc"}>
                    <%= family_context_kind(person) %>
                  </.badge>
                  <span class="text-sm/6 text-zinc-950"><%= family_role_label(person) %></span>
                </div>
                <div :if={proxy_for_label(person, @family_context_people)} class="mt-1 text-xs/5 text-zinc-500">
                  For <%= proxy_for_label(person, @family_context_people) %>
                </div>
              </.table_cell>
              <.table_cell class="whitespace-normal align-top">
                <div class="text-sm/6 text-zinc-950"><%= todo_policy_label(person) %></div>
                <div class="mt-1 text-xs/5 text-zinc-500"><%= communication_frequency(person) %></div>
              </.table_cell>
              <.table_cell class="whitespace-normal align-top">
                <div class="text-sm/6 text-zinc-950"><%= push_policy_label(person) %></div>
                <div :if={present?(person.preferred_communication_method)} class="mt-1 text-xs/5 text-zinc-500">
                  <%= label(person.preferred_communication_method) %>
                </div>
              </.table_cell>
            </.table_row>
          </.table_body>
        </.table>
      </div>

      <div :if={@family_context_people == []} class="mt-4 border-t border-zinc-950/10 pt-4 text-sm/6 text-zinc-500">
        Family context will appear after you add a family member or proxy.
      </div>

      <.family_member_onboarding_form
        :if={@family_onboarding_mode == "member"}
        form={@family_member_form}
      />
      <.family_proxy_onboarding_form
        :if={@family_onboarding_mode == "proxy"}
        form={@family_proxy_form}
        family_context_people={@family_context_people}
      />
    </.panel>
    """
  end

  attr :form, :any, required: true

  defp family_member_onboarding_form(assigns) do
    ~H"""
    <.form
      for={@form}
      id="family-member-onboarding-form"
      phx-submit="create_family_member"
      class="mt-4 border-t border-zinc-950/10 pt-4"
    >
      <div class="grid gap-4 lg:grid-cols-4">
        <.field label="Name" for="family-member-display-name">
          <.c_input
            id="family-member-display-name"
            name={@form[:display_name].name}
            value={@form[:display_name].value}
            required
            placeholder="Jack Fenwick"
          />
        </.field>

        <.field label="Role" for="family-member-preset">
          <.c_select id="family-member-preset" name={@form[:preset].name}>
            <option
              :for={preset <- family_member_preset_options()}
              value={preset.id}
              selected={@form[:preset].value == preset.id}
            >
              <%= preset.label %>
            </option>
          </.c_select>
        </.field>

        <.field label="Handling" for="family-member-todo-policy">
          <.c_select id="family-member-todo-policy" name={@form[:todo_policy].name}>
            <option
              :for={option <- todo_policy_options()}
              value={option.value}
              selected={@form[:todo_policy].value == option.value}
            >
              <%= option.label %>
            </option>
          </.c_select>
        </.field>

        <.field label="Notifications" for="family-member-push-policy">
          <.c_select id="family-member-push-policy" name={@form[:push_policy].name}>
            <option
              :for={option <- push_policy_options()}
              value={option.value}
              selected={@form[:push_policy].value == option.value}
            >
              <%= option.label %>
            </option>
          </.c_select>
        </.field>

        <.field label="Cadence" for="family-member-cadence">
          <.c_select id="family-member-cadence" name={@form[:communication_frequency].name}>
            <option value="">No cadence</option>
            <option
              :for={option <- RelationshipPresets.cadence_options()}
              value={option.value}
              selected={@form[:communication_frequency].value == option.value}
            >
              <%= option.label %>
            </option>
          </.c_select>
        </.field>

        <.field label="Channel" for="family-member-channel">
          <.c_select id="family-member-channel" name={@form[:preferred_communication_method].name}>
            <option value="">No preference</option>
            <option
              :for={option <- RelationshipPresets.channel_options()}
              value={option.value}
              selected={@form[:preferred_communication_method].value == option.value}
            >
              <%= option.label %>
            </option>
          </.c_select>
        </.field>

        <.field label="Contact hint" for="family-member-contact-hint">
          <.c_input
            id="family-member-contact-hint"
            name={@form[:contact_hint].name}
            value={@form[:contact_hint].value}
            placeholder="email or phone"
          />
        </.field>

        <.field label="Context" for="family-member-notes" class="lg:col-span-4">
          <.c_textarea
            id="family-member-notes"
            name={@form[:notes].name}
            value={@form[:notes].value}
            rows={3}
            placeholder="What should Maraithon remember before surfacing this person?"
          />
        </.field>
      </div>

      <div class="mt-4 flex justify-end gap-2">
        <.button type="button" variant="plain" phx-click="cancel_people_onboarding">Cancel</.button>
        <.button type="submit">Save family context</.button>
      </div>
    </.form>
    """
  end

  attr :form, :any, required: true
  attr :family_context_people, :list, required: true

  defp family_proxy_onboarding_form(assigns) do
    assigns =
      assign(
        assigns,
        :family_members,
        Enum.filter(assigns.family_context_people, &family_member?/1)
      )

    ~H"""
    <.form
      for={@form}
      id="family-proxy-onboarding-form"
      phx-submit="create_family_proxy"
      class="mt-4 border-t border-zinc-950/10 pt-4"
    >
      <div class="grid gap-4 lg:grid-cols-4">
        <.field label="Name" for="family-proxy-display-name">
          <.c_input
            id="family-proxy-display-name"
            name={@form[:display_name].name}
            value={@form[:display_name].value}
            required
            placeholder="School office"
          />
        </.field>

        <.field label="Role" for="family-proxy-preset">
          <.c_select id="family-proxy-preset" name={@form[:preset].name}>
            <option
              :for={preset <- family_proxy_preset_options()}
              value={preset.id}
              selected={@form[:preset].value == preset.id}
            >
              <%= preset.label %>
            </option>
          </.c_select>
        </.field>

        <.field label="For" for="family-proxy-for-person">
          <.c_select id="family-proxy-for-person" name={@form[:proxy_for_person_id].name}>
            <option value="">No specific person</option>
            <option
              :for={person <- @family_members}
              value={person.id}
              selected={@form[:proxy_for_person_id].value == person.id}
            >
              <%= person.display_name %>
            </option>
          </.c_select>
        </.field>

        <.field label="Handling" for="family-proxy-todo-policy">
          <.c_select id="family-proxy-todo-policy" name={@form[:todo_policy].name}>
            <option
              :for={option <- todo_policy_options()}
              value={option.value}
              selected={@form[:todo_policy].value == option.value}
            >
              <%= option.label %>
            </option>
          </.c_select>
        </.field>

        <.field label="Notifications" for="family-proxy-push-policy">
          <.c_select id="family-proxy-push-policy" name={@form[:push_policy].name}>
            <option
              :for={option <- push_policy_options()}
              value={option.value}
              selected={@form[:push_policy].value == option.value}
            >
              <%= option.label %>
            </option>
          </.c_select>
        </.field>

        <.field label="Channel" for="family-proxy-channel">
          <.c_select id="family-proxy-channel" name={@form[:preferred_communication_method].name}>
            <option value="">No preference</option>
            <option
              :for={option <- RelationshipPresets.channel_options()}
              value={option.value}
              selected={@form[:preferred_communication_method].value == option.value}
            >
              <%= option.label %>
            </option>
          </.c_select>
        </.field>

        <.field label="Contact hint" for="family-proxy-contact-hint">
          <.c_input
            id="family-proxy-contact-hint"
            name={@form[:contact_hint].name}
            value={@form[:contact_hint].value}
            placeholder="email or phone"
          />
        </.field>

        <.field label="Context" for="family-proxy-notes" class="lg:col-span-4">
          <.c_textarea
            id="family-proxy-notes"
            name={@form[:notes].name}
            value={@form[:notes].value}
            rows={3}
            placeholder="What family logistics should this contact represent?"
          />
        </.field>
      </div>

      <div class="mt-4 flex justify-end gap-2">
        <.button type="button" variant="plain" phx-click="cancel_people_onboarding">Cancel</.button>
        <.button type="submit">Save family contact</.button>
      </div>
    </.form>
    """
  end

  defp family_member_preset_options do
    RelationshipPresets.all()
    |> Enum.filter(&(&1.id in @family_member_presets))
  end

  defp family_proxy_preset_options do
    RelationshipPresets.all()
    |> Enum.filter(&(&1.id in @family_proxy_presets))
  end

  defp todo_policy_options, do: @todo_policy_options
  defp push_policy_options, do: @push_policy_options

  defp family_onboarding_mode("proxy"), do: "proxy"
  defp family_onboarding_mode(_mode), do: "member"

  defp reset_family_onboarding(socket) do
    assign(socket,
      family_onboarding_mode: nil,
      family_member_form: to_family_member_form(%{}),
      family_proxy_form: to_family_proxy_form(%{})
    )
  end

  defp to_family_member_form(params) do
    params
    |> form_values(@default_family_member_form)
    |> to_form(as: :family_member)
  end

  defp to_family_proxy_form(params) do
    params
    |> form_values(@default_family_proxy_form)
    |> to_form(as: :family_proxy)
  end

  defp form_values(params, defaults) when is_map(params) do
    params =
      params
      |> stringify_params()
      |> Map.take(Map.keys(defaults))

    Map.merge(defaults, params)
  end

  defp family_member_attrs(params) do
    params = stringify_params(params)
    display_name = normalize_text(Map.get(params, "display_name"))
    preset_id = normalize_text(Map.get(params, "preset")) || "child"

    with display_name when is_binary(display_name) <- display_name,
         {:ok, preset} <- allowed_preset(preset_id, @family_member_presets) do
      relationship = preset.value

      metadata =
        %{}
        |> relationship_metadata(preset.id, relationship)
        |> Map.merge(%{
          "family_member" => true,
          "family_role" => preset.id,
          "people_onboarding" => true,
          "relationship_context_source" => "people_onboarding",
          "sensitivity" => family_sensitivity(preset.id),
          "todo_policy" => todo_policy_value(params),
          "push_policy" => push_policy_value(params)
        })
        |> maybe_put("dependent_context", if(preset.id == "child", do: true))

      attrs =
        %{
          "display_name" => display_name,
          "relationship" => relationship,
          "metadata" => metadata
        }
        |> maybe_put(
          "communication_frequency",
          normalize_text(Map.get(params, "communication_frequency"))
        )
        |> maybe_put(
          "preferred_communication_method",
          normalize_text(Map.get(params, "preferred_communication_method"))
        )
        |> maybe_put("notes", normalize_text(Map.get(params, "notes")))
        |> maybe_put_contact_hint(params)

      {:ok, attrs}
    else
      nil -> {:error, :missing_display_name}
      {:error, reason} -> {:error, reason}
    end
  end

  defp family_proxy_attrs(user_id, params) do
    params = stringify_params(params)
    display_name = normalize_text(Map.get(params, "display_name"))
    preset_id = normalize_text(Map.get(params, "preset")) || "school_contact"

    with display_name when is_binary(display_name) <- display_name,
         {:ok, preset} <- allowed_preset(preset_id, @family_proxy_presets),
         {:ok, proxy_for_person_id} <- proxy_for_person_id(user_id, params) do
      relationship = preset.value

      metadata =
        %{}
        |> relationship_metadata(preset.id, relationship)
        |> Map.merge(%{
          "relationship_domain" => "family",
          "family_proxy" => true,
          "proxy_role" => preset.id,
          "people_onboarding" => true,
          "relationship_context_source" => "people_onboarding",
          "todo_policy" => todo_policy_value(params),
          "default_todo_policy" => "family_logistics",
          "push_policy" => push_policy_value(params)
        })
        |> maybe_put("proxy_for_person_id", proxy_for_person_id)

      attrs =
        %{
          "display_name" => display_name,
          "relationship" => relationship,
          "metadata" => metadata
        }
        |> maybe_put(
          "preferred_communication_method",
          normalize_text(Map.get(params, "preferred_communication_method"))
        )
        |> maybe_put("notes", normalize_text(Map.get(params, "notes")))
        |> maybe_put_contact_hint(params)

      {:ok, attrs}
    else
      nil -> {:error, :missing_display_name}
      {:error, reason} -> {:error, reason}
    end
  end

  defp allowed_preset(preset_id, allowed_ids) do
    case RelationshipPresets.get(preset_id) do
      nil ->
        {:error, :invalid_relationship_preset}

      preset ->
        if preset.id in allowed_ids,
          do: {:ok, preset},
          else: {:error, :invalid_relationship_preset}
    end
  end

  defp proxy_for_person_id(_user_id, %{"proxy_for_person_id" => ""}), do: {:ok, nil}
  defp proxy_for_person_id(_user_id, %{"proxy_for_person_id" => nil}), do: {:ok, nil}

  defp proxy_for_person_id(user_id, params) do
    case normalize_text(Map.get(params, "proxy_for_person_id")) do
      nil ->
        {:ok, nil}

      person_id ->
        case Crm.get_person_for_user(user_id, person_id) do
          %Person{} = person ->
            if family_member?(person),
              do: {:ok, person.id},
              else: {:error, :proxy_family_member_not_found}

          nil ->
            {:error, :proxy_family_member_not_found}
        end
    end
  end

  defp maybe_put_contact_hint(attrs, params) do
    case normalize_text(Map.get(params, "contact_hint")) do
      nil ->
        attrs

      contact_hint ->
        if String.contains?(contact_hint, "@") do
          Map.put(attrs, "email", contact_hint)
        else
          Map.put(attrs, "phone", contact_hint)
        end
    end
  end

  defp todo_policy_value(params) do
    params
    |> Map.get("todo_policy")
    |> normalize_text()
    |> option_value(@todo_policy_options, "family_logistics_only")
  end

  defp push_policy_value(params) do
    params
    |> Map.get("push_policy")
    |> normalize_text()
    |> option_value(@push_policy_options, "time_sensitive_only")
  end

  defp option_value(value, options, default) do
    values = Enum.map(options, & &1.value)
    if value in values, do: value, else: default
  end

  defp write_family_context_memory(user_id, %Person{} = person) do
    _result =
      Memory.write(
        user_id,
        %{
          "title" => "Family context: #{person.display_name}",
          "content" => family_memory_content(person),
          "kind" => "relationship",
          "scope" => "user",
          "author_type" => "user",
          "source" => "people_onboarding",
          "source_ref_type" => "crm_person",
          "source_ref_id" => person.id,
          "tags" => ["family", "people_onboarding", "todo_policy"],
          "importance" => 86,
          "confidence" => 1.0,
          "dedupe_key" => "people_onboarding:family_context:#{person.id}",
          "metadata" => %{
            "person_id" => person.id,
            "relationship_domain" => metadata_value(person, "relationship_domain"),
            "relationship_preset" => metadata_value(person, "relationship_preset"),
            "family_member" => family_member?(person),
            "family_proxy" => family_proxy?(person),
            "todo_policy" => metadata_value(person, "todo_policy"),
            "push_policy" => metadata_value(person, "push_policy")
          }
        },
        source: "people_onboarding"
      )

    :ok
  rescue
    _exception -> :ok
  end

  defp family_memory_content(%Person{} = person) do
    [
      "#{person.display_name} is #{family_role_label(person)} in #{String.downcase(family_context_kind(person))} context.",
      "Treat items involving #{person.display_name} as family context, not generic work follow-up.",
      "Handling: #{todo_policy_label(person)}.",
      "Notifications: #{push_policy_label(person)}.",
      person.notes
    ]
    |> Enum.filter(&present?/1)
    |> Enum.join(" ")
  end

  defp family_sensitivity("child"), do: "child_family"
  defp family_sensitivity(_preset_id), do: "family"

  defp family_context_summary(0, 0), do: "No family context yet"
  defp family_context_summary(member_count, 0), do: pluralize(member_count, "family member")
  defp family_context_summary(0, proxy_count), do: pluralize(proxy_count, "family contact")

  defp family_context_summary(member_count, proxy_count) do
    "#{pluralize(member_count, "family member")} · #{pluralize(proxy_count, "family contact")}"
  end

  defp family_context_kind(%Person{} = person) do
    if family_member?(person), do: "Family member", else: "Family contact"
  end

  defp family_context_person?(%Person{} = person) do
    metadata_value(person, "relationship_domain") == "family" or family_member?(person) or
      family_proxy?(person)
  end

  defp family_member?(%Person{} = person) do
    truthy?(metadata_value(person, "family_member")) or
      metadata_value(person, "relationship_preset") in @family_member_presets
  end

  defp family_proxy?(%Person{} = person) do
    truthy?(metadata_value(person, "family_proxy")) or
      metadata_value(person, "proxy_role") in @family_proxy_presets
  end

  defp family_role_label(%Person{} = person) do
    preset_id =
      metadata_value(person, "family_role") ||
        metadata_value(person, "proxy_role") ||
        metadata_value(person, "relationship_preset")

    case RelationshipPresets.get(preset_id) do
      nil -> fallback(person.relationship)
      preset -> preset.label
    end
  end

  defp todo_policy_label(%Person{} = person) do
    person
    |> metadata_value("todo_policy")
    |> option_label(@todo_policy_options, "Logistics only")
  end

  defp push_policy_label(%Person{} = person) do
    person
    |> metadata_value("push_policy")
    |> option_label(@push_policy_options, "Time-sensitive only")
  end

  defp option_label(value, options, default) do
    options
    |> Enum.find(&(&1.value == value))
    |> case do
      nil -> default
      option -> option.label
    end
  end

  defp proxy_for_label(%Person{} = person, people) do
    proxy_for_person_id = metadata_value(person, "proxy_for_person_id")

    people
    |> Enum.find(&(&1.id == proxy_for_person_id))
    |> case do
      %Person{} = proxy_for -> proxy_for.display_name
      nil -> nil
    end
  end

  defp metadata_value(%Person{metadata: metadata}, key) when is_map(metadata) do
    Map.get(metadata, key)
  end

  defp metadata_value(_person, _key), do: nil

  defp truthy?(true), do: true
  defp truthy?("true"), do: true
  defp truthy?(_value), do: false

  defp pluralize(1, label), do: "1 #{label}"
  defp pluralize(count, label), do: "#{count} #{label}s"

  defp onboarding_error(:missing_display_name), do: "Add a name before saving family context."

  defp onboarding_error(:invalid_relationship_preset),
    do: "Choose one of the family relationship presets."

  defp onboarding_error(:proxy_family_member_not_found),
    do: "Choose a family member from this account, or leave For blank."

  defp onboarding_error(_reason), do: "Could not save that family context."

  attr :people, :list, required: true
  attr :selected_person_ids, :any, required: true
  attr :menu_open?, :boolean, required: true
  attr :action_mode, :string, default: nil
  attr :bulk_merge_form, :any, required: true

  defp people_bulk_action_bar(assigns) do
    assigns =
      assigns
      |> assign(:selected_people, selected_people(assigns.people, assigns.selected_person_ids))
      |> assign(:selected_count, MapSet.size(assigns.selected_person_ids))

    ~H"""
    <div
      :if={@selected_count > 0}
      id="people-bulk-actions"
      class="pointer-events-none fixed inset-x-3 bottom-[calc(1rem+env(safe-area-inset-bottom))] z-50 flex justify-center sm:inset-x-6 lg:left-64 lg:bottom-6"
    >
      <div class="pointer-events-auto relative max-w-[calc(100vw-1.5rem)]">
        <.people_bulk_action_panel
          :if={@action_mode == "merge"}
          selected_count={@selected_count}
          selected_people={@selected_people}
          bulk_merge_form={@bulk_merge_form}
        />

        <.people_bulk_delete_panel
          :if={@action_mode == "delete"}
          selected_count={@selected_count}
        />

        <.people_bulk_menu
          :if={@menu_open?}
          selected_count={@selected_count}
        />

        <div class="flex flex-wrap items-center justify-center gap-1.5 rounded-lg border border-zinc-950/20 bg-zinc-950/95 px-2.5 py-2 text-white shadow-xl ring-1 ring-white/10 backdrop-blur">
          <span class="rounded-md border border-white/10 bg-white/10 px-3 py-1.5 text-sm/6 font-semibold">
            <%= @selected_count %> selected
          </span>
          <button
            type="button"
            phx-click="clear_people_selection"
            aria-label="Clear selection"
            class="rounded-md px-2 py-1.5 text-sm/6 text-zinc-300 hover:bg-white/10 hover:text-white focus:outline-none focus:ring-2 focus:ring-white/30"
          >
            ×
          </button>
          <span class="mx-0.5 hidden h-6 w-px bg-white/15 sm:block" aria-hidden="true"></span>
          <button
            id="people-bulk-merge-direct"
            type="button"
            phx-click="choose_people_bulk_action"
            phx-value-action="merge"
            phx-value-anchor="bottom"
            disabled={@selected_count < 2}
            class="rounded-md border border-white/10 bg-white/10 px-3 py-1.5 text-sm/6 font-medium text-white hover:bg-white/15 focus:outline-none focus:ring-2 focus:ring-white/30 disabled:cursor-not-allowed disabled:text-zinc-500 disabled:hover:bg-white/10"
          >
            Merge
          </button>
          <button
            id="people-bulk-delete-direct"
            type="button"
            phx-click="choose_people_bulk_action"
            phx-value-action="delete"
            phx-value-anchor="bottom"
            class="rounded-md px-3 py-1.5 text-sm/6 font-medium text-red-100 hover:bg-red-500/20 hover:text-white focus:outline-none focus:ring-2 focus:ring-red-200/40"
          >
            Delete
          </button>
          <button
            id="people-bulk-actions-button"
            type="button"
            phx-click="toggle_people_bulk_menu"
            phx-value-anchor="bottom"
            aria-expanded={@menu_open?}
            aria-controls="people-bulk-action-menu"
            class="rounded-md border border-white/10 bg-white/10 px-3 py-1.5 text-sm/6 font-medium text-white hover:bg-white/15 focus:outline-none focus:ring-2 focus:ring-white/30"
          >
            Actions
          </button>
        </div>
      </div>
    </div>
    """
  end

  attr :selected_count, :integer, required: true
  attr :id, :string, default: "people-bulk-action-menu"
  attr :anchor, :string, default: "bottom"
  attr :placement, :string, default: "above"

  defp people_bulk_menu(assigns) do
    ~H"""
    <div
      id={@id}
      class={[
        "absolute left-1/2 z-20 w-72 -translate-x-1/2 overflow-hidden rounded-lg border border-zinc-950/10 bg-white p-1.5 text-zinc-950 shadow-lg",
        @placement == "below" && "top-full mt-2",
        @placement != "below" && "bottom-full mb-2"
      ]}
    >
      <button
        type="button"
        phx-click="choose_people_bulk_action"
        phx-value-action="merge"
        phx-value-anchor={@anchor}
        disabled={@selected_count < 2}
        class="flex w-full items-center justify-between rounded-md px-3 py-2 text-left text-sm/6 hover:bg-zinc-950/5 disabled:cursor-not-allowed disabled:text-zinc-400 disabled:hover:bg-transparent"
      >
        <span>Merge contacts</span>
        <span class="text-xs/5 text-zinc-500">Keep one</span>
      </button>
      <button
        type="button"
        phx-click="choose_people_bulk_action"
        phx-value-action="delete"
        phx-value-anchor={@anchor}
        class="flex w-full items-center justify-between rounded-md px-3 py-2 text-left text-sm/6 text-red-700 hover:bg-red-50"
      >
        <span>Delete contacts</span>
        <span class="text-xs/5 text-red-500"><%= @selected_count %></span>
      </button>
      <button
        type="button"
        phx-click="clear_people_selection"
        class="flex w-full items-center rounded-md px-3 py-2 text-left text-sm/6 hover:bg-zinc-950/5"
      >
        <span>Clear selection</span>
      </button>
    </div>
    """
  end

  attr :selected_count, :integer, required: true
  attr :selected_people, :list, required: true
  attr :bulk_merge_form, :any, required: true
  attr :id, :string, default: "people-bulk-merge-panel"
  attr :form_id, :string, default: "people-bulk-merge"
  attr :placement, :string, default: "above"

  defp people_bulk_action_panel(assigns) do
    ~H"""
    <div
      id={@id}
      class={[
        "absolute left-1/2 z-20 w-[min(92vw,30rem)] -translate-x-1/2 rounded-lg border border-zinc-950/10 bg-white p-4 text-zinc-950 shadow-lg",
        @placement == "below" && "top-full mt-2",
        @placement != "below" && "bottom-full mb-2"
      ]}
    >
      <div class="flex items-start justify-between gap-3">
        <div>
          <p class="text-sm/6 font-semibold text-zinc-950">Merge contacts</p>
          <p class="mt-1 text-xs/5 text-zinc-500">
            Choose the person to keep. The other selected contacts will be folded into it.
          </p>
        </div>
        <button
          type="button"
          phx-click="cancel_people_bulk_action"
          aria-label="Cancel merge"
          class="rounded-md px-2 py-1 text-sm/6 text-zinc-500 hover:bg-zinc-950/5 hover:text-zinc-950"
        >
          ×
        </button>
      </div>

      <.form
        for={@bulk_merge_form}
        id={@form_id}
        phx-submit="merge_selected_people"
        class="mt-3 flex flex-wrap items-end gap-2"
      >
        <.field label="Keep" for="people-bulk-survivor-id" class="min-w-64 flex-1">
          <.c_select
            id="people-bulk-survivor-id"
            name={@bulk_merge_form[:surviving_person_id].name}
            disabled={@selected_count < 2}
          >
            <option :for={person <- @selected_people} value={person.id}>
              <%= merge_candidate_label(person) %>
            </option>
          </.c_select>
        </.field>

        <.button type="submit" variant="outline" disabled={@selected_count < 2}>
          Merge contacts
        </.button>
      </.form>
    </div>
    """
  end

  attr :selected_count, :integer, required: true
  attr :id, :string, default: "people-bulk-delete-panel"
  attr :placement, :string, default: "above"

  defp people_bulk_delete_panel(assigns) do
    ~H"""
    <div
      id={@id}
      class={[
        "absolute left-1/2 z-20 w-[min(92vw,26rem)] -translate-x-1/2 rounded-lg border border-red-200 bg-white p-4 text-zinc-950 shadow-lg",
        @placement == "below" && "top-full mt-2",
        @placement != "below" && "bottom-full mb-2"
      ]}
    >
      <div class="flex items-start justify-between gap-3">
        <div>
          <p class="text-sm/6 font-semibold text-zinc-950">Delete contacts?</p>
          <p class="mt-1 text-xs/5 text-zinc-500">
            This removes <%= pluralize_people(@selected_count) %> and their relationship links.
          </p>
        </div>
        <button
          type="button"
          phx-click="cancel_people_bulk_action"
          aria-label="Cancel delete"
          class="rounded-md px-2 py-1 text-sm/6 text-zinc-500 hover:bg-zinc-950/5 hover:text-zinc-950"
        >
          ×
        </button>
      </div>

      <div class="mt-4 flex justify-end gap-2">
        <.button type="button" variant="plain" phx-click="cancel_people_bulk_action">
          Cancel
        </.button>
        <.button type="button" color="red" phx-click="delete_selected_people">
          Delete contacts
        </.button>
      </div>
    </div>
    """
  end

  attr :person, :any, required: true
  attr :filters, :map, required: true
  attr :timezone_info, :map, required: true

  defp person_detail_panel(assigns) do
    assigns =
      assigns
      |> assign(:relationship_form, relationship_form(assigns.person))
      |> assign(:contact_rows, contact_rows(assigns.person))

    ~H"""
    <aside id="person-detail" class="rounded-lg border border-zinc-950/10 bg-white px-4 py-4 shadow-sm">
      <div class="flex items-start justify-between gap-3">
        <div class="min-w-0">
          <div class="flex flex-wrap items-center gap-2">
            <.badge color={status_color(@person.status)}><%= label(@person.status) %></.badge>
            <span class="text-xs/5 text-zinc-500"><%= interaction_label(@person.interaction_count) %></span>
            <span class="text-xs/5 text-zinc-500"><%= format_datetime(@person.last_interaction_at, @timezone_info) %></span>
          </div>
          <h3 class="mt-2 text-base/7 font-semibold text-zinc-950"><%= @person.display_name %></h3>
          <p class="mt-1 text-sm/6 text-zinc-500"><%= contact_preview(@person) %></p>
        </div>
        <.link
          patch={people_path(@filters)}
          class="rounded-md px-2 py-1 text-xs/5 font-medium text-zinc-500 hover:bg-zinc-950/5 hover:text-zinc-950"
        >
          Close
        </.link>
      </div>

      <div :if={@contact_rows != []} class="mt-4 border-t border-zinc-950/10 pt-4">
        <p class="text-xs/5 font-medium text-zinc-500">Contact points</p>
        <dl class="mt-2 space-y-1.5">
          <div :for={row <- @contact_rows} class="grid grid-cols-[4.5rem_minmax(0,1fr)] gap-2">
            <dt class="text-xs/5 text-zinc-500"><%= row.label %></dt>
            <dd class="break-words text-xs/5 text-zinc-700"><%= row.value %></dd>
          </div>
        </dl>
      </div>

      <.form
        for={@relationship_form}
        id={"relationship-form-#{@person.id}"}
        phx-submit="save_relationship"
        class="mt-5 space-y-4 border-t border-zinc-950/10 pt-4"
      >
        <input type="hidden" name={@relationship_form[:person_id].name} value={@person.id} />

        <.field label="Name" for={"relationship-display-name-#{@person.id}"}>
          <.c_input
            id={"relationship-display-name-#{@person.id}"}
            name={@relationship_form[:display_name].name}
            value={@relationship_form[:display_name].value}
            placeholder="Display name"
          />
        </.field>

        <.field label="Relationship" for={"relationship-preset-#{@person.id}"}>
          <.c_select id={"relationship-preset-#{@person.id}"} name={@relationship_form[:preset].name}>
            <option value="">Choose a preset</option>
            <optgroup :for={group <- RelationshipPresets.groups()} label={group.label}>
              <option
                :for={preset <- group.presets}
                value={preset.id}
                selected={@relationship_form[:preset].value == preset.id}
              >
                <%= preset.label %>
              </option>
            </optgroup>
          </.c_select>
        </.field>

        <.field label="Custom relationship" for={"relationship-label-#{@person.id}"}>
          <.c_input
            id={"relationship-label-#{@person.id}"}
            name={@relationship_form[:relationship].name}
            value={@relationship_form[:relationship].value}
            placeholder="e.g. Emma's school contact"
          />
        </.field>

        <div class="grid gap-3 sm:grid-cols-2">
          <.field label="Cadence" for={"relationship-cadence-#{@person.id}"}>
            <.c_select
              id={"relationship-cadence-#{@person.id}"}
              name={@relationship_form[:communication_frequency].name}
            >
              <option value="">No cadence</option>
              <option
                :for={option <- RelationshipPresets.cadence_options()}
                value={option.value}
                selected={@relationship_form[:communication_frequency].value == option.value}
              >
                <%= option.label %>
              </option>
            </.c_select>
          </.field>

          <.field label="Channel" for={"relationship-channel-#{@person.id}"}>
            <.c_select
              id={"relationship-channel-#{@person.id}"}
              name={@relationship_form[:preferred_communication_method].name}
            >
              <option value="">No preference</option>
              <option
                :for={option <- RelationshipPresets.channel_options()}
                value={option.value}
                selected={@relationship_form[:preferred_communication_method].value == option.value}
              >
                <%= option.label %>
              </option>
            </.c_select>
          </.field>
        </div>

        <div :if={family_context_person?(@person)} class="grid gap-3 sm:grid-cols-2">
          <.field label="Family handling" for={"relationship-todo-policy-#{@person.id}"}>
            <.c_select
              id={"relationship-todo-policy-#{@person.id}"}
              name={@relationship_form[:todo_policy].name}
            >
              <option
                :for={option <- todo_policy_options()}
                value={option.value}
                selected={@relationship_form[:todo_policy].value == option.value}
              >
                <%= option.label %>
              </option>
            </.c_select>
          </.field>

          <.field label="Notifications" for={"relationship-push-policy-#{@person.id}"}>
            <.c_select
              id={"relationship-push-policy-#{@person.id}"}
              name={@relationship_form[:push_policy].name}
            >
              <option
                :for={option <- push_policy_options()}
                value={option.value}
                selected={@relationship_form[:push_policy].value == option.value}
              >
                <%= option.label %>
              </option>
            </.c_select>
          </.field>
        </div>

        <.field label="Context" for={"relationship-notes-#{@person.id}"}>
          <.c_textarea
            id={"relationship-notes-#{@person.id}"}
            name={@relationship_form[:notes].name}
            value={@relationship_form[:notes].value}
            rows={5}
            placeholder="What should Maraithon remember before surfacing this person?"
          />
        </.field>

        <div class="flex justify-end">
          <.button type="submit" variant="outline">Save context</.button>
        </div>
      </.form>
    </aside>
    """
  end

  defp relationship_form(%Person{} = person) do
    to_form(
      %{
        "person_id" => person.id,
        "display_name" => person.display_name || "",
        "preset" => get_in(person.metadata || %{}, ["relationship_preset"]) || "",
        "relationship" => person.relationship || "",
        "communication_frequency" => person.communication_frequency || "",
        "preferred_communication_method" => person.preferred_communication_method || "",
        "todo_policy" =>
          get_in(person.metadata || %{}, ["todo_policy"]) || "family_logistics_only",
        "push_policy" => get_in(person.metadata || %{}, ["push_policy"]) || "time_sensitive_only",
        "notes" => person.notes || ""
      },
      as: :relationship
    )
  end

  defp relationship_attrs(user_id, params) do
    person_id = normalize_text(Map.get(params, "person_id"))

    with person_id when is_binary(person_id) <- person_id,
         %Person{} = person <- Crm.get_person_for_user(user_id, person_id) do
      preset_id = normalize_text(Map.get(params, "preset"))
      display_name = normalize_text(Map.get(params, "display_name")) || person.display_name
      relationship = relationship_value(params, person)
      frequency = normalize_text(Map.get(params, "communication_frequency"))
      channel = normalize_text(Map.get(params, "preferred_communication_method"))
      notes = normalize_text(Map.get(params, "notes"))

      if Enum.all?([display_name, relationship, frequency, channel, preset_id, notes], &blank?/1) do
        {:error, :relationship_required}
      else
        attrs =
          %{
            "id" => person.id,
            "display_name" => display_name,
            "metadata" =>
              person.metadata
              |> relationship_metadata(preset_id, relationship)
              |> relationship_preferences_metadata(params),
            "notes" => notes
          }
          |> maybe_put("relationship", relationship)
          |> maybe_put("communication_frequency", frequency)
          |> maybe_put("preferred_communication_method", channel)

        {:ok, attrs}
      end
    else
      nil -> {:error, :person_not_found}
    end
  end

  defp relationship_value(params, %Person{} = person) do
    normalize_text(Map.get(params, "relationship")) ||
      RelationshipPresets.value(normalize_text(Map.get(params, "preset"))) ||
      normalize_text(person.relationship)
  end

  defp relationship_metadata(metadata, preset_id, relationship) do
    metadata = metadata || %{}
    now = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

    metadata =
      metadata
      |> Map.put("relationship_label", relationship)
      |> Map.put("relationship_context_source", "operator_people")
      |> Map.put("relationship_context_updated_at", now)

    case RelationshipPresets.get(preset_id) do
      nil ->
        metadata

      preset ->
        metadata
        |> Map.put("relationship_preset", preset.id)
        |> Map.put("relationship_domain", preset.domain)
        |> Map.put("relationship_preset_label", preset.label)
        |> relationship_kind_metadata(preset)
    end
  end

  defp relationship_kind_metadata(metadata, preset) do
    cond do
      preset.id in @family_member_presets ->
        metadata
        |> Map.put("family_member", true)
        |> Map.put("family_role", preset.id)
        |> Map.put("family_proxy", false)
        |> Map.delete("proxy_role")
        |> Map.delete("proxy_for_person_id")
        |> Map.put("sensitivity", family_sensitivity(preset.id))
        |> maybe_put("dependent_context", if(preset.id == "child", do: true))

      preset.id in @family_proxy_presets ->
        metadata
        |> Map.put("relationship_domain", "family")
        |> Map.put("family_member", false)
        |> Map.delete("family_role")
        |> Map.put("family_proxy", true)
        |> Map.put("proxy_role", preset.id)

      preset.domain == "family" ->
        metadata

      true ->
        clear_family_metadata(metadata)
    end
  end

  defp relationship_preferences_metadata(metadata, params) do
    if family_metadata?(metadata) do
      metadata
      |> Map.put_new("people_onboarding", false)
      |> Map.put("todo_policy", todo_policy_value(params))
      |> Map.put("push_policy", push_policy_value(params))
    else
      metadata
    end
  end

  defp family_metadata?(metadata) when is_map(metadata) do
    Map.get(metadata, "relationship_domain") == "family" or
      truthy?(Map.get(metadata, "family_member")) or
      truthy?(Map.get(metadata, "family_proxy"))
  end

  defp family_metadata?(_metadata), do: false

  defp clear_family_metadata(metadata) do
    Map.drop(
      metadata,
      ~w(
        family_member
        family_role
        family_proxy
        proxy_role
        proxy_for_person_id
        dependent_context
        sensitivity
        todo_policy
        push_policy
        default_todo_policy
        people_onboarding
      )
    )
  end

  defp selected_people(people, selected_person_ids) do
    Enum.filter(people, &MapSet.member?(selected_person_ids, &1.id))
  end

  defp assign_people_selection(socket, selected_person_ids) do
    if MapSet.size(selected_person_ids) == 0 do
      socket
      |> assign(:selected_person_ids, selected_person_ids)
      |> assign(:bulk_action_menu_open?, false)
      |> assign(:bulk_action_mode, nil)
      |> assign(:bulk_action_anchor, nil)
    else
      assign(socket, :selected_person_ids, selected_person_ids)
    end
  end

  defp assign_bulk_action(socket, action_mode, anchor \\ "context")

  defp assign_bulk_action(socket, nil, _anchor) do
    socket
    |> assign(:bulk_action_menu_open?, false)
    |> assign(:bulk_action_mode, nil)
    |> assign(:bulk_action_anchor, nil)
  end

  defp assign_bulk_action(socket, action_mode, anchor) do
    socket
    |> assign(:bulk_action_menu_open?, false)
    |> assign(:bulk_action_mode, action_mode)
    |> assign(:bulk_action_anchor, bulk_action_anchor(anchor))
  end

  defp anchored_action_mode(action_mode, anchor, anchor), do: action_mode
  defp anchored_action_mode(_action_mode, _anchor, _expected_anchor), do: nil

  defp bulk_action_anchor(anchor, default \\ "bottom")
  defp bulk_action_anchor("context", _default), do: "context"
  defp bulk_action_anchor("bottom", _default), do: "bottom"
  defp bulk_action_anchor(_anchor, default), do: default

  defp selected_visible_person_ids(socket) do
    socket.assigns.selected_person_ids
    |> MapSet.intersection(visible_person_ids(socket))
    |> MapSet.to_list()
  end

  defp visible_person_id?(socket, person_id) when is_binary(person_id) do
    MapSet.member?(visible_person_ids(socket), person_id)
  end

  defp visible_person_id?(_socket, _person_id), do: false

  defp visible_person_ids(socket) do
    (socket.assigns.people ++ socket.assigns.family_context_people)
    |> Enum.map(& &1.id)
    |> MapSet.new()
  end

  defp all_visible_people_selected?([], _selected_person_ids), do: false

  defp all_visible_people_selected?(people, selected_person_ids) when is_list(people) do
    visible_ids = people |> Enum.map(& &1.id) |> MapSet.new()
    MapSet.subset?(visible_ids, selected_person_ids)
  end

  defp all_visible_people_selected?(_people, _selected_person_ids), do: false

  defp toggle_mapset_member(mapset, value) do
    if MapSet.member?(mapset, value) do
      MapSet.delete(mapset, value)
    else
      MapSet.put(mapset, value)
    end
  end

  defp selected_person_for_user(_user_id, nil), do: nil
  defp selected_person_for_user(_user_id, ""), do: nil

  defp selected_person_for_user(user_id, person_id)
       when is_binary(user_id) and is_binary(person_id) do
    Crm.get_person_for_user(user_id, person_id)
  end

  defp selected_person_for_user(_user_id, _person_id), do: nil

  defp merge_selected_people(_user_id, selected_ids, _surviving_id)
       when length(selected_ids) < 2,
       do: {:error, :not_enough_people_selected}

  defp merge_selected_people(_user_id, _selected_ids, nil), do: {:error, :missing_survivor}

  defp merge_selected_people(user_id, selected_ids, surviving_id) do
    if surviving_id in selected_ids do
      survivor = Crm.get_person_for_user(user_id, surviving_id)
      duplicate_ids = Enum.reject(selected_ids, &(&1 == surviving_id))

      with %Person{} = survivor <- survivor,
           {:ok, merged_count} <- merge_duplicate_ids(user_id, survivor, duplicate_ids) do
        {:ok, survivor, merged_count}
      else
        nil -> {:error, :person_not_found}
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, :survivor_not_selected}
    end
  end

  defp merge_duplicate_ids(user_id, %Person{} = survivor, duplicate_ids) do
    Enum.reduce_while(duplicate_ids, {:ok, 0}, fn duplicate_id, {:ok, count} ->
      case Crm.merge_people(user_id, survivor.id, duplicate_id, %{
             "performed_by" => "operator_people",
             "evidence" => "Manual bulk duplicate merge from the People index.",
             "model_rationale" =>
               "Kept the selected canonical People row and merged the selected duplicate rows."
           }) do
        {:ok, _result} -> {:cont, {:ok, count + 1}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp merge_people_from_params(_user_id, nil, _merged_id), do: {:error, :missing_survivor}
  defp merge_people_from_params(_user_id, _surviving_id, nil), do: {:error, :missing_duplicate}

  defp merge_people_from_params(_user_id, person_id, person_id),
    do: {:error, :cannot_merge_person_into_self}

  defp merge_people_from_params(user_id, surviving_id, merged_id) do
    surviving = Crm.get_person_for_user(user_id, surviving_id)
    merged = Crm.get_person_for_user(user_id, merged_id)

    with %Person{} = surviving <- surviving,
         %Person{} = merged <- merged,
         {:ok, _result} <-
           Crm.merge_people(user_id, surviving.id, merged.id, %{
             "performed_by" => "operator_people",
             "evidence" => "Manual duplicate merge from the People table.",
             "model_rationale" => "Kept the selected People row and merged the duplicate row."
           }) do
      {:ok, surviving, merged}
    else
      nil -> {:error, :person_not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp delete_selected_people(_user_id, []), do: {:error, :no_people_selected}

  defp delete_selected_people(user_id, person_ids) do
    Enum.reduce_while(person_ids, {:ok, 0}, fn person_id, {:ok, count} ->
      case Crm.delete_person(user_id, person_id) do
        {:ok, _person} -> {:cont, {:ok, count + 1}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp merge_candidate_label(%Person{} = person) do
    "#{person.display_name} - #{contact_preview(person)}"
  end

  defp bulk_merge_flash(%Person{} = survivor, 1),
    do: "Merged 1 duplicate into #{survivor.display_name}."

  defp bulk_merge_flash(%Person{} = survivor, count),
    do: "Merged #{count} duplicates into #{survivor.display_name}."

  defp delete_people_flash(1), do: "Deleted 1 contact."
  defp delete_people_flash(count), do: "Deleted #{count} contacts."

  defp pluralize_people(1), do: "1 person"
  defp pluralize_people(count), do: "#{count} people"

  defp maybe_put(attrs, _key, nil), do: attrs
  defp maybe_put(attrs, key, value), do: Map.put(attrs, key, value)

  defp relationship_error(:relationship_required),
    do: "Add a name, relationship, cadence, channel, or context before saving."

  defp relationship_error(:person_not_found), do: "That person could not be found."
  defp relationship_error(_reason), do: "Could not update that relationship."

  defp merge_error(:missing_survivor), do: "Choose the person to keep."
  defp merge_error(:missing_duplicate), do: "Choose a duplicate to merge."
  defp merge_error(:not_enough_people_selected), do: "Select at least two people to merge."
  defp merge_error(:survivor_not_selected), do: "Choose one of the selected people to keep."
  defp merge_error(:cannot_merge_person_into_self), do: "Choose two different people to merge."
  defp merge_error(:person_not_found), do: "One of those people could not be found."
  defp merge_error(:person_already_merged), do: "That duplicate has already been merged."
  defp merge_error(:survivor_already_merged), do: "Choose an active person to keep."
  defp merge_error(:person_not_active), do: "Only active people can be merged."
  defp merge_error(_reason), do: "Could not merge those people."

  defp delete_error(:no_people_selected), do: "Select at least one person to delete."
  defp delete_error(:person_not_found), do: "One of those people could not be found."
  defp delete_error(_reason), do: "Could not delete those people."

  defp normalize_filters(params) do
    %{"q" => normalize_text(Map.get(params, "q")) || ""}
  end

  defp people_path(filters, extra_params \\ %{}) do
    query =
      filters
      |> Map.merge(extra_params)
      |> Enum.reject(fn {_key, value} -> blank?(value) end)
      |> Enum.into(%{})

    if map_size(query) == 0, do: ~p"/operator/people", else: ~p"/operator/people?#{query}"
  end

  defp current_path_from_uri(uri) do
    uri
    |> URI.parse()
    |> Map.get(:path)
    |> case do
      nil -> "/operator/people"
      "" -> "/operator/people"
      path -> path
    end
  end

  defp person_row_class(%Person{} = person, selected_person_ids, selected_person_id) do
    [
      "cursor-pointer transition-colors hover:bg-zinc-950/[0.025]",
      MapSet.member?(selected_person_ids, person.id) && "bg-blue-50/70",
      selected_person_id == person.id && "outline outline-1 -outline-offset-1 outline-zinc-950/10"
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" ")
  end

  defp contact_rows(%Person{contact_details: contact_details}) when is_map(contact_details) do
    [
      {"Email", Map.get(contact_details, "emails")},
      {"Slack", Map.get(contact_details, "slack_ids")},
      {"Phone", Map.get(contact_details, "phones")},
      {"Telegram", Map.get(contact_details, "telegram_ids")}
    ]
    |> Enum.flat_map(fn {label, values} ->
      values
      |> List.wrap()
      |> Enum.filter(&present?/1)
      |> Enum.map(&%{label: label, value: &1})
    end)
  end

  defp contact_rows(_person), do: []

  defp contact_preview(%Person{contact_details: contact_details}) when is_map(contact_details) do
    [
      {"Email", first_contact(contact_details, "emails")},
      {"Slack", first_contact(contact_details, "slack_ids")},
      {"Phone", first_contact(contact_details, "phones")},
      {"Telegram", first_contact(contact_details, "telegram_ids")}
    ]
    |> Enum.find_value(fn {label, value} ->
      if present?(value), do: "#{label}: #{value}"
    end)
    |> fallback("No contact")
  end

  defp contact_preview(_person), do: "No contact"

  defp first_contact(contact_details, key) do
    contact_details
    |> Map.get(key)
    |> List.wrap()
    |> Enum.find(&present?/1)
  end

  defp communication_frequency(%Person{communication_frequency: value}) do
    if present?(value), do: label(value), else: "No cadence"
  end

  defp interaction_label(count) when is_integer(count) and count == 1, do: "1 interaction"
  defp interaction_label(count) when is_integer(count), do: "#{count} interactions"
  defp interaction_label(_count), do: "0 interactions"

  defp empty_message(%{"q" => query}) do
    if present?(query),
      do: "No people match this search.",
      else: "People will appear after connected sources surface relationships."
  end

  defp status_color("active"), do: "green"
  defp status_color("merged"), do: "amber"
  defp status_color("archived"), do: "zinc"
  defp status_color(_status), do: "zinc"

  defp format_datetime(nil, _timezone_info), do: "No interactions recorded"

  defp format_datetime(%DateTime{} = datetime, timezone_info) do
    timezone_info = normalize_timezone_info(timezone_info)
    offset = Timezones.offset_at(timezone_info.name, datetime, timezone_info.offset_hours)
    label = Timezones.label(timezone_info.name, offset)

    datetime
    |> DateTime.add(offset, :hour)
    |> Calendar.strftime("%b %-d, %Y at %-I:%M %p #{label}")
  end

  defp format_datetime(value, _timezone_info), do: to_string(value)

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

  defp label(value) when is_binary(value) do
    value
    |> String.replace("_", " ")
    |> String.capitalize()
  end

  defp label(value), do: to_string(value)

  defp fallback(value, fallback \\ "Not set")

  defp fallback(value, fallback) when is_binary(value),
    do: if(present?(value), do: value, else: fallback)

  defp fallback(_value, fallback), do: fallback

  defp current_user_id(socket), do: socket.assigns.current_user.id

  defp stringify_params(params) when is_map(params) do
    Map.new(params, fn {key, value} -> {to_string(key), value} end)
  end

  defp stringify_params(_params), do: %{}

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
