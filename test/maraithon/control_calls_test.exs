defmodule Maraithon.ControlCallsTest do
  use Maraithon.DataCase, async: true

  alias Maraithon.ControlCalls
  alias Maraithon.ControlCalls.ControlCall

  test "replays completed idempotent calls without running the function again" do
    Process.put(:control_call_runs, 0)

    fun = fn ->
      count = Process.get(:control_call_runs, 0) + 1
      Process.put(:control_call_runs, count)
      {:ok, %{count: count}}
    end

    attrs = %{
      method: "tools.call:test",
      idempotency_key: "unit-test-key-1",
      request: %{"params" => %{"value" => 1}}
    }

    assert {:ok, %{"count" => 1}, replay?: false} = ControlCalls.run(attrs, fun)
    assert {:ok, %{"count" => 1}, replay?: true} = ControlCalls.run(attrs, fun)
    assert Process.get(:control_call_runs) == 1
  end

  test "purges expired idempotency keys" do
    expired_at = DateTime.utc_now() |> DateTime.add(-60, :second)

    {:ok, _call} =
      %ControlCall{}
      |> ControlCall.changeset(%{
        method: "tools.call:expired",
        idempotency_key: "expired-key-1",
        request_hash: String.duplicate("a", 64),
        status: "completed",
        result: %{"ok" => true},
        expires_at: expired_at,
        completed_at: expired_at
      })
      |> Repo.insert()

    assert {:ok, 1} = ControlCalls.purge_expired(DateTime.utc_now())
  end
end
