defmodule MaraithonWeb.ActivityLive do
  @moduledoc """
  "What did you do today?" audit surface (SPEC 09 R4).

  Mirrors `MaraithonWeb.BriefingLive`'s structure and permissions (same
  `:browser` + `LiveUserAuth.ensure_authenticated` live_session) and renders
  `Maraithon.ActionLedger.activity_summary/2` as day-picked rollups and
  notable-item rows, never raw dumps.
  """

  use MaraithonWeb, :live_view

  alias Maraithon.ActionLedger
  alias MaraithonWeb.LocalTime

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, :current_path, "/activity")}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, socket |> assign_day(params) |> refresh()}
  end

  defp assign_day(socket, %{"day" => "yesterday"}) do
    assign(socket, day: :yesterday, selected_date: nil)
  end

  defp assign_day(socket, %{"day" => day}) when is_binary(day) do
    case Date.from_iso8601(day) do
      {:ok, date} -> assign(socket, day: date, selected_date: date)
      _error -> assign_day(socket, %{})
    end
  end

  defp assign_day(socket, _params) do
    assign(socket, day: :today, selected_date: nil)
  end

  defp refresh(socket) do
    user_id = socket.assigns.current_user.id
    timezone_info = LocalTime.timezone_info_for_user(user_id)
    summary = ActionLedger.activity_summary(user_id, socket.assigns.day)

    socket
    |> assign(:timezone_info, timezone_info)
    |> assign(:summary, summary)
    |> assign(:sections, build_sections(summary, timezone_info))
  end

  defp build_sections(summary, timezone_info) do
    [
      %{
        key: "added",
        title: "Added",
        count: summary.todos.created.count,
        empty: "No new work items yet.",
        rows: Enum.map(summary.todos.created.items, &todo_event_row(&1, timezone_info))
      },
      %{
        key: "updated",
        title: "Updated",
        count: summary.todos.updated.count,
        empty: "No work item edits yet.",
        rows: Enum.map(summary.todos.updated.items, &todo_updated_row(&1, timezone_info))
      },
      %{
        key: "closed",
        title: "Closed",
        count: summary.todos.closed.count,
        empty: "Nothing closed yet.",
        rows: Enum.map(summary.todos.closed.items, &todo_event_row(&1, timezone_info))
      },
      %{
        key: "learned",
        title: "Learned",
        count: summary.memories.count,
        empty: "No new memories yet.",
        rows: Enum.map(summary.memories.items, &memory_row(&1, timezone_info))
      },
      %{
        key: "people",
        title: "People",
        count: summary.people.created.count + summary.people.enriched.count,
        empty: "No People changes yet.",
        rows:
          Enum.map(summary.people.created.items, &person_row(&1, "Created", timezone_info)) ++
            Enum.map(summary.people.enriched.items, &person_row(&1, "Enriched", timezone_info))
      },
      %{
        key: "pinged",
        title: "Pinged",
        count: summary.pings.count,
        empty: "No proactive pings sent yet.",
        rows: Enum.map(summary.pings.items, &ping_row(&1, timezone_info))
      },
      %{
        key: "held",
        title: "Held",
        count: summary.holds.count,
        empty: "Nothing held yet.",
        rows: Enum.map(summary.holds.items, &hold_row(&1, timezone_info))
      }
    ]
  end

  defp todo_event_row(item, timezone_info) do
    %{
      primary: presence(item.title, "Untitled work item"),
      secondary: presence(item.source, nil),
      timestamp: format_time(item.occurred_at, timezone_info)
    }
  end

  defp todo_updated_row(item, timezone_info) do
    %{
      primary: presence(item.title, "Untitled work item"),
      secondary: presence(item.status, nil),
      timestamp: format_time(item.updated_at, timezone_info)
    }
  end

  defp memory_row(item, timezone_info) do
    %{
      primary: presence(item.title, "Untitled memory"),
      secondary: presence(item.kind, nil),
      timestamp: format_time(item.inserted_at, timezone_info)
    }
  end

  defp person_row(item, label, timezone_info) do
    %{
      primary: presence(item.display_name, "Unnamed person"),
      secondary: label,
      timestamp: format_time(item[:updated_at] || item[:inserted_at], timezone_info)
    }
  end

  defp ping_row(item, timezone_info) do
    %{
      primary: presence(item.why_now, presence(item.origin_type, "Proactive push")),
      secondary: item.decision,
      timestamp: format_time(item.inserted_at, timezone_info)
    }
  end

  defp hold_row(item, timezone_info) do
    %{
      primary: presence(item.why_now, "Held"),
      secondary: humanize_reason(item.reason),
      timestamp: format_time(item.inserted_at, timezone_info)
    }
  end

  defp presence(nil, fallback), do: fallback
  defp presence("", fallback), do: fallback
  defp presence(value, _fallback), do: value

  defp humanize_reason(nil), do: "unknown"
  defp humanize_reason(reason), do: reason |> to_string() |> String.replace("_", " ")

  defp format_time(nil, _timezone_info), do: nil
  defp format_time(value, timezone_info), do: LocalTime.format_datetime(value, nil, timezone_info)

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_path={@current_path} current_user={@current_user}>
      <div class="mx-auto max-w-3xl px-4 py-8 sm:px-6">
        <div class="flex flex-wrap items-end justify-between gap-3">
          <div>
            <p class="text-xs font-semibold uppercase tracking-wide text-zinc-500">Activity</p>
            <h1 class="mt-1 text-2xl font-semibold text-zinc-900">What did Maraithon do?</h1>
          </div>

          <div class="flex items-center gap-2">
            <.link
              patch={~p"/activity?day=today"}
              class={[
                "rounded-md px-2.5 py-1.5 text-xs font-semibold",
                @day == :today && "bg-zinc-900 text-white",
                @day != :today && "text-zinc-600 hover:bg-zinc-100"
              ]}
            >
              Today
            </.link>
            <.link
              patch={~p"/activity?day=yesterday"}
              class={[
                "rounded-md px-2.5 py-1.5 text-xs font-semibold",
                @day == :yesterday && "bg-zinc-900 text-white",
                @day != :yesterday && "text-zinc-600 hover:bg-zinc-100"
              ]}
            >
              Yesterday
            </.link>
            <form phx-change="jump_to_day" class="flex items-center">
              <input
                type="date"
                name="date"
                value={@selected_date && Date.to_iso8601(@selected_date)}
                class="rounded-md border border-zinc-300 px-2 py-1.5 text-xs text-zinc-700"
              />
            </form>
          </div>
        </div>

        <p class="mt-2 text-sm text-zinc-500">
          Showing {@summary.period.label}, your local day.
        </p>

        <dl class="mt-6 grid grid-cols-2 gap-x-6 gap-y-6 rounded-xl border border-zinc-200 bg-white p-6 sm:grid-cols-4">
          <.activity_stat :for={section <- @sections} label={section.title} value={section.count} />
        </dl>

        <div class="mt-8 space-y-8">
          <.activity_section :for={section <- @sections} section={section} />
        </div>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def handle_event("jump_to_day", %{"date" => ""}, socket), do: {:noreply, socket}

  def handle_event("jump_to_day", %{"date" => date}, socket) do
    {:noreply, push_patch(socket, to: ~p"/activity?day=#{date}")}
  end

  attr :label, :string, required: true
  attr :value, :integer, required: true

  defp activity_stat(assigns) do
    ~H"""
    <div>
      <dt class="text-xs font-medium text-zinc-500">{@label}</dt>
      <dd class="mt-1 text-xl font-semibold tracking-tight text-zinc-900">{@value}</dd>
    </div>
    """
  end

  attr :section, :map, required: true

  defp activity_section(assigns) do
    ~H"""
    <section>
      <div class="flex items-center gap-2">
        <h2 class="text-sm font-semibold text-zinc-900">{@section.title}</h2>
        <span class="text-xs text-zinc-400">{@section.count}</span>
      </div>

      <ul
        :if={@section.rows != []}
        class="mt-3 divide-y divide-zinc-100 rounded-xl border border-zinc-200 bg-white"
      >
        <li :for={row <- @section.rows} class="flex items-start justify-between gap-4 px-4 py-3">
          <div class="min-w-0 flex-1">
            <p class="truncate text-sm font-medium text-zinc-900">{row.primary}</p>
            <p :if={row.secondary} class="mt-0.5 text-sm text-zinc-500">{row.secondary}</p>
          </div>
          <span :if={row.timestamp} class="shrink-0 text-xs text-zinc-400">{row.timestamp}</span>
        </li>
      </ul>

      <p
        :if={@section.rows == []}
        class="mt-3 rounded-xl border border-dashed border-zinc-300 bg-white p-4 text-center text-sm text-zinc-500"
      >
        {@section.empty}
      </p>
    </section>
    """
  end
end
