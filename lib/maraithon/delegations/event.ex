defmodule Maraithon.Delegations.Event do
  @moduledoc "Deduplicated conversation input and its durable wake intent."
  use Maraithon.Delegations.Record

  @fields ~w(delegation_id seq kind event_key source_ref source_revision occurred_at consumed_by_turn_id wake_state)a

  schema "delegation_events" do
    payload_fields()
    field :delegation_id, :binary_id
    field :seq, :integer, read_after_writes: true
    field :kind, :string
    field :event_key, :string
    field :source_ref, :string
    field :source_revision, :string
    field :occurred_at, :utc_datetime_usec
    field :consumed_by_turn_id, :binary_id
    field :wake_state, :string, default: "pending"
  end

  def payload_binding_spec, do: Record.spec("delegation_events", @fields -- [:seq])

  def changeset(row, attrs) do
    Record.changeset(row, attrs, @fields -- [:seq], [
      :delegation_id,
      :kind,
      :event_key,
      :occurred_at
    ])
    |> Maraithon.DurablePayload.put_bounded_map(:data, 8_192, Record.bounds())
    |> validate_inclusion(:wake_state, ~w(pending dispatched consumed))
    |> validate_length(:event_key, min: 1, max: 500)
    |> unique_constraint([:delegation_id, :event_key])
  end
end
