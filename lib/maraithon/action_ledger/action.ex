defmodule Maraithon.ActionLedger.Action do
  @moduledoc """
  Durable audit record for material assistant decisions and side effects.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @event_types ~w(
    tool.allowed
    tool.denied
    tool.needs_confirmation
    tool.executed
    proactive.sent
    proactive.held
    proactive.delivery_planned
    todo.changed
    crm.changed
    memory.changed
    external_action.changed
    connector.reauth
    model.uncertainty
    scheduled_task.changed
    agent_isolation.changed
    mobile_node.changed
    secret_ref.checked
  )

  @statuses ~w(allowed denied needs_confirmation completed failed held sent)

  schema "action_ledger_actions" do
    field :user_id, :string
    field :agent_id, :binary_id
    field :surface, :string
    field :event_type, :string
    field :status, :string
    field :source_evidence, :map, default: %{}
    field :policy_decision, :map, default: %{}
    field :model_summary, :string
    field :confirmation_state, :string
    field :result_object_refs, :map, default: %{}
    field :remediation_hint, :string
    field :metadata, :map, default: %{}

    timestamps(type: :utc_datetime_usec)
  end

  @required_fields [:surface, :event_type, :status]
  @optional_fields [
    :user_id,
    :agent_id,
    :source_evidence,
    :policy_decision,
    :model_summary,
    :confirmation_state,
    :result_object_refs,
    :remediation_hint,
    :metadata
  ]

  def changeset(action, attrs) do
    action
    |> cast(attrs || %{}, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_inclusion(:event_type, @event_types)
    |> validate_inclusion(:status, @statuses)
    |> validate_length(:user_id, max: 320)
    |> validate_length(:surface, min: 2, max: 80)
    |> validate_length(:event_type, min: 3, max: 120)
    |> validate_length(:status, min: 2, max: 80)
    |> validate_length(:model_summary, max: 2_000)
    |> validate_length(:confirmation_state, max: 80)
    |> validate_length(:remediation_hint, max: 1_000)
    |> validate_map(:source_evidence)
    |> validate_map(:policy_decision)
    |> validate_map(:result_object_refs)
    |> validate_map(:metadata)
  end

  def event_types, do: @event_types
  def statuses, do: @statuses

  defp validate_map(changeset, field) do
    validate_change(changeset, field, fn ^field, value ->
      if is_map(value), do: [], else: [{field, "must be a map"}]
    end)
  end
end
