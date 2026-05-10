defmodule Maraithon.Runtime.HeartbeatScheduleTest do
  use ExUnit.Case, async: true

  alias Maraithon.Runtime.HeartbeatSchedule

  describe "phase_offset_ms/2" do
    test "is deterministic for a given agent and interval" do
      assert HeartbeatSchedule.phase_offset_ms("agent-a", 60_000) ==
               HeartbeatSchedule.phase_offset_ms("agent-a", 60_000)
    end

    test "different agents land on different offsets within the interval" do
      offsets = for id <- 1..200, do: HeartbeatSchedule.phase_offset_ms("agent-#{id}", 60_000)

      assert Enum.all?(offsets, &(&1 >= 0 and &1 < 60_000))

      # Distribution sanity: at least 100 distinct offsets across 200 agents
      # over a 60-second interval (collisions are fine, but not all the same).
      assert length(Enum.uniq(offsets)) >= 100
    end

    test "stays within [0, interval_ms)" do
      for interval_ms <- [1_000, 5_000, 60_000, 600_000] do
        offset = HeartbeatSchedule.phase_offset_ms("any-agent", interval_ms)
        assert offset >= 0
        assert offset < interval_ms
      end
    end
  end

  describe "next_fire_at/3" do
    test "is strictly in the future" do
      now = DateTime.utc_now()
      next = HeartbeatSchedule.next_fire_at("agent-a", 60_000, now)

      assert DateTime.compare(next, now) == :gt
    end

    test "lands on the agent's phase boundary" do
      now = ~U[2026-05-09 10:00:00.000Z]
      interval_ms = 60_000
      offset = HeartbeatSchedule.phase_offset_ms("agent-a", interval_ms)

      next = HeartbeatSchedule.next_fire_at("agent-a", interval_ms, now)
      next_ms = DateTime.to_unix(next, :millisecond)

      assert rem(next_ms - offset, interval_ms) == 0
    end

    test "two different agents on the same interval don't necessarily fire together" do
      now = ~U[2026-05-09 10:00:00.000Z]
      interval_ms = 60_000

      a = HeartbeatSchedule.next_fire_at("agent-aaaa", interval_ms, now)
      b = HeartbeatSchedule.next_fire_at("agent-bbbb", interval_ms, now)

      # Almost always different — and even if they collide, they at least
      # land on the agents' respective phases (which are different).
      assert DateTime.compare(a, b) != :eq
    end
  end
end
