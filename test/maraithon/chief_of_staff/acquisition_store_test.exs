defmodule Maraithon.ChiefOfStaff.AcquisitionStoreTest do
  use Maraithon.DataCase, async: true

  alias Maraithon.AgentIsolation
  alias Maraithon.Agents
  alias Maraithon.ChiefLineageFixtures
  alias Maraithon.ChiefOfStaff.AcquisitionPage
  alias Maraithon.ChiefOfStaff.AcquisitionStore
  alias Maraithon.ChiefOfStaff.Semantics
  alias Maraithon.ChiefOfStaff.SourceEnvelope
  alias Maraithon.ConnectedAccounts
  alias Maraithon.Connectors.SourceCursors
  alias Maraithon.Repo
  alias Maraithon.Runtime.AgentDirectives
  alias Maraithon.Runtime.IngressReceipts

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

    assert {:error, :acquisition_page_idempotency_conflict} =
             ChiefLineageFixtures.terminal_page(fixture, [
               put_in(hd(envelopes), [:provenance, "fixture"], false)
             ])

    assert {:error, :acquisition_page_idempotency_conflict} =
             ChiefLineageFixtures.terminal_page(fixture, [
               Map.put(hd(envelopes), :occurred_at, ~U[2026-08-09 12:00:00.000000Z])
             ])

    assert {:error, :acquisition_pagination_exhausted} =
             AcquisitionStore.record_page(
               fixture.acquisition,
               %{
                 ordinal: 1,
                 request_cursor: nil,
                 next_cursor: nil,
                 terminal: true,
                 request: %{},
                 response_proof: %{"pagination_exhausted" => true}
               },
               []
             )

    assert {:error, :acquisition_pagination_exhausted} =
             AcquisitionStore.mark_incomplete(
               fixture.acquisition,
               :page_limit,
               %{"next_cursor" => "impossible"}
             )

    assert {:ok, complete} = AcquisitionStore.seal_complete(fixture.acquisition, "cursor-1")
    assert complete.status == "complete"
    assert complete.pagination_exhausted
    assert complete.page_count == 1
    assert complete.item_count == 1
    assert byte_size(complete.manifest_digest) == 32

    assert_raw_check_violation(
      """
      INSERT INTO chief_acquisition_envelopes
      SELECT *
      FROM chief_acquisition_envelopes
      WHERE acquisition_run_id = $1::uuid
      LIMIT 1
      """,
      [Ecto.UUID.dump!(complete.id)],
      "chief acquisition envelope proof set is closed"
    )

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

  test "caller-owned transaction can commit a page error without partial lineage writes" do
    fixture = ChiefLineageFixtures.base("acquisition-savepoint")
    first = ChiefLineageFixtures.source_envelope(fixture, "first")

    assert {:ok, _page, [_first_envelope], :inserted} =
             AcquisitionStore.record_page(
               fixture.acquisition,
               %{
                 ordinal: 0,
                 request_cursor: fixture.acquisition.start_cursor,
                 next_cursor: "cursor-1",
                 terminal: false,
                 request: %{"cursor" => fixture.acquisition.start_cursor},
                 response_proof: %{"page" => 0}
               },
               [first]
             )

    second = ChiefLineageFixtures.source_envelope(fixture, "second")

    assert {:ok, :outer_transaction_committed} =
             Repo.transaction(fn ->
               assert {:error, _reason} =
                        AcquisitionStore.record_page_in_transaction(
                          fixture.acquisition,
                          %{
                            ordinal: 1,
                            request_cursor: "cursor-1",
                            next_cursor: nil,
                            terminal: true,
                            request: %{"cursor" => "cursor-1"},
                            response_proof: %{"page" => 1}
                          },
                          [second, first]
                        )

               :outer_transaction_committed
             end)

    refute Repo.get_by(AcquisitionPage,
             acquisition_run_id: fixture.acquisition.id,
             ordinal: 1
           )

    refute Repo.get_by(SourceEnvelope,
             user_id: fixture.user_id,
             source_item_key: second.source_item_key
           )

    stored_run = Repo.get!(Maraithon.ChiefOfStaff.AcquisitionRun, fixture.acquisition.id)
    assert stored_run.page_count == 1
    assert stored_run.item_count == 1
  end

  test "reconnecting one OAuth row snapshots a new provider account envelope identity" do
    fixture = ChiefLineageFixtures.base("acquisition-reconnect")
    envelope_attrs = ChiefLineageFixtures.source_envelope(fixture, "stable-provider-item")

    assert {:ok, _first_page, [first_envelope], :inserted} =
             ChiefLineageFixtures.terminal_page(fixture, [envelope_attrs])

    new_provider_account_key = "reconnected-provider-account-#{fixture.unique}"

    assert {:ok, reconnected_account} =
             ConnectedAccounts.upsert_from_oauth(fixture.user_id, fixture.provider, %{
               access_token: "reconnected-token",
               external_account_id: new_provider_account_key,
               scopes: ["chief-test"]
             })

    assert reconnected_account.id == fixture.account.id

    assert {:ok, updated_agent} =
             Agents.update_agent(fixture.agent, %{
               connector_grants: %{
                 fixture.provider => %{"account_ids" => [new_provider_account_key]}
               }
             })

    assert {:ok, _binding} = AgentIsolation.upsert_binding(updated_agent)

    assert {:ok, directive} =
             AgentDirectives.enqueue(
               fixture.agent.id,
               fixture.user_id,
               "connector_sync",
               %{"source" => "fixture"},
               "chief-reconnect-#{fixture.unique}"
             )

    assert {:ok, receipt, :inserted} =
             IngressReceipts.record(%{
               user_id: fixture.user_id,
               agent_id: fixture.agent.id,
               connected_account_id: fixture.account.id,
               provider: fixture.provider,
               ingress_kind: "poll",
               provider_event_key: "event-#{fixture.unique}",
               payload: %{"cursor_hint" => "safe"}
             })

    assert receipt.provider_account_key == new_provider_account_key

    assert {:ok, acquisition, :inserted} =
             AcquisitionStore.begin_run(%{
               user_id: fixture.user_id,
               agent_id: fixture.agent.id,
               agent_directive_id: directive.id,
               runtime_ingress_receipt_id: receipt.id,
               connected_account_id: fixture.account.id,
               source_cursor_id: fixture.cursor.id,
               cursor_kind: fixture.cursor.kind,
               provider: fixture.provider,
               source: fixture.acquisition.source,
               scope_key: fixture.acquisition.scope_key,
               request_key: "reconnect-request-#{fixture.unique}",
               contract_version: 1
             })

    assert acquisition.provider_account_key == new_provider_account_key

    assert {:ok, _second_page, [second_envelope], :inserted} =
             ChiefLineageFixtures.terminal_page(%{fixture | acquisition: acquisition}, [
               envelope_attrs
             ])

    assert second_envelope.provider_account_key == new_provider_account_key
    refute second_envelope.id == first_envelope.id
    refute second_envelope.envelope_key == first_envelope.envelope_key
  end

  test "an explicit terminal empty page is valid complete coverage" do
    fixture = ChiefLineageFixtures.base("acquisition-empty")

    assert {:ok, _page, [], :inserted} = ChiefLineageFixtures.terminal_page(fixture, [])
    assert {:ok, complete} = AcquisitionStore.seal_complete(fixture.acquisition, "cursor-0")
    assert complete.page_count == 1
    assert complete.item_count == 0
  end

  defp assert_raw_check_violation(sql, params, expected_message) do
    error =
      assert_raise Postgrex.Error, fn ->
        Repo.transaction(fn -> Repo.query!(sql, params) end, mode: :savepoint)
      end

    assert error.postgres.code == :check_violation
    assert error.postgres.message =~ expected_message
    assert %{rows: [[1]]} = Repo.query!("SELECT 1")
  end
end
