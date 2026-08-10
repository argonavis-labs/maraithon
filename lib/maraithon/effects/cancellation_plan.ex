defmodule Maraithon.Effects.CancellationPlan do
  @moduledoc """
  Exact post-commit work produced by a durable Effect cancellation transaction.

  A plan is only a snapshot of committed fences. Every termination and
  settlement operation re-reads the persisted exact claim identity.
  """

  @enforce_keys [
    :agent_id,
    :user_id,
    :reason,
    :claims,
    :pending_cancelled,
    :requested,
    :more?
  ]
  defstruct [
    :agent_id,
    :user_id,
    :reason,
    :claims,
    :pending_cancelled,
    :requested,
    :more?,
    :lifecycle_operation_token
  ]

  @type claim :: %{
          required(:effect_id) => Ecto.UUID.t(),
          required(:agent_id) => Ecto.UUID.t(),
          required(:claim_token) => Ecto.UUID.t(),
          required(:runtime_owner_generation) => Ecto.UUID.t(),
          required(:owner_node) => String.t(),
          required(:supervisor_id) => Ecto.UUID.t(),
          required(:task_id) => Ecto.UUID.t()
        }

  @type t :: %__MODULE__{
          agent_id: Ecto.UUID.t(),
          user_id: String.t(),
          reason: String.t(),
          claims: [claim()],
          pending_cancelled: non_neg_integer(),
          requested: non_neg_integer(),
          more?: boolean(),
          lifecycle_operation_token: Ecto.UUID.t() | nil
        }
end
