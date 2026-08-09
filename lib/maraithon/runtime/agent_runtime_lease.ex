defmodule Maraithon.Runtime.AgentRuntimeLease do
  @moduledoc """
  Exact, database-clock runtime ownership for one resident Agent incarnation.

  A non-nil `ready_at` is workload authority only while the lease is live and
  the Agent and its isolation Binding remain runnable. `owner_node` is routing
  and observability data; `owner_token` is the immutable authority generation.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Maraithon.Agents.Agent

  @primary_key false
  @foreign_key_type :binary_id
  @max_owner_node_bytes 255

  schema "agent_runtime_leases" do
    belongs_to :agent, Agent, primary_key: true

    field :owner_token, Ecto.UUID
    field :owner_node, :string
    field :claimed_at, :utc_datetime_usec
    field :lease_until, :utc_datetime_usec
    field :renewed_at, :utc_datetime_usec
    field :ready_at, :utc_datetime_usec
    field :draining_at, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec)
  end

  @required_fields [
    :agent_id,
    :owner_token,
    :owner_node,
    :claimed_at,
    :lease_until,
    :renewed_at
  ]
  @optional_fields [:ready_at, :draining_at]

  def changeset(lease, attrs) do
    lease
    |> cast(attrs || %{}, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_length(:owner_node, min: 1, max: @max_owner_node_bytes, count: :bytes)
    |> validate_format(:owner_node, ~r/^[^\s\x00-\x1F\x7F]+$/u)
    |> foreign_key_constraint(:agent_id)
    |> unique_constraint(:owner_token,
      name: :agent_runtime_leases_owner_token_unique_index
    )
    |> check_constraint(:owner_node, name: :agent_runtime_leases_owner_node_check)
    |> check_constraint(:lease_until, name: :agent_runtime_leases_time_order_check)
  end

  def max_owner_node_bytes, do: @max_owner_node_bytes
end
