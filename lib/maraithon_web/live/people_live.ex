defmodule MaraithonWeb.PeopleLive do
  use MaraithonWeb, :live_view

  alias Maraithon.Crm
  alias Maraithon.Crm.Person
  alias Maraithon.Crm.RelationshipPresets

  @default_filters %{"q" => ""}

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: "People",
       current_path: "/operator/people",
       filters: @default_filters,
       filter_form: to_form(@default_filters, as: :filters),
       people: []
     )}
  end

  @impl true
  def handle_params(params, uri, socket) do
    filters = normalize_filters(params)

    socket =
      socket
      |> assign(:current_path, current_path_from_uri(uri))
      |> assign(:filters, filters)
      |> assign(:filter_form, to_form(filters, as: :filters))
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

  def handle_event("save_relationship", %{"relationship" => params}, socket) do
    user_id = current_user_id(socket)

    socket =
      case relationship_attrs(user_id, params) do
        {:ok, attrs} ->
          case Crm.upsert_person(user_id, attrs) do
            {:ok, person} ->
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
          subtitle="CRM relationships Maraithon has learned from connected work and conversations."
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
                <h2 class="text-sm/6 font-semibold text-zinc-950">CRM people</h2>
                <p class="text-sm/6 text-zinc-500"><%= length(@people) %> shown</p>
              </div>
              <.badge color="zinc">Active</.badge>
            </div>
          </:header>

          <.table>
            <.table_head>
              <.table_row>
                <.table_header>Person</.table_header>
                <.table_header>Relationship</.table_header>
                <.table_header>Channel</.table_header>
                <.table_header>Activity</.table_header>
                <.table_header>Strength</.table_header>
                <.table_header>Status</.table_header>
                <.table_header class="text-right">Actions</.table_header>
              </.table_row>
            </.table_head>
            <.table_body>
              <.table_row :if={@people == []}>
                <.table_cell colspan="7" class="py-10 text-center text-sm/6 text-zinc-500">
                  <%= empty_message(@filters) %>
                </.table_cell>
              </.table_row>

              <.table_row :for={person <- @people} id={"person-#{person.id}"} class="hover:bg-zinc-50">
                <.table_cell class="max-w-sm whitespace-normal">
                  <div class="font-medium text-zinc-950"><%= person.display_name %></div>
                  <div class="mt-1 text-sm/6 text-zinc-500"><%= contact_preview(person) %></div>
                  <div :if={present?(person.notes)} class="mt-1 line-clamp-2 text-sm/6 text-zinc-600">
                    <%= person.notes %>
                  </div>
                </.table_cell>
                <.table_cell class="whitespace-normal">
                  <div class="text-sm/6 text-zinc-950"><%= fallback(person.relationship) %></div>
                  <div class="mt-1 text-xs/5 text-zinc-500">
                    <%= communication_frequency(person) %>
                  </div>
                </.table_cell>
                <.table_cell>
                  <%= if present?(person.preferred_communication_method) do %>
                    <.badge color="blue"><%= label(person.preferred_communication_method) %></.badge>
                  <% else %>
                    <span class="text-sm/6 text-zinc-500">Unknown</span>
                  <% end %>
                </.table_cell>
                <.table_cell>
                  <div class="text-sm/6 text-zinc-950"><%= format_datetime(person.last_interaction_at) %></div>
                  <div class="mt-1 text-xs/5 text-zinc-500">
                    <%= interaction_label(person.interaction_count) %>
                  </div>
                </.table_cell>
                <.table_cell>
                  <div class="text-sm/6 text-zinc-950">
                    <%= metric_label("Strength", person.relationship_strength) %>
                  </div>
                  <div class="mt-1 text-xs/5 text-zinc-500">
                    <%= metric_label("Affinity", person.affinity_score) %>
                  </div>
                </.table_cell>
                <.table_cell>
                  <.badge color={status_color(person.status)}><%= label(person.status) %></.badge>
                </.table_cell>
                <.table_cell class="w-80 whitespace-normal text-right align-top">
                  <.person_actions
                    person={person}
                    people={@people}
                    relationship_preset_groups={RelationshipPresets.groups()}
                  />
                </.table_cell>
              </.table_row>
            </.table_body>
          </.table>
        </.panel>
      </div>
    </Layouts.app>
    """
  end

  defp refresh_people(socket) do
    people =
      Crm.list_people(current_user_id(socket),
        query: normalize_text(socket.assigns.filters["q"]),
        limit: 100
      )

    assign(socket, :people, people)
  end

  attr :person, :any, required: true
  attr :people, :list, required: true
  attr :relationship_preset_groups, :list, required: true

  defp person_actions(assigns) do
    assigns =
      assigns
      |> assign(:relationship_form, relationship_form(assigns.person))
      |> assign(:merge_form, merge_form(assigns.person))
      |> assign(:merge_candidates, merge_candidates(assigns.people, assigns.person))

    ~H"""
    <div class="inline-flex w-72 flex-col gap-2 text-left">
      <details class="rounded-lg border border-zinc-950/10 bg-white px-3 py-2">
        <summary class="cursor-pointer list-none text-sm/6 font-medium text-zinc-950 hover:text-blue-600">
          Set relationship
        </summary>

        <.form
          for={@relationship_form}
          id={"relationship-form-#{@person.id}"}
          phx-submit="save_relationship"
          class="mt-3 space-y-3"
        >
          <input type="hidden" name={@relationship_form[:person_id].name} value={@person.id} />

          <.field label="Preset" for={"relationship-preset-#{@person.id}"}>
            <.c_select
              id={"relationship-preset-#{@person.id}"}
              name={@relationship_form[:preset].name}
            >
              <option value="">Choose relationship</option>
              <optgroup :for={group <- @relationship_preset_groups} label={group.label}>
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

          <.field label="Custom label" for={"relationship-label-#{@person.id}"}>
            <.c_input
              id={"relationship-label-#{@person.id}"}
              name={@relationship_form[:relationship].name}
              value={@relationship_form[:relationship].value}
              placeholder="e.g. Family event organizer"
            />
          </.field>

          <div class="grid gap-3 sm:grid-cols-2">
            <.field label="Cadence" for={"relationship-cadence-#{@person.id}"}>
              <.c_select
                id={"relationship-cadence-#{@person.id}"}
                name={@relationship_form[:communication_frequency].name}
              >
                <option value="">No change</option>
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
                <option value="">No change</option>
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

          <div class="flex justify-end">
            <.button type="submit" variant="outline">Save</.button>
          </div>
        </.form>
      </details>

      <details class="rounded-lg border border-zinc-950/10 bg-white px-3 py-2">
        <summary class="cursor-pointer list-none text-sm/6 font-medium text-zinc-950 hover:text-blue-600">
          Merge duplicate
        </summary>

        <.form
          for={@merge_form}
          id={"merge-form-#{@person.id}"}
          phx-submit="merge_people"
          class="mt-3 space-y-3"
        >
          <input type="hidden" name={@merge_form[:surviving_person_id].name} value={@person.id} />

          <.field label="Merge into this person" for={"merge-merged-person-id-#{@person.id}"}>
            <.c_select
              id={"merge-merged-person-id-#{@person.id}"}
              name={@merge_form[:merged_person_id].name}
              disabled={@merge_candidates == []}
            >
              <option value="">Choose duplicate</option>
              <option :for={candidate <- @merge_candidates} value={candidate.id}>
                <%= merge_candidate_label(candidate) %>
              </option>
            </.c_select>
          </.field>

          <div class="flex justify-end">
            <.button type="submit" variant="outline" disabled={@merge_candidates == []}>
              Merge
            </.button>
          </div>
        </.form>
      </details>
    </div>
    """
  end

  defp relationship_form(%Person{} = person) do
    to_form(
      %{
        "person_id" => person.id,
        "preset" => get_in(person.metadata || %{}, ["relationship_preset"]) || "",
        "relationship" => person.relationship || "",
        "communication_frequency" => person.communication_frequency || "",
        "preferred_communication_method" => person.preferred_communication_method || ""
      },
      as: :relationship
    )
  end

  defp merge_form(%Person{} = person) do
    to_form(%{"surviving_person_id" => person.id, "merged_person_id" => ""}, as: :merge)
  end

  defp relationship_attrs(user_id, params) do
    person_id = normalize_text(Map.get(params, "person_id"))

    with person_id when is_binary(person_id) <- person_id,
         %Person{} = person <- Crm.get_person_for_user(user_id, person_id) do
      preset_id = normalize_text(Map.get(params, "preset"))
      relationship = relationship_value(params, person)
      frequency = normalize_text(Map.get(params, "communication_frequency"))
      channel = normalize_text(Map.get(params, "preferred_communication_method"))

      if Enum.all?([relationship, frequency, channel, preset_id], &blank?/1) do
        {:error, :relationship_required}
      else
        attrs =
          %{
            "id" => person.id,
            "metadata" => relationship_metadata(person.metadata, preset_id, relationship)
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
    end
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
             "evidence" => "Manual duplicate merge from the People operator table.",
             "model_rationale" =>
               "The user selected the canonical CRM row and the duplicate row to collapse."
           }) do
      {:ok, surviving, merged}
    else
      nil -> {:error, :person_not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp merge_candidates(people, %Person{} = person) do
    Enum.reject(people, &(&1.id == person.id))
  end

  defp merge_candidate_label(%Person{} = person) do
    "#{person.display_name} - #{contact_preview(person)}"
  end

  defp maybe_put(attrs, _key, nil), do: attrs
  defp maybe_put(attrs, key, value), do: Map.put(attrs, key, value)

  defp relationship_error(:relationship_required),
    do: "Choose a relationship preset, enter a custom relationship, or set cadence/channel."

  defp relationship_error(:person_not_found), do: "That person could not be found."
  defp relationship_error(_reason), do: "Could not update that relationship."

  defp merge_error(:missing_survivor), do: "Choose the person to keep."
  defp merge_error(:missing_duplicate), do: "Choose a duplicate to merge."
  defp merge_error(:cannot_merge_person_into_self), do: "Choose two different people to merge."
  defp merge_error(:person_not_found), do: "One of those people could not be found."
  defp merge_error(:person_already_merged), do: "That duplicate has already been merged."
  defp merge_error(:survivor_already_merged), do: "Choose an active person to keep."
  defp merge_error(:person_not_active), do: "Only active people can be merged."
  defp merge_error(_reason), do: "Could not merge those people."

  defp normalize_filters(params) do
    %{"q" => normalize_text(Map.get(params, "q")) || ""}
  end

  defp people_path(filters) do
    query =
      filters
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

  defp metric_label(label, value) when is_integer(value), do: "#{label} #{value}"
  defp metric_label(label, _value), do: "#{label} 0"

  defp empty_message(%{"q" => query}) do
    if present?(query), do: "No people match this search.", else: "No people found yet."
  end

  defp status_color("active"), do: "green"
  defp status_color("merged"), do: "amber"
  defp status_color("archived"), do: "zinc"
  defp status_color(_status), do: "zinc"

  defp format_datetime(nil), do: "Never"

  defp format_datetime(%DateTime{} = datetime) do
    Calendar.strftime(datetime, "%Y-%m-%d %H:%M UTC")
  end

  defp format_datetime(value), do: to_string(value)

  defp label(value) when is_binary(value) do
    value
    |> String.replace("_", " ")
    |> String.capitalize()
  end

  defp label(value), do: to_string(value)

  defp fallback(value, fallback \\ "Unknown")

  defp fallback(value, fallback) when is_binary(value),
    do: if(present?(value), do: value, else: fallback)

  defp fallback(_value, fallback), do: fallback

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
