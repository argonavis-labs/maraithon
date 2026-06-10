defmodule Maraithon.Briefs.Digest do
  @moduledoc """
  Projects the user's current open work under the morning briefing as
  grouped action cards: Slack, Gmail, Calendar, decisions to make, and
  everything else. One grouping definition shared by the web briefing
  page and the mobile Today tab.
  """

  alias Maraithon.ActionCards
  alias Maraithon.SourceFreshness
  alias Maraithon.Todos
  alias Maraithon.Todos.AttentionRanker

  @open_statuses ~w(open snoozed)
  @max_items 60

  @group_titles %{
    "decisions" => "Decisions to make",
    "gmail" => "Gmail",
    "slack" => "Slack",
    "calendar" => "Calendar",
    "more" => "Everything else"
  }
  @group_order ~w(decisions gmail slack calendar more)

  @doc """
  Returns ordered groups of `%{todo, card}` entries for the user's open
  work. Empty groups are omitted.
  """
  def groups_for_user(user_id) when is_binary(user_id) do
    snapshots = SourceFreshness.compact_for_prompt(user_id)

    todos =
      user_id
      |> Todos.list_for_user(statuses: @open_statuses, limit: @max_items)
      |> AttentionRanker.sort()

    entries =
      Enum.map(todos, fn todo ->
        card = ActionCards.for_todo(todo, source_health_snapshots: snapshots)
        %{todo: todo, card: card, group: group_for(todo, card)}
      end)

    @group_order
    |> Enum.map(fn key ->
      %{
        key: key,
        title: Map.fetch!(@group_titles, key),
        entries: entries |> Enum.filter(&(&1.group == key)) |> Enum.map(&Map.drop(&1, [:group]))
      }
    end)
    |> Enum.reject(&(&1.entries == []))
  end

  def groups_for_user(_user_id), do: []

  defp group_for(todo, card) do
    cond do
      card["attention_mode"] == "stale_check" -> "decisions"
      decision_obligation?(todo) -> "decisions"
      todo.source == "gmail" or todo.kind == "gmail_triage" -> "gmail"
      todo.source == "slack" -> "slack"
      todo.source in ["calendar", "google_calendar", "calendar_local"] -> "calendar"
      calendar_detector?(todo) -> "calendar"
      true -> "more"
    end
  end

  defp decision_obligation?(todo) do
    metadata = todo.metadata || %{}
    Map.get(metadata, "obligation_type") in ["decision_required", "approval_required"]
  end

  defp calendar_detector?(todo) do
    Map.get(todo.metadata || %{}, "detector") == "calendar_conflict"
  end
end
