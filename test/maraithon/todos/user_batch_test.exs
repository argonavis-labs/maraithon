defmodule Maraithon.Todos.UserBatchTest do
  use Maraithon.DataCase, async: true

  alias Maraithon.Accounts
  alias Maraithon.Todos
  alias Maraithon.Todos.UserBatch

  test "durable lexical cursor reaches users beyond the first two batches" do
    users =
      Enum.map(1..25, fn index ->
        user_id =
          "user-batch-#{String.pad_leading(Integer.to_string(index), 2, "0")}-#{Ecto.UUID.generate()}@example.com"

        {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

        {:ok, [_todo]} =
          Todos.upsert_many(user_id, [
            %{
              "source" => "test",
              "title" => "Open work #{index}",
              "summary" => "Open work for bounded user rotation.",
              "dedupe_key" => "user-batch:#{index}:#{Ecto.UUID.generate()}"
            }
          ])

        user_id
      end)
      |> Enum.sort()

    first = UserBatch.open_todo_user_ids()
    assert first == Enum.take(users, 10)
    assert :ok = UserBatch.record_cursor("test_user_batch", List.last(first))

    cursor = UserBatch.load_cursor("test_user_batch")
    assert cursor == List.last(first)

    second = UserBatch.open_todo_user_ids(after_user_id: cursor)
    assert second == users |> Enum.drop(10) |> Enum.take(10)

    third = UserBatch.open_todo_user_ids(after_user_id: List.last(second))
    assert Enum.take(third, 5) == Enum.drop(users, 20)
    assert Enum.drop(third, 5) == Enum.take(users, 5)
  end
end
