defmodule Maraithon.ContextEngineTest do
  use ExUnit.Case, async: true

  alias Maraithon.ContextEngine
  alias Maraithon.ContextEngine.Telegram

  test "compacts oversized context deterministically and reports omitted evidence" do
    context = %{
      todos: Enum.map(1..5, &%{id: "todo-#{&1}"}),
      source_freshness: [
        %{provider: "gmail", account_label: "Work Gmail", status: "fresh"},
        %{provider: "slack", account_label: "Agora", status: "stale", stale_reason: "old"}
      ]
    }

    budget = %{
      open_loops: %{max_items: 2, fields: [:todos]},
      source_evidence: %{max_items: 10, fields: [:source_freshness]}
    }

    {compacted, diagnostics} = Telegram.compact(context, budget)

    assert Enum.map(compacted.todos, & &1.id) == ["todo-1", "todo-2"]
    assert get_in(diagnostics, [:fields, "todos", "omitted_count"]) == 3
    assert get_in(diagnostics, [:fields, "todos", "truncated"]) == true

    assert get_in(diagnostics, [:source_freshness, :aggregate_status]) == "stale"

    assert [%{"provider" => "slack", "account_label" => "Agora", "status" => "stale"}] =
             get_in(diagnostics, [:source_freshness, :stale_or_broken])
  end

  test "facade exposes engine budget and context slices" do
    context = %{
      deep_memory: [%{id: "mem-1"}],
      open_loops: %{totals: %{open_todos: 1}},
      todos: [%{id: "todo-1"}]
    }

    assert ContextEngine.budget(context).memory.fields == [
             :deep_memory,
             :operator_memory,
             :user_memory
           ]

    assert ContextEngine.memory_context(context).deep_memory == [%{id: "mem-1"}]
    assert ContextEngine.open_loop_context(context).todos == [%{id: "todo-1"}]
  end
end
