defmodule Maraithon.Runtime.SnapshotQuarantine do
  @moduledoc """
  Sanitized evidence for a snapshot row rejected by the v1 migration.

  Raw behavior state and budget are deliberately never copied here. A blocked
  active Agent keeps its source snapshot until a newer valid checkpoint exists;
  stopped Agents and safely superseded active rows are removed after this
  report is written in the same transaction.
  """

  use Ecto.Schema

  @statuses ~w(blocked_active quarantined)

  schema "snapshot_quarantines" do
    field :snapshot_id, :integer
    field :agent_id, :binary_id
    field :sequence_num, :integer
    field :failure_code, :string
    field :status, :string
    field :state_bytes, :integer
    field :budget_bytes, :integer
    field :snapshot_inserted_at, :utc_datetime_usec
    field :quarantined_at, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  def statuses, do: @statuses
end
