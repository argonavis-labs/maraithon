defmodule Maraithon.Delegations.CostWindowTest do
  use ExUnit.Case, async: true
  alias Maraithon.LLM.CostMonitor

  test "six-hour scheduling drift does not erase the first six hours of spend" do
    samples = for n <- 0..4, do: %{"at" => n * 21_601, "total" => n * 2}
    window = CostMonitor.window_samples(samples, 5 * 21_601, 10)
    assert hd(window) == Enum.at(samples, 1)
    assert 10 - hd(window)["total"] == 8
    assert length(window) <= 6
  end

  test "an exact 24-hour boundary does not include an older sample" do
    samples = for n <- 0..5, do: %{"at" => n * 21_600, "total" => n}
    window = CostMonitor.window_samples(samples, 6 * 21_600, 6)
    assert hd(window)["at"] == 2 * 21_600
    assert 6 - hd(window)["total"] == 4
  end

  test "new monitoring starts with only the available history" do
    assert CostMonitor.window_samples([], 100, 8) == [%{"at" => 100, "total" => 8}]
    assert hd(CostMonitor.window_samples([%{"at" => 100, "total" => 8}], 200, 9))["at"] == 100
  end
end
