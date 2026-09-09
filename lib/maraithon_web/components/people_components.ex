defmodule MaraithonWeb.PeopleComponents do
  @moduledoc "People graph, evidence rows and profile panels using the app primitives."
  use MaraithonWeb, :html

  attr :id, :string, required: true
  attr :nodes, :list, required: true
  attr :edges, :list, required: true
  attr :selected, :string, default: nil

  def people_graph(assigns) do
    ~H"""
    <div id={@id} phx-hook="PeopleGraph" data-graph={Jason.encode!(%{nodes: @nodes, edges: @edges, selected: @selected})}>
      <div class="flex flex-wrap items-center justify-between gap-3 border-b border-zinc-950/10 px-4 py-2">
        <div class="flex flex-wrap gap-4 text-xs text-zinc-500"><span>Solid · Your communication</span><span>Dashed · Shared context</span></div>
        <div class="flex gap-1">
          <.button type="button" variant="plain" data-graph-action="zoom-in" aria-label="Zoom in">+</.button>
          <.button type="button" variant="plain" data-graph-action="zoom-out" aria-label="Zoom out">−</.button>
          <.button type="button" variant="plain" data-graph-action="fit">Fit</.button>
        </div>
      </div>
      <div data-graph-area class="relative h-[32rem] overflow-hidden bg-zinc-50/40" style="touch-action: none;">
        <canvas id={@id <> "-canvas"} phx-update="ignore" class="absolute inset-0 size-full" aria-hidden="true"></canvas>
        <div id={@id <> "-nodes"} phx-update="ignore" data-graph-nodes class="absolute inset-0" role="group" aria-label="People in the network"></div>
        <p class="pointer-events-none absolute bottom-3 left-4 text-xs text-zinc-500">Drag to explore · Select a person or connection</p>
      </div>
    </div>
    """
  end

  attr :nodes, :list, required: true
  attr :selected, :string, default: nil

  def network_people_list(assigns) do
    ~H"""
    <ul class="divide-y divide-zinc-950/10">
      <li :for={node <- @nodes}>
        <button type="button" phx-click="select_person" phx-value-id={node["id"]} aria-pressed={@selected == node["id"]} class={[
          "flex w-full items-center gap-3 px-1 py-3 text-left hover:bg-zinc-50", @selected == node["id"] && "bg-zinc-50"]}>
          <div class="min-w-0 flex-1"><p class="truncate text-sm font-medium"><%= node["name"] %></p><p class="truncate text-xs text-zinc-500"><%= node["subtitle"] || channel_label(node["channels"]) %></p></div>
          <div class="text-right text-xs text-zinc-500"><p><%= node["active_days"] %> active days</p><p><%= relative_time(node["last_at"]) %></p></div>
        </button>
      </li>
    </ul>
    """
  end

  attr :person, :map, required: true
  attr :days, :integer, required: true
  attr :query, :string, default: ""

  def network_person_detail(assigns) do
    ~H"""
    <.panel id="network-person-detail" body_class="px-4 py-4">
      <div class="flex items-start justify-between gap-2">
        <div><h2 class="text-base font-semibold"><%= @person["name"] %></h2><p class="mt-1 text-sm text-zinc-500"><%= @person["subtitle"] || "Observed in your connected sources" %></p></div>
        <.button variant="plain" patch={~p"/operator/people?#{%{days: @days, q: @query}}"}>Close</.button>
      </div>
      <p :if={@person["notes"]} class="mt-4 whitespace-pre-wrap text-sm text-zinc-700"><%= @person["notes"] %></p>
      <div class="mt-4 flex flex-wrap gap-x-4 gap-y-1 border-y border-zinc-950/10 py-3 text-xs text-zinc-600">
        <span><%= @person["active_days"] %> active days</span><span><%= @person["message_count"] %> messages</span><span>Last <%= @days %> days</span>
      </div>
      <p class="mt-2 text-xs text-zinc-500"><%= channel_label(@person["channels"]) %></p>
      <div :if={@person["next_meetings"] != []} class="mt-4">
        <h3 class="text-xs font-semibold">Next meeting</h3>
        <div :for={meeting <- Enum.take(@person["next_meetings"], 1)} class="mt-2 text-sm"><p><%= meeting["title"] || "Calendar event" %></p><p class="text-xs text-zinc-500"><time datetime={meeting["at"]}><%= date_label(meeting["at"]) %></time></p></div>
      </div>
      <h3 class="mt-5 text-xs font-semibold">Open todos</h3>
      <p :if={@person["todos"] == []} class="mt-2 text-sm text-zinc-500">No open todos linked.</p>
      <ul class="mt-2 divide-y divide-zinc-950/10">
        <li :for={todo <- @person["todos"]} class="py-2"><.link navigate={~p"/todos/#{todo.id}"} class="text-sm text-zinc-700 underline decoration-zinc-300 underline-offset-4"><%= todo.title %></.link></li>
      </ul>
      <h3 class="mt-5 text-xs font-semibold">Recent history</h3>
      <p :if={@person["history"] == []} class="mt-2 text-sm text-zinc-500">No earlier exchanges found.</p>
      <.activity_history events={@person["history"]} />
      <div :if={@person["connections"] != []} class="mt-4">
        <h3 class="text-xs font-semibold">Shared context with</h3>
        <div class="mt-2 divide-y divide-zinc-950/10"><div :for={connection <- Enum.take(@person["connections"], 6)} class="flex items-center justify-between gap-2 py-1"><.button variant="plain" phx-click="select_person" phx-value-id={connection["node_id"]}><%= connection["name"] %></.button><.button variant="plain" phx-click="select_connection" phx-value-id={Enum.sort([@person["id"], connection["node_id"]]) |> Enum.join(":")}>Evidence</.button></div></div>
      </div>
      <div :if={@person["person_id"]} class="mt-5 border-t border-zinc-950/10 pt-3"><.button variant="plain" navigate={~p"/operator/people/manage?#{%{person_id: @person["person_id"]}}"}>Edit person</.button></div>
    </.panel>
    """
  end

  attr :events, :list, required: true

  def activity_history(assigns) do
    ~H"""
    <ul class="mt-2 divide-y divide-zinc-950/10">
      <li :for={event <- @events} class="py-3">
        <p class="text-xs text-zinc-500"><%= source_name(value(event, :source)) %> · <time datetime={value(event, :at)}><%= date_label(value(event, :at)) %></time></p>
        <p class="mt-1 text-sm font-medium"><%= value(event, :title) || event_label(event) %></p>
        <p :if={value(event, :excerpt)} class="mt-1 whitespace-pre-wrap break-words text-sm text-zinc-600"><%= value(event, :excerpt) %></p>
        <p :if={value(event, :kind) in ["calendar", "shared", "conversation"]} class="mt-1 text-xs text-zinc-500"><%= if value(event, :type) == "calendar", do: "On your calendar", else: "Shared conversation" %></p>
      </li>
    </ul>
    """
  end

  def date_label(value) do
    case datetime(value) do
      nil -> "Date unknown"
      at -> Calendar.strftime(at, "%b %-d · %H:%M UTC")
    end
  end

  def relative_time(value) do
    case datetime(value) do
      nil ->
        "No recorded exchange"

      at ->
        seconds = max(DateTime.diff(DateTime.utc_now(), at), 0)

        cond do
          seconds < 60 -> "just now"
          seconds < 3600 -> "#{div(seconds, 60)}m ago"
          seconds < 86_400 -> "#{div(seconds, 3600)}h ago"
          true -> "#{div(seconds, 86_400)}d ago"
        end
    end
  end

  defp datetime(%DateTime{} = value), do: value

  defp datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, at, _} -> at
      _ -> nil
    end
  end

  defp datetime(_value), do: nil
  defp value(event, key), do: Map.get(event, key) || Map.get(event, Atom.to_string(key))

  defp event_label(event),
    do:
      if(value(event, :type) == "calendar",
        do: "Calendar event",
        else: "#{source_name(value(event, :source))} exchange"
      )

  defp channel_label(channels),
    do: Enum.map_join(channels || [], " · ", &source_name(&1["source"]))

  defp source_name("gmail"), do: "Email"
  defp source_name("slack"), do: "Slack"
  defp source_name("whatsapp"), do: "WhatsApp"
  defp source_name("calendar"), do: "Calendar"
  defp source_name(_source), do: "Messages"
end
