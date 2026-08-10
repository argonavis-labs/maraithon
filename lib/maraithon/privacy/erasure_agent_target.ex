defmodule Maraithon.Privacy.ErasureAgentTarget do
  @moduledoc "Content-free per-Agent drain coordination for a user erasure."

  use Ecto.Schema
  import Ecto.Changeset

  @states ~w(pending draining drained erasing)

  schema "privacy_erasure_agent_targets" do
    field :request_id, Ecto.UUID
    field :agent_id, Ecto.UUID, redact: true
    field :state, :string, default: "pending"
    field :blocker_code, :string
    field :last_attempted_at, :utc_datetime_usec
    field :drained_at, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(target, attrs) do
    target
    |> cast(attrs, [
      :request_id,
      :agent_id,
      :state,
      :blocker_code,
      :last_attempted_at,
      :drained_at
    ])
    |> validate_required([:request_id, :agent_id, :state])
    |> validate_inclusion(:state, @states)
    |> validate_length(:blocker_code, min: 1, max: 128, count: :bytes)
    |> validate_format(:blocker_code, ~r/^[a-z0-9_]+$/)
    |> unique_constraint([:request_id, :agent_id],
      name: :privacy_erasure_agent_targets_identity_index
    )
    |> foreign_key_constraint(:request_id)
    |> foreign_key_constraint(:agent_id)
  end
end
