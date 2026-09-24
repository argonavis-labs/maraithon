defmodule Maraithon.Todos.MeetingRelevanceSweep do
  @moduledoc """
  Bounded, rotating cleanup of calendar-only and expired meeting suggestions.
  Runs on the existing provider lane without model calls or personal feedback.
  """
  import Ecto.Query
  alias Maraithon.Repo
  alias Maraithon.Todos
  alias Maraithon.Todos.{MeetingRelevance, Todo, UserBatch}

  @batch_size 100
  @statuses ~w(triage open snoozed)

  def run_for_user(user_id, opts \\ []) do
    now = Keyword.get(opts, :now) || DateTime.utc_now()
    cursor_key = "meeting_relevance:#{user_id}"
    cursor = Keyword.get(opts, :after_id, UserBatch.load_cursor(cursor_key))
    dry_run? = Keyword.get(opts, :dry_run, false)

    base =
      from t in Todo,
        where: t.user_id == ^user_id and t.status in ^@statuses,
        order_by: [asc: t.id],
        limit: @batch_size

    rows = if cursor, do: Repo.all(where(base, [t], t.id > ^cursor)), else: Repo.all(base)
    rows = if rows == [] and cursor, do: Repo.all(base), else: rows

    result =
      Enum.reduce_while(rows, {:ok, %{checked: length(rows), dismissed: 0, matches: []}}, fn todo,
                                                                                             {:ok,
                                                                                              acc} ->
        case MeetingRelevance.reason(todo, now: now) do
          nil ->
            {:cont, {:ok, acc}}

          reason ->
            provenance = %{
              "policy" => "meeting_relevance",
              "version" => MeetingRelevance.version(),
              "reason" => reason
            }

            outcome =
              if dry_run?,
                do: {:ok, todo},
                else:
                  Todos.dismiss_if_current(todo, provenance, note: MeetingRelevance.note(reason))

            case outcome do
              {:ok, _} ->
                match = %{id: todo.id, reason: reason}

                {:cont,
                 {:ok,
                  %{
                    acc
                    | dismissed: acc.dismissed + if(dry_run?, do: 0, else: 1),
                      matches: [match | acc.matches]
                  }}}

              {:error, reason} when reason in [:stale_todo, :todo_no_longer_open, :not_found] ->
                {:cont, {:ok, acc}}

              {:error, _} = error ->
                {:halt, error}
            end
        end
      end)

    with {:ok, report} <- result do
      if not dry_run? and rows != [], do: UserBatch.record_cursor(cursor_key, List.last(rows).id)
      {:ok, Map.put(report, :next_cursor, if(rows == [], do: nil, else: List.last(rows).id))}
    end
  end
end
