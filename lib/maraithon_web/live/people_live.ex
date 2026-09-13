defmodule MaraithonWeb.PeopleLive do
  use MaraithonWeb, :live_view
  alias Maraithon.PeopleNetwork
  import MaraithonWeb.PeopleComponents
  import MaraithonWeb.Components.Sidebar, only: [icon: 1]

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Process.send_after(self(), :refresh_network, 60_000)

    {:ok,
     assign(socket,
       page_title: "People",
       current_path: "/operator/people",
       days: 30,
       query: "",
       person_id: nil,
       connection: nil,
       view: "network",
       filters: to_form(%{"q" => "", "days" => "30"}, as: :filters)
     )}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    days = PeopleNetwork.window_days(params["days"])
    query = String.slice(params["q"] || "", 0, 160)

    socket =
      assign(socket,
        days: days,
        query: query,
        person_id: params["person_id"],
        connection: nil,
        filters: to_form(%{"q" => query, "days" => to_string(days)}, as: :filters)
      )

    {:noreply, load_network(socket)}
  end

  @impl true
  def handle_event("filter", %{"filters" => filters}, socket) do
    {:noreply, push_patch(socket, to: network_path(filters["days"], filters["q"], nil))}
  end

  def handle_event("select_person", %{"id" => id}, socket) do
    {:noreply,
     push_patch(socket, to: network_path(socket.assigns.days, socket.assigns.query, id))}
  end

  def handle_event("select_connection", %{"id" => id}, socket) do
    connection =
      case socket.assigns.result do
        %{ok?: true, result: %{network: network}} -> Enum.find(network.edges, &(&1.id == id))
        _ -> nil
      end

    {:noreply, assign(socket, :connection, connection)}
  end

  def handle_event("view", %{"view" => view}, socket) when view in ["network", "list"] do
    {:noreply, assign(socket, :view, view)}
  end

  def handle_event("retry", _params, socket), do: {:noreply, load_network(socket)}

  def handle_event("close_connection", _params, socket),
    do: {:noreply, assign(socket, :connection, nil)}

  @impl true
  def handle_info(:refresh_network, socket) do
    Process.send_after(self(), :refresh_network, 60_000)
    {:noreply, load_network(socket)}
  end

  defp load_network(socket) do
    user_id = socket.assigns.current_user.id
    days = socket.assigns.days
    query = socket.assigns.query
    person_id = socket.assigns.person_id

    assign_async(socket, :result, fn ->
      network = PeopleNetwork.view(user_id, days: days, query: query, focus: person_id)

      selected =
        if is_binary(person_id) do
          case PeopleNetwork.Detail.fetch(user_id, person_id, days: days) do
            {:ok, person} -> person
            _ -> nil
          end
        end

      {:ok, %{result: %{network: network, selected: selected}}}
    end)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_path={@current_path} current_user={@current_user}>
      <div id="people-page" phx-hook="PeopleDates" class="space-y-5">
        <.page_header title="People">
          <:actions><.button navigate={~p"/operator/people/manage"} variant="plain">Manage people</.button></:actions>
        </.page_header>
        <.form for={@filters} id="people-network-filters" phx-change="filter" phx-submit="filter" class="flex flex-wrap items-end gap-4">
          <.field label="Find a person" for="people-network-search" class="min-w-48 flex-1">
            <.c_input id="people-network-search" name={@filters[:q].name} value={@filters[:q].value} placeholder="Search people" phx-debounce="300" />
          </.field>
          <.field label="Communication history" for="people-network-days">
            <.c_select id="people-network-days" name={@filters[:days].name}>
              <option :for={days <- [30, 90, 180]} value={days} selected={days == @days}>Last <%= days %> days</option>
            </.c_select>
          </.field>
          <div class="flex gap-1 pb-0.5" aria-label="People view">
            <.button type="button" variant={if @view == "network", do: "solid", else: "plain"} phx-click="view" phx-value-view="network" aria-pressed={@view == "network"}>Network</.button>
            <.button type="button" variant={if @view == "list", do: "solid", else: "plain"} phx-click="view" phx-value-view="list" aria-pressed={@view == "list"}>List</.button>
          </div>
        </.form>

        <.async_result :let={result} assign={@result}>
          <:loading><.panel><p class="text-sm text-zinc-500" role="status">Loading your network…</p></.panel></:loading>
          <:failed :let={_failure}>
            <.panel><p class="text-sm text-zinc-700">Your network couldn’t load.</p><.button class="mt-3" phx-click="retry" variant="outline">Try again</.button></.panel>
          </:failed>
          <div :if={result.network.status == "preparing"} class="rounded-lg border border-zinc-950/10 px-6 py-12 text-center">
            <.icon name={:people} class="mx-auto size-8 text-zinc-400" />
            <h2 class="mt-4 text-base font-semibold">Your network is being prepared</h2>
            <p class="mt-2 text-sm text-zinc-500">People and conversations will appear after the first background update.</p>
          </div>
          <div :if={result.network.status == "ready"} class="grid gap-5 xl:grid-cols-[minmax(0,1fr)_20rem]">
            <div class="min-w-0 space-y-4">
              <.panel body_class="p-0">
                <div :if={@view == "network"}>
                  <.people_graph id="people-network" nodes={result.network.nodes} edges={result.network.edges} selected={@person_id} />
                </div>
                <div :if={@view == "list"} class="px-4">
                  <.network_people_list nodes={result.network.nodes} selected={@person_id} />
                </div>
                <div :if={result.network.nodes == []} class="px-6 py-8 text-center text-sm text-zinc-500">
                  <%= if @query == "", do: "No communication network yet. Your upcoming meetings are shown alongside it.", else: "No people match this search." %>
                </div>
                <div class="flex flex-wrap justify-between gap-2 border-t border-zinc-950/10 px-4 py-3 text-xs text-zinc-500">
                  <span><%= length(result.network.nodes) %> people in view · <%= result.network.people_count %> known people</span>
                  <span>Updated <%= relative_time(result.network.refreshed_at) %></span>
                </div>
              </.panel>
              <.panel :if={@connection} body_class="px-4 py-3">
                <div class="flex items-center justify-between gap-3"><h2 class="text-sm font-semibold"><%= connection_title(@connection, result.network.nodes) %></h2><.button variant="plain" phx-click="close_connection">Close</.button></div>
                <p class="mt-1 text-xs text-zinc-500"><%= if @connection.kind == "direct", do: "Your communication", else: "Observed shared context" %></p>
                <.activity_history events={@connection.evidence || []} />
              </.panel>
              <.panel :if={@view == "network" and result.network.nodes != []} body_class="px-4 py-3">
                <h2 class="mb-2 text-sm font-semibold">In conversation</h2>
                <.network_people_list nodes={frequent_people(result.network.nodes)} selected={@person_id} />
              </.panel>
            </div>
            <div class="space-y-4">
              <.network_person_detail :if={result.selected} person={result.selected} days={@days} query={@query} />
              <.panel :if={@person_id && !result.selected} body_class="px-4 py-3"><p class="text-sm text-zinc-500">This person is not in the current network snapshot.</p></.panel>
              <.panel body_class="px-4 py-3">
                <h2 class="mb-2 text-sm font-semibold">Meeting next</h2>
                <p :if={"calendar_unavailable" in result.network.warnings} class="mb-3 text-xs text-zinc-500">A connected calendar couldn’t update. Available synced meetings are shown.</p>
                <p :if={result.network.meetings == []} class="py-4 text-sm text-zinc-500">No upcoming meetings in the synced calendar.</p>
                <ul class="divide-y divide-zinc-950/10">
                  <li :for={meeting <- result.network.meetings} class="py-3">
                    <p class="text-xs text-zinc-500"><time datetime={meeting["at"]}><%= date_label(meeting["at"]) %></time></p>
                    <p class="mt-1 text-sm font-medium"><%= meeting["title"] || "Calendar event" %></p>
                    <div class="mt-1 flex flex-wrap gap-x-3 gap-y-1">
                      <button :for={person <- meeting["people"]} type="button" phx-click="select_person" phx-value-id={person["id"]} class="text-left text-sm text-zinc-600 underline decoration-zinc-300 underline-offset-4 hover:text-zinc-950"><%= person["name"] %></button>
                    </div>
                  </li>
                </ul>
              </.panel>
            </div>
          </div>
        </.async_result>
      </div>
    </Layouts.app>
    """
  end

  defp frequent_people(nodes),
    do:
      nodes
      |> Enum.filter(&(&1["message_count"] > 0))
      |> Enum.sort_by(& &1["active_days"], :desc)
      |> Enum.take(8)

  defp connection_title(edge, nodes) do
    names = Map.new(nodes, &{&1["id"], &1["name"]}) |> Map.put("you", "You")
    "#{Map.get(names, edge.from, "Person")} · #{Map.get(names, edge.to, "Person")}"
  end

  defp network_path(days, query, person_id) do
    params =
      %{"days" => PeopleNetwork.window_days(days), "q" => query || "", "person_id" => person_id}
      |> Enum.reject(fn {_key, value} -> value in [nil, ""] end)
      |> URI.encode_query()

    "/operator/people?" <> params
  end
end
