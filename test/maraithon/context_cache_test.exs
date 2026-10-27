defmodule Maraithon.ContextCacheTest do
  use ExUnit.Case, async: false

  alias Maraithon.ContextCache

  setup do
    on_exit(fn -> ContextCache.reset() end)
    :ok
  end

  describe "put_digest/3 and get_digest/1" do
    test "stores and retrieves a digest" do
      digest = %{top_todos: [%{id: "todo_1", title: "Renew domain"}], waiting_on: []}
      :ok = ContextCache.put_digest("user-1", digest)

      assert %{
               top_todos: [%{id: "todo_1"}],
               generated_at: %DateTime{}
             } = ContextCache.get_digest("user-1")
    end

    test "returns nil for unknown users" do
      assert ContextCache.get_digest("nobody") == nil
    end

    test "returns nil after the ttl expires" do
      :ok = ContextCache.put_digest("user-2", %{top_todos: []}, 1)
      Process.sleep(5)
      assert ContextCache.get_digest("user-2") == nil
    end

    test "later put overrides earlier digest for the same user" do
      :ok = ContextCache.put_digest("user-3", %{top_todos: [%{id: "old"}]})
      :ok = ContextCache.put_digest("user-3", %{top_todos: [%{id: "new"}]})

      assert %{top_todos: [%{id: "new"}]} = ContextCache.get_digest("user-3")
    end

    test "forget_digest removes a stored digest" do
      :ok = ContextCache.put_digest("user-4", %{top_todos: []})
      assert ContextCache.get_digest("user-4")
      :ok = ContextCache.forget_digest("user-4")
      assert ContextCache.get_digest("user-4") == nil
    end
  end
end
