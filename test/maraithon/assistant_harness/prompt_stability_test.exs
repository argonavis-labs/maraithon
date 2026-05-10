defmodule Maraithon.AssistantHarness.PromptStabilityTest do
  use ExUnit.Case, async: true

  alias Maraithon.AssistantHarness.PromptStability

  describe "encode!/1" do
    test "produces the same JSON regardless of input map ordering" do
      a = %{"z" => 1, "a" => 2, "m" => %{"y" => 3, "x" => 4}}
      b = %{"a" => 2, "m" => %{"x" => 4, "y" => 3}, "z" => 1}

      assert PromptStability.encode!(a) == PromptStability.encode!(b)
    end

    test "sorts maps recursively" do
      json = PromptStability.encode!(%{"z" => 1, "a" => %{"d" => 4, "b" => 5}})
      assert json == ~s({"a":{"b":5,"d":4},"z":1})
    end

    test "preserves list order" do
      assert PromptStability.encode!(["c", "a", "b"]) == ~s(["c","a","b"])
    end

    test "normalizes datetimes to ISO8601" do
      assert PromptStability.encode!(~U[2026-05-09 12:34:56Z]) ==
               ~s("2026-05-09T12:34:56Z")
    end

    test "treats atom keys and string keys as equivalent" do
      a = %{title: "x", count: 3}
      b = %{"title" => "x", "count" => 3}

      assert PromptStability.encode!(a) == PromptStability.encode!(b)
    end
  end
end
