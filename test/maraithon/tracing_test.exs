defmodule Maraithon.TracingTest do
  use ExUnit.Case, async: true

  alias Maraithon.Tracing

  test "with_span/3 returns the inner function's value unchanged" do
    assert Tracing.with_span("test.span", %{foo: "bar"}, fn -> :inner_result end) ==
             :inner_result
  end

  test "with_span/3 returns the value even with empty attributes" do
    assert Tracing.with_span("test.span", %{}, fn -> 42 end) == 42
  end

  test "with_span/3 re-raises exceptions from the inner function" do
    assert_raise RuntimeError, "boom", fn ->
      Tracing.with_span("test.span", %{}, fn -> raise "boom" end)
    end
  end

  test "record_error/1 does not raise when there is no active span" do
    assert Tracing.record_error(:some_reason) == :ok
  end

  test "record_error/1 does not raise inside a span" do
    Tracing.with_span("test.span", %{}, fn ->
      assert Tracing.record_error({:assistant_harness_empty_tool_calls, []}) == :ok
    end)
  end
end
