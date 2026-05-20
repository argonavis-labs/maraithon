defmodule MaraithonWeb.PeopleLive do
  use MaraithonWeb, :live_view

  alias Maraithon.Crm
  alias Maraithon.Crm.Person

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
              </.table_row>
            </.table_head>
            <.table_body>
              <.table_row :if={@people == []}>
                <.table_cell colspan="6" class="py-10 text-center text-sm/6 text-zinc-500">
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
