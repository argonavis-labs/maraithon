defmodule Maraithon.Delegations.SchedulingLinks do
  @moduledoc "User-owned meeting links, frozen with the offer rather than chosen by the model."
  alias Maraithon.{AccountCategories, CalendarLinks, Repo}
  alias Maraithon.Delegations.Preferences
  alias Maraithon.Todos.Todo

  def snapshot(context, duration) do
    user_id = context.delegation.user_id
    prefs = Preferences.get(user_id)
    todo = Repo.get_by(Todo, id: context.delegation.todo_id, user_id: user_id)

    link =
      if prefs["calendar_link_id"] in [nil, ""] do
        category = if todo, do: AccountCategories.for_todo(todo)

        category =
          case category do
            "personal" -> "personal"
            "work" -> "business"
            _ -> nil
          end

        CalendarLinks.best_link_for(user_id, todo, context.grant.data["scope"]["instruction"],
          duration_minutes: duration,
          context: category,
          exact: true
        )
      else
        Enum.find(CalendarLinks.list_active_links(user_id), fn link ->
          link.id == prefs["calendar_link_id"] and link.duration_minutes == duration
        end)
      end

    %{
      "video_link" => prefs["video_link"],
      "booking_link" =>
        if(link,
          do: %{"url" => link.url, "label" => link.label, "duration_min" => link.duration_minutes}
        )
    }
  end

  def invitation_description(links) do
    case links["video_link"] do
      url when is_binary(url) and url != "" -> "Arranged by Maraithon.\n\nJoin: " <> url
      _ -> "Arranged by Maraithon."
    end
  end
end
