defmodule MaraithonWeb.StreamLive do
  use MaraithonWeb, :live_view

  alias Maraithon.Todos

  @event_limit 200

  @impl true
  def mount(_params, _session, socket) do
    events = Todos.list_activity_for_user(socket.assigns.current_user.id, limit: @event_limit)

    {:ok, assign(socket, :days, group_by_day(events))}
  end

  defp group_by_day(events) do
    events
    |> Enum.group_by(fn event -> DateTime.to_date(event.occurred_at) end)
    |> Enum.sort_by(fn {date, _events} -> date end, {:desc, Date})
    |> Enum.map(fn {date, day_events} ->
      %{
        date: date,
        title: day_title(date),
        events: Enum.sort_by(day_events, & &1.occurred_at, {:desc, DateTime})
      }
    end)
  end

  defp day_title(date) do
    cond do
      date == Date.utc_today() -> "Today"
      date == Date.add(Date.utc_today(), -1) -> "Yesterday"
      true -> Calendar.strftime(date, "%A, %b %-d")
    end
  end

  defp event_phrase(event) do
    actor = if event.actor_type == "user", do: "You", else: "Maraithon"

    case event.event_type do
      "created" -> "#{actor} added this"
      "marked_done" -> "#{actor} checked this off"
      "deleted" -> "#{actor} removed this"
      _other -> "#{actor} updated this"
    end
  end

  defp event_note(%{metadata: %{"note" => note}}) when is_binary(note) and note != "", do: note
  defp event_note(_event), do: nil

  defp event_tint("created"), do: "text-blue-600"
  defp event_tint("marked_done"), do: "text-green-600"
  defp event_tint("deleted"), do: "text-red-500"
  defp event_tint(_event_type), do: "text-zinc-400"

  @impl true
  def render(assigns) do
    ~H"""
    <div class="mx-auto max-w-3xl px-4 py-8 sm:px-6">
      <h1 class="text-2xl font-semibold text-zinc-900">Stream</h1>
      <p class="mt-1 text-sm text-zinc-500">
        Work items being added and checked off, by you or by Maraithon.
      </p>

      <div :if={@days == []} class="mt-8 rounded-xl border border-dashed border-zinc-300 bg-white p-8 text-center text-sm text-zinc-500">
        Activity will appear here as work items are created and completed.
      </div>

      <section :for={day <- @days} class="mt-8">
        <h2 class="text-sm font-semibold text-zinc-900">{day.title}</h2>
        <ul class="mt-3 divide-y divide-zinc-100 rounded-xl border border-zinc-200 bg-white">
          <li :for={event <- day.events} class="flex items-start gap-3 px-4 py-3">
            <span class={"mt-1 text-lg leading-none #{event_tint(event.event_type)}"}>•</span>
            <div class="min-w-0 flex-1">
              <p class="truncate text-sm font-medium text-zinc-900">
                {event.todo_title || "Untitled work item"}
              </p>
              <p :if={event_note(event)} class="mt-0.5 text-sm text-zinc-500">
                {event_note(event)}
              </p>
              <p class="mt-0.5 text-xs text-zinc-400">
                {event_phrase(event)} · {Calendar.strftime(event.occurred_at, "%-I:%M %p")}
              </p>
            </div>
          </li>
        </ul>
      </section>
    </div>
    """
  end
end
