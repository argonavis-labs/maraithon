defmodule Maraithon.Crm.Ingest.WindowPolicyTest do
  use ExUnit.Case, async: true

  alias Maraithon.Crm.Ingest.WindowPolicy

  defp window(observation_count, opened_minutes_ago) do
    opened_at = DateTime.add(DateTime.utc_now(), -opened_minutes_ago * 60, :second)
    %{observation_count: observation_count, opened_at: opened_at}
  end

  describe "ready?/4" do
    test "returns false for an empty fresh window" do
      refute WindowPolicy.ready?(window(0, 0), DateTime.utc_now(), 0, false)
    end

    test "returns true when observation count reaches the size threshold" do
      assert WindowPolicy.ready?(
               window(WindowPolicy.max_observations(), 0),
               DateTime.utc_now(),
               0,
               false
             )
    end

    test "returns false for a young window below the size threshold" do
      refute WindowPolicy.ready?(window(10, 1), DateTime.utc_now(), 0, false)
    end

    test "returns true when an aged window has at least one observation" do
      now = DateTime.utc_now()
      aged = window(3, WindowPolicy.max_age_minutes() + 1)
      assert WindowPolicy.ready?(aged, now, 0, false)
    end

    test "returns false for an aged but empty window" do
      now = DateTime.utc_now()
      aged_empty = window(0, WindowPolicy.max_age_minutes() + 1)
      refute WindowPolicy.ready?(aged_empty, now, 0, false)
    end

    test "driver_force? flushes any non-empty window" do
      assert WindowPolicy.ready?(window(1, 0), DateTime.utc_now(), 0, true)
    end

    test "driver_force? does not flush an empty window" do
      refute WindowPolicy.ready?(window(0, 0), DateTime.utc_now(), 0, true)
    end

    test "rate cap blocks flushing even when size threshold is reached" do
      refute WindowPolicy.ready?(
               window(WindowPolicy.max_observations(), 0),
               DateTime.utc_now(),
               WindowPolicy.max_flushes_per_hour(),
               false
             )
    end

    test "rate cap blocks driver-forced flushes too" do
      refute WindowPolicy.ready?(
               window(10, 0),
               DateTime.utc_now(),
               WindowPolicy.max_flushes_per_hour(),
               true
             )
    end
  end
end
