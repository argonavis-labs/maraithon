defmodule Maraithon.SnapshotBudgetAssertions do
  @moduledoc false

  import ExUnit.Assertions

  alias Maraithon.Behaviors.SnapshotTrim
  alias Maraithon.Runtime.SnapshotFormat

  def assert_snapshot_budget(state, max_bytes, opts \\ []) do
    snapshot_fun = Keyword.get(opts, :snapshot, &SnapshotTrim.trim/1)
    identity? = Keyword.get(opts, :identity?, true)
    snapshot_state = snapshot_fun.(state)

    if identity? do
      assert snapshot_state === state,
             "snapshot_state/1 changed a budget-compliant state; raw or oversized content remains"
    end

    assert {:ok, envelope, bytes} = SnapshotFormat.encode(snapshot_state)

    assert bytes <= max_bytes,
           "snapshot used #{bytes} bytes, exceeding the #{max_bytes}-byte budget"

    assert {:ok, decoded} = SnapshotFormat.decode(envelope)
    assert decoded === snapshot_state

    bytes
  end
end
