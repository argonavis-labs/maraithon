defmodule MaraithonWeb.TodoCalendarCard do
  @moduledoc "Public calendar previews expose the exact action awaiting confirmation."

  def build(action, base) do
    payload = action.payload || %{}

    Map.merge(base, %{
      "provider" => "calendar",
      "title" => payload["title"] || "Calendar event",
      "body" => payload["description"],
      "start_at" => payload["start_at"],
      "end_at" => payload["end_at"],
      "timezone" => payload["timezone"],
      "action_type" => action.action_type,
      "status" => status(action.status, base),
      "send_label" => label(action.action_type)
    })
  end

  defp status("executed", _), do: "Saved to calendar"
  defp status("awaiting_confirmation", %{"status" => "Expired"}), do: "Expired"
  defp status("awaiting_confirmation", _), do: "Ready for review"
  defp status("confirmed", _), do: "Saving"
  defp status("rejected", _), do: "Cancelled"
  defp status("expired", _), do: "Expired"
  defp status(_, base), do: base["status"] || "Needs review"
  defp label("calendar_create_event"), do: "Book event"
  defp label("calendar_update_event"), do: "Update event"
  defp label(_), do: "Cancel event"
end
