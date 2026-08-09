defmodule Maraithon.ChiefOfStaff.ProjectionsTest do
  use ExUnit.Case, async: true

  alias Maraithon.ChiefOfStaff.ProjectionReceipt

  test "receipt changesets require exactly one target matching projection kind" do
    id = Ecto.UUID.generate()
    now = DateTime.utc_now()

    base = %{
      receipt_key: :crypto.strong_rand_bytes(32),
      agent_work_result_id: id,
      semantic_effect_id: Ecto.UUID.generate(),
      user_id: "projection@example.com",
      agent_id: Ecto.UUID.generate(),
      projection_key: "chief:projection:key",
      attrs_digest: :crypto.strong_rand_bytes(32),
      projected_at: now,
      inserted_at: now
    }

    refute ProjectionReceipt.changeset(
             %ProjectionReceipt{},
             Map.merge(base, %{projection_kind: "todo", todo_id: nil, decision_id: nil})
           ).valid?

    refute ProjectionReceipt.changeset(
             %ProjectionReceipt{},
             Map.merge(base, %{projection_kind: "todo", todo_id: id, decision_id: id})
           ).valid?

    assert ProjectionReceipt.changeset(
             %ProjectionReceipt{},
             Map.merge(base, %{projection_kind: "todo", todo_id: id, decision_id: nil})
           ).valid?
  end
end
