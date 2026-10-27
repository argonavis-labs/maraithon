defmodule Maraithon.Todos.Consolidation do
  @moduledoc """
  Keeps one canonical todo for model-confirmed duplicate work. Original rows
  and their source evidence remain addressable as aliases, without teaching
  the relevance learner that the underlying obligation was unimportant.
  """
  import Ecto.Query
  alias Maraithon.Repo
  alias Maraithon.Todos.Todo

  @bookkeeping ~w(consolidated_duplicate_todos duplicate_of_todo_id duplicate_repair)

  def alias?(%Todo{metadata: metadata}), do: is_binary(metadata["duplicate_of_todo_id"])

  def canonical(%Todo{} = todo), do: canonical(todo, MapSet.new())

  defp canonical(todo, seen) do
    case todo.metadata["duplicate_of_todo_id"] do
      nil ->
        todo

      id when is_binary(id) ->
        if MapSet.member?(seen, id) or MapSet.size(seen) >= 8 do
          raise "invalid todo consolidation chain"
        end

        case Repo.get_by(Todo, id: id, user_id: todo.user_id) do
          %Todo{} = parent -> canonical(parent, MapSet.put(seen, todo.id))
          nil -> raise "missing canonical todo"
        end
    end
  end

  def preserve_metadata(existing, incoming) do
    Map.merge(incoming || %{}, Map.take(existing.metadata || %{}, @bookkeeping))
  end

  def strip_metadata(metadata), do: Map.drop(metadata, @bookkeeping)

  @doc "Runs inside the intake write transaction, after canonical rows are upserted."
  def apply!(user_id, groups) do
    Enum.each(groups, fn group ->
      target = Repo.get_by!(Todo, user_id: user_id, dedupe_key: group.dedupe_key) |> canonical()
      ids = [target.id | group.duplicate_ids] |> Enum.uniq() |> Enum.sort()

      rows =
        Repo.all(
          from t in Todo,
            where: t.user_id == ^user_id and t.id in ^ids,
            order_by: t.id,
            lock: "FOR UPDATE"
        )

      if length(rows) != length(ids), do: Repo.rollback(:todo_merge_target_missing)
      target = Enum.find(rows, &(&1.id == target.id))
      duplicates = Enum.reject(rows, &(&1.id == target.id))

      if Enum.any?(duplicates, &(&1.owner_user_id != target.owner_user_id)),
        do: Repo.rollback(:todo_merge_owner_mismatch)

      # FYI is not an opposing obligation. Older intake sometimes saved an
      # informational copy of the same request alongside its actionable todo.
      # Still refuse to collapse work owed by the user into work owed to them.
      obligation_directions =
        [target | duplicates]
        |> Enum.map(& &1.direction)
        |> Enum.reject(&(&1 == "fyi"))
        |> Enum.uniq()

      if length(obligation_directions) > 1,
        do: Repo.rollback(:todo_merge_direction_mismatch)

      now = DateTime.utc_now()

      evidence =
        Enum.map(duplicates, fn todo ->
          %{
            "id" => todo.id,
            "title" => todo.title,
            "source" => todo.source,
            "source_item_id" => todo.source_item_id,
            "source_ref" => todo.metadata["source_ref"],
            "dedupe_key" => todo.dedupe_key
          }
        end)

      history =
        ((target.metadata["consolidated_duplicate_todos"] || []) ++ evidence)
        |> Enum.uniq_by(& &1["id"])

      target
      |> Todo.changeset(%{
        metadata: Map.put(target.metadata, "consolidated_duplicate_todos", history)
      })
      |> Repo.update!()

      Enum.each(duplicates, fn duplicate ->
        metadata =
          duplicate.metadata
          |> Map.put("duplicate_of_todo_id", target.id)
          |> Map.put("duplicate_repair", %{
            "reason" => group.reason,
            "merged_at" => DateTime.to_iso8601(now),
            "original_status" => duplicate.status
          })

        duplicate
        |> Todo.changeset(%{
          status:
            if(duplicate.status in ["done", "dismissed"], do: duplicate.status, else: "dismissed"),
          closed_at: duplicate.closed_at || now,
          snoozed_until: nil,
          metadata: metadata
        })
        |> Repo.update!()
      end)
    end)
  end
end
