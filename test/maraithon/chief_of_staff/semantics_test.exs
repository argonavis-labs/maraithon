defmodule Maraithon.ChiefOfStaff.SemanticsTest do
  use Maraithon.DataCase, async: true

  alias Maraithon.ChiefLineageFixtures
  alias Maraithon.ChiefOfStaff.AcquisitionStore
  alias Maraithon.ChiefOfStaff.Projections
  alias Maraithon.ChiefOfStaff.Semantics

  test "effect identity is deterministic over sorted immutable source revisions" do
    fixture = ChiefLineageFixtures.base("semantics")

    assert {:ok, _page, envelopes, :inserted} =
             ChiefLineageFixtures.terminal_page(fixture, [
               ChiefLineageFixtures.source_envelope(fixture, "a"),
               ChiefLineageFixtures.source_envelope(fixture, "b")
             ])

    assert {:ok, complete} = AcquisitionStore.seal_complete(fixture.acquisition, "cursor-1")
    [first, second] = envelopes

    attrs = %{
      acquisition_run_id: complete.id,
      kind: "decision",
      subject_key: "thread:#{fixture.unique}",
      contract_version: 1,
      extractor_version: "fixture-v1",
      payload: %{"question" => "Choose a path"}
    }

    assert {:ok, effect, :inserted} = Semantics.put_effect(attrs, [second.id, first.id])
    assert byte_size(effect.effect_key) == 32
    assert byte_size(effect.payload_digest) == 32

    assert {:ok, duplicate, :duplicate} = Semantics.put_effect(attrs, [first.id, second.id])
    assert duplicate.id == effect.id

    assert {:error, :semantic_effect_idempotency_conflict} =
             Semantics.put_effect(
               put_in(attrs, [:payload, "question"], "Changed question"),
               [first.id, second.id]
             )

    assert {:ok, decision, :inserted} =
             Projections.put_decision(effect, %{
               decision_identity: "decision:#{fixture.unique}",
               kind: "choice",
               payload: %{"options" => ["a", "b"]}
             })

    assert byte_size(decision.decision_key) == 32

    assert {:ok, same_decision, :duplicate} =
             Projections.put_decision(effect, %{
               decision_identity: "decision:#{fixture.unique}",
               kind: "choice",
               payload: %{"options" => ["a", "b"]}
             })

    assert same_decision.id == decision.id

    assert {:error, :decision_idempotency_conflict} =
             Projections.put_decision(effect, %{
               decision_identity: "decision:changed",
               kind: "choice",
               payload: %{"options" => ["a", "b"]}
             })
  end

  test "semantic effects reject envelopes outside their complete acquisition" do
    fixture = ChiefLineageFixtures.base("semantics-owner")
    other = ChiefLineageFixtures.base("semantics-other")

    assert {:ok, _page, [_own], :inserted} =
             ChiefLineageFixtures.terminal_page(fixture, [
               ChiefLineageFixtures.source_envelope(fixture)
             ])

    assert {:ok, _other_page, [outside], :inserted} =
             ChiefLineageFixtures.terminal_page(other, [
               ChiefLineageFixtures.source_envelope(other)
             ])

    assert {:ok, complete} = AcquisitionStore.seal_complete(fixture.acquisition, "cursor-1")

    assert {:error, :semantic_source_not_in_acquisition} =
             Semantics.put_effect(
               %{
                 acquisition_run_id: complete.id,
                 kind: "todo",
                 subject_key: "subject",
                 contract_version: 1,
                 extractor_version: "fixture-v1",
                 payload: %{}
               },
               [outside.id]
             )
  end
end
