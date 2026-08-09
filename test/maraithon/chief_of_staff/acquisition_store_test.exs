defmodule Maraithon.ChiefOfStaff.AcquisitionStoreTest do
  use Maraithon.DataCase, async: true

  alias Maraithon.ChiefLineageFixtures
  alias Maraithon.ChiefOfStaff.AcquisitionStore
  alias Maraithon.ChiefOfStaff.Semantics
  alias Maraithon.Connectors.SourceCursors

  test "contiguous terminal pages seal an immutable complete manifest" do
    fixture = ChiefLineageFixtures.base("acquisition-complete")
    envelopes = [ChiefLineageFixtures.source_envelope(fixture, "a")]

    assert {:ok, page, [envelope], :inserted} =
             ChiefLineageFixtures.terminal_page(fixture, envelopes)

    assert page.ordinal == 0
    assert page.terminal
    assert envelope.source_item_key == "item-#{fixture.unique}-a"

    assert {:ok, ^page, [duplicate_envelope], :duplicate} =
             ChiefLineageFixtures.terminal_page(fixture, envelopes)

    assert duplicate_envelope.id == envelope.id

    assert {:error, :acquisition_page_idempotency_conflict} =
             AcquisitionStore.record_page(
               fixture.acquisition,
               %{
                 ordinal: 0,
                 request_cursor: fixture.acquisition.start_cursor,
                 next_cursor: "forked-page",
                 terminal: false,
                 request: %{"cursor" => fixture.acquisition.start_cursor},
                 response_proof: %{"pagination_exhausted" => true}
               },
               envelopes
             )

    assert {:error, :acquisition_page_idempotency_conflict} =
             ChiefLineageFixtures.terminal_page(fixture, [
               put_in(hd(envelopes), [:raw_payload, "body"], "changed")
             ])

    assert {:ok, complete} = AcquisitionStore.seal_complete(fixture.acquisition, "cursor-1")
    assert complete.status == "complete"
    assert complete.pagination_exhausted
    assert complete.page_count == 1
    assert complete.item_count == 1
    assert byte_size(complete.manifest_digest) == 32

    assert [stored] = AcquisitionStore.list_complete_envelopes(complete)
    assert stored.id == envelope.id

    assert {:error, :acquisition_sealed} =
             ChiefLineageFixtures.terminal_page(%{fixture | acquisition: complete}, [])
  end

  test "out-of-order and incomplete pagination never admit semantics or advance cursor" do
    fixture = ChiefLineageFixtures.base("acquisition-incomplete")

    assert {:error, :noncontiguous_acquisition_page} =
             AcquisitionStore.record_page(
               fixture.acquisition,
               %{
                 ordinal: 1,
                 request_cursor: "cursor-1",
                 next_cursor: nil,
                 terminal: true,
                 request: %{},
                 response_proof: %{}
               },
               []
             )

    assert {:ok, incomplete} =
             AcquisitionStore.mark_incomplete(
               fixture.acquisition,
               :page_limit,
               %{"next_cursor" => "page-2"}
             )

    assert incomplete.status == "incomplete"
    assert incomplete.sealed_at
    assert byte_size(incomplete.manifest_digest) == 32

    assert {:error, :acquisition_sealed} =
             AcquisitionStore.seal_complete(incomplete, "cursor-1")

    assert {:error, :acquisition_not_complete} =
             Semantics.put_effect(
               %{
                 acquisition_run_id: incomplete.id,
                 kind: "todo",
                 subject_key: "subject",
                 contract_version: 1,
                 extractor_version: "fixture-v1",
                 payload: %{}
               },
               [Ecto.UUID.generate()]
             )

    assert SourceCursors.get(fixture.account.id, fixture.cursor.kind).value == "cursor-0"
  end

  test "an explicit terminal empty page is valid complete coverage" do
    fixture = ChiefLineageFixtures.base("acquisition-empty")

    assert {:ok, _page, [], :inserted} = ChiefLineageFixtures.terminal_page(fixture, [])
    assert {:ok, complete} = AcquisitionStore.seal_complete(fixture.acquisition, "cursor-0")
    assert complete.page_count == 1
    assert complete.item_count == 0
  end
end
