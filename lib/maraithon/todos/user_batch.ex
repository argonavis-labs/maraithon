defmodule Maraithon.Todos.UserBatch do
  @moduledoc false

  import Ecto.Query

  alias Maraithon.Repo
  alias Maraithon.Todos.Todo

  @max_users 10
  @max_explicit_scan 1_000
  @open_statuses ~w(open snoozed)

  @max_cursor_key_bytes 128

  def load_cursor(sweep_key)
      when is_binary(sweep_key) and byte_size(sweep_key) <= @max_cursor_key_bytes do
    from(cursor in "runtime_sweep_cursors",
      where: field(cursor, :sweep_key) == ^sweep_key,
      select: field(cursor, :after_user_id),
      limit: 1
    )
    |> Repo.one()
    |> bounded_cursor()
  rescue
    _error -> nil
  end

  def load_cursor(_sweep_key), do: nil

  def record_cursor(sweep_key, after_user_id)
      when is_binary(sweep_key) and byte_size(sweep_key) <= @max_cursor_key_bytes and
             is_binary(after_user_id) and byte_size(after_user_id) <= 1_280 do
    now = DateTime.utc_now()

    Repo.insert_all(
      "runtime_sweep_cursors",
      [
        %{
          sweep_key: sweep_key,
          after_user_id: after_user_id,
          inserted_at: now,
          updated_at: now
        }
      ],
      on_conflict: [set: [after_user_id: after_user_id, updated_at: now]],
      conflict_target: [:sweep_key]
    )

    :ok
  rescue
    _error -> :error
  end

  def record_cursor(_sweep_key, _after_user_id), do: :error

  def open_todo_user_ids(opts \\ []) when is_list(opts) do
    open_todo_user_ids_from_query(base_query(), opts)
  end

  def open_todo_user_ids_without_source_account(opts \\ []) when is_list(opts) do
    query = where(base_query(), [todo], is_nil(todo.source_account_id))
    open_todo_user_ids_from_query(query, opts)
  end

  defp open_todo_user_ids_from_query(query, opts) do
    case Keyword.get(opts, :user_ids) do
      user_ids when is_list(user_ids) ->
        user_ids
        |> Enum.take(@max_explicit_scan)
        |> Enum.filter(&(is_binary(&1) and byte_size(&1) <= 1_280))
        |> Enum.uniq()
        |> Enum.take(@max_users)

      _other ->
        cursor = bounded_cursor(Keyword.get(opts, :after_user_id))

        first =
          query
          |> maybe_after(cursor)
          |> limit(^@max_users)
          |> Repo.all()

        remaining = @max_users - length(first)

        if remaining > 0 and is_binary(cursor) do
          wrap =
            query
            |> where([todo], todo.user_id <= ^cursor)
            |> limit(^remaining)
            |> Repo.all()

          first ++ wrap
        else
          first
        end
    end
  end

  defp base_query do
    Todo
    |> where([todo], todo.status in ^@open_statuses)
    |> select([todo], todo.user_id)
    |> distinct(true)
    |> order_by([todo], asc: todo.user_id)
  end

  defp bounded_cursor(value) when is_binary(value) and byte_size(value) <= 1_280, do: value
  defp bounded_cursor(_value), do: nil

  defp maybe_after(query, nil), do: query
  defp maybe_after(query, cursor), do: where(query, [todo], todo.user_id > ^cursor)
end
