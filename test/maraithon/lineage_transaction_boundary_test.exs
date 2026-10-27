defmodule Maraithon.Lineage.TransactionBoundaryTest do
  use ExUnit.Case, async: true

  alias Maraithon.ChiefOfStaff.AcquisitionStore
  alias Maraithon.ChiefOfStaff.Projections
  alias Maraithon.ChiefOfStaff.Semantics
  alias Maraithon.Connectors.SourceCursorAdvancements
  alias Maraithon.Runtime.AgentWorkResults
  alias Maraithon.Runtime.IngressReceipts

  test "every composable lineage API fails closed without a caller-owned transaction" do
    id = Ecto.UUID.generate()

    assert {:error, :lineage_transaction_required} =
             IngressReceipts.record_in_transaction(%{})

    assert {:error, :lineage_transaction_required} =
             AcquisitionStore.begin_run_in_transaction(%{})

    assert {:error, :lineage_transaction_required} =
             AcquisitionStore.record_page_in_transaction(id, %{}, [])

    assert {:error, :lineage_transaction_required} =
             AcquisitionStore.mark_incomplete_in_transaction(id, :page_limit, %{})

    assert {:error, :lineage_transaction_required} =
             AcquisitionStore.seal_complete_in_transaction(id, "cursor")

    assert {:error, :lineage_transaction_required} =
             Semantics.put_effect_in_transaction(%{}, [id])

    assert {:error, :lineage_transaction_required} =
             Projections.put_decision_in_transaction(id, %{})

    assert {:error, :lineage_transaction_required} =
             Projections.record_receipt_in_transaction(id, id, {:decision, id}, %{})

    assert {:error, :lineage_transaction_required} =
             AgentWorkResults.insert_provisional_in_transaction(%{}, [id])

    assert {:error, :lineage_transaction_required} =
             AgentWorkResults.finalize_in_transaction(id)

    assert {:error, :lineage_transaction_required} =
             SourceCursorAdvancements.advance_in_transaction(id, [id])
  end

  test "invalid arguments cannot bypass the caller-owned transaction boundary" do
    id = Ecto.UUID.generate()

    assert {:error, :lineage_transaction_required} =
             IngressReceipts.record_in_transaction(:invalid)

    assert {:error, :lineage_transaction_required} =
             AcquisitionStore.begin_run_in_transaction(:invalid)

    assert {:error, :lineage_transaction_required} =
             AcquisitionStore.record_page_in_transaction(id, :invalid, :invalid)

    assert {:error, :lineage_transaction_required} =
             Semantics.put_effect_in_transaction(:invalid, [])

    assert {:error, :lineage_transaction_required} =
             Projections.put_decision_in_transaction(id, :invalid)

    assert {:error, :lineage_transaction_required} =
             Projections.record_receipt_in_transaction(id, id, :invalid, :invalid)

    assert {:error, :lineage_transaction_required} =
             AgentWorkResults.insert_provisional_in_transaction(:invalid, [])

    assert {:error, :lineage_transaction_required} =
             SourceCursorAdvancements.advance_in_transaction(id, [])
  end
end
