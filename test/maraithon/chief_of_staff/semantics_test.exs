defmodule Maraithon.ChiefOfStaff.SemanticsTest do
  use Maraithon.DataCase, async: true

  alias Maraithon.ChiefLineageFixtures
  alias Maraithon.ChiefOfStaff.AcquisitionStore
  alias Maraithon.ChiefOfStaff.Projections
  alias Maraithon.ChiefOfStaff.SemanticEffect
  alias Maraithon.ChiefOfStaff.Semantics
  alias Maraithon.Repo
  alias Maraithon.Runtime.AgentDirectives

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

  test "the same provider revision produces a distinct semantic occurrence in a later acquisition" do
    fixture = ChiefLineageFixtures.base("semantics-replay")
    envelope_attrs = ChiefLineageFixtures.source_envelope(fixture, "replayed")

    assert {:ok, _first_page, [envelope], :inserted} =
             ChiefLineageFixtures.terminal_page(fixture, [envelope_attrs])

    assert {:ok, first_complete} =
             AcquisitionStore.seal_complete(fixture.acquisition, "cursor-1")

    effect_attrs = %{
      acquisition_run_id: first_complete.id,
      kind: "todo",
      subject_key: "thread:#{fixture.unique}",
      contract_version: 1,
      extractor_version: "fixture-v1",
      payload: %{"title" => "Follow up"}
    }

    assert {:ok, first_effect, :inserted} =
             Semantics.put_effect(effect_attrs, [envelope.id])

    assert {:ok, later_acquisition, :inserted} =
             AcquisitionStore.begin_run(%{
               user_id: fixture.user_id,
               agent_id: fixture.agent.id,
               agent_directive_id: fixture.directive.id,
               runtime_ingress_receipt_id: fixture.receipt.id,
               connected_account_id: fixture.account.id,
               source_cursor_id: fixture.cursor.id,
               cursor_kind: fixture.cursor.kind,
               provider: fixture.provider,
               source: fixture.acquisition.source,
               scope_key: fixture.acquisition.scope_key,
               request_key: "replay-request-#{fixture.unique}",
               contract_version: 1
             })

    later_fixture = %{fixture | acquisition: later_acquisition}

    assert {:ok, _later_page, [same_envelope], :inserted} =
             ChiefLineageFixtures.terminal_page(later_fixture, [envelope_attrs])

    assert same_envelope.id == envelope.id
    assert {:ok, later_complete} = AcquisitionStore.seal_complete(later_acquisition, "cursor-1")

    assert {:ok, later_effect, :inserted} =
             effect_attrs
             |> Map.put(:acquisition_run_id, later_complete.id)
             |> Semantics.put_effect([envelope.id])

    refute later_effect.id == first_effect.id
    refute later_effect.effect_key == first_effect.effect_key
    assert later_effect.acquisition_run_id == later_complete.id
  end

  test "database rejects a semantic directive that differs from its acquisition directive" do
    fixture = ChiefLineageFixtures.base("semantics-directive-mismatch")

    assert {:ok, _page, [envelope], :inserted} =
             ChiefLineageFixtures.terminal_page(fixture, [
               ChiefLineageFixtures.source_envelope(fixture)
             ])

    assert {:ok, complete} = AcquisitionStore.seal_complete(fixture.acquisition, "cursor-1")

    assert {:ok, other_directive} =
             AgentDirectives.enqueue(
               fixture.agent.id,
               fixture.user_id,
               "connector_sync",
               %{"source" => "mismatch"},
               "semantic-mismatch-#{fixture.unique}"
             )

    now = DateTime.utc_now()
    payload = %{"title" => "Must fail"}

    attrs = %{
      id: Ecto.UUID.generate(),
      effect_key: :crypto.strong_rand_bytes(32),
      user_id: fixture.user_id,
      agent_id: fixture.agent.id,
      agent_directive_id: other_directive.id,
      acquisition_run_id: complete.id,
      kind: "todo",
      subject_key: "mismatched-directive",
      contract_version: 1,
      extractor_version: "fixture-v1",
      payload: payload,
      payload_digest: :crypto.hash(:sha256, Jason.encode!(payload)),
      inserted_at: now
    }

    assert {:error, changeset} =
             %SemanticEffect{}
             |> SemanticEffect.changeset(attrs)
             |> Repo.insert(mode: :savepoint)

    assert {"does not exist", metadata} = Keyword.fetch!(changeset.errors, :acquisition_run_id)
    assert metadata[:constraint_name] == "chief_semantic_effects_acquisition_owner_fkey"
    assert envelope.id
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
