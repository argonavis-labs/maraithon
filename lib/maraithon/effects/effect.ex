defmodule Maraithon.Effects.Effect do
  @moduledoc """
  Schema for effect outbox records.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: false}
  @foreign_key_type :binary_id

  schema "effects" do
    field :agent_id, :binary_id
    field :owner_user_id, :string
    field :idempotency_key, :binary_id
    field :effect_type, :string
    field :params, :map, default: %{}
    field :status, :string, default: "pending"
    field :claimed_by, :string
    field :claimed_at, :utc_datetime_usec
    field :completion_claimed_by, :string
    field :completion_claimed_at, :utc_datetime_usec
    field :agent_run_id, :binary_id
    field :agent_run_step_id, :binary_id
    field :result_envelope, :map
    field :result_dispatched_at, :utc_datetime_usec
    field :result_dispatch_after, :utc_datetime_usec
    field :result_dispatch_attempts, :integer, default: 0
    field :result_acknowledged_at, :utc_datetime_usec
    field :attempts, :integer, default: 0
    field :max_attempts, :integer, default: 3
    field :last_failure_code, :string
    field :last_failure_attempt, :integer
    field :retry_after, :utc_datetime_usec
    field :result, :map
    field :error, :string

    timestamps(type: :utc_datetime_usec)
  end

  @required_fields [:id, :agent_id, :idempotency_key, :effect_type]
  @optional_fields [
    :params,
    :owner_user_id,
    :status,
    :claimed_by,
    :claimed_at,
    :completion_claimed_by,
    :completion_claimed_at,
    :agent_run_id,
    :agent_run_step_id,
    :result_envelope,
    :result_dispatched_at,
    :result_dispatch_after,
    :result_dispatch_attempts,
    :result_acknowledged_at,
    :attempts,
    :max_attempts,
    :last_failure_code,
    :last_failure_attempt,
    :retry_after,
    :result,
    :error
  ]

  def changeset(effect, attrs) do
    effect
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_inclusion(:status, [
      "pending",
      "claimed",
      "cancelling",
      "completed",
      "failed",
      "cancelled"
    ])
    |> unique_constraint(:idempotency_key)
  end
end
