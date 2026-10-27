defmodule Maraithon.Runtime.AgentRestartGuard do
  @moduledoc """
  Durable, token-scoped crash-loop and recovery admission for an Agent.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Maraithon.Agents.Agent

  @primary_key false
  @foreign_key_type :binary_id
  @max_reason_bytes 255

  schema "agent_restart_guards" do
    belongs_to :agent, Agent, primary_key: true

    field :generation, Ecto.UUID
    field :last_owner_token, Ecto.UUID
    field :blocked_until, :utc_datetime_usec
    field :window_started_at, :utc_datetime_usec
    field :crash_count, :integer, default: 0
    field :tripped, :boolean, default: false
    field :needs_recovery, :boolean, default: false
    field :last_reason, :string

    timestamps(type: :utc_datetime_usec)
  end

  @required_fields [:agent_id, :generation, :crash_count, :tripped, :needs_recovery]
  @optional_fields [
    :last_owner_token,
    :blocked_until,
    :window_started_at,
    :last_reason
  ]

  def changeset(guard, attrs) do
    guard
    |> cast(attrs || %{}, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_number(:crash_count, greater_than_or_equal_to: 0)
    |> validate_length(:last_reason, min: 1, max: @max_reason_bytes, count: :bytes)
    |> validate_format(:last_reason, ~r/^[^\x00-\x1F\x7F]+$/u)
    |> foreign_key_constraint(:agent_id)
    |> unique_constraint(:generation,
      name: :agent_restart_guards_generation_unique_index
    )
    |> check_constraint(:crash_count, name: :agent_restart_guards_crash_count_check)
    |> check_constraint(:window_started_at, name: :agent_restart_guards_window_check)
    |> check_constraint(:needs_recovery,
      name: :agent_restart_guards_recovery_owner_check
    )
    |> check_constraint(:last_reason, name: :agent_restart_guards_reason_check)
  end

  def max_reason_bytes, do: @max_reason_bytes
end
