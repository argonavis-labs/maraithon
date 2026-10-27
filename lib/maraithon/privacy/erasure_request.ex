defmodule Maraithon.Privacy.ErasureRequest do
  @moduledoc """
  Durable, idempotent coordination for one user or Agent erasure.

  Subject identifiers exist only while work is pending. Completion deletes the
  subject rows, lets the database clear both identifiers, and clears the
  idempotency digest; only the separately classified, bounded receipt remains.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @scopes ~w(user agent)
  @states ~w(requested draining revoking_credentials erasing completed)

  schema "privacy_erasure_requests" do
    field :scope, :string
    field :subject_user_id, :string, redact: true
    field :subject_agent_id, Ecto.UUID, redact: true
    field :idempotency_digest, :binary, redact: true
    field :state, :string, default: "requested"
    field :blocker_code, :string
    field :target_agent_count, :integer, default: 0
    field :credentials_locally_revoked, :boolean, default: false
    field :provider_revocation_override, :boolean, default: false
    field :claim_token, Ecto.UUID, redact: true
    field :claimed_at, :utc_datetime_usec
    field :claim_expires_at, :utc_datetime_usec
    field :requested_at, :utc_datetime_usec
    field :last_attempted_at, :utc_datetime_usec
    field :completed_at, :utc_datetime_usec
    field :expires_at, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(request, attrs) do
    request
    |> cast(attrs, [
      :scope,
      :subject_user_id,
      :subject_agent_id,
      :idempotency_digest,
      :state,
      :blocker_code,
      :target_agent_count,
      :credentials_locally_revoked,
      :provider_revocation_override,
      :claim_token,
      :claimed_at,
      :claim_expires_at,
      :requested_at,
      :last_attempted_at,
      :completed_at,
      :expires_at
    ])
    |> validate_required([:scope, :state, :requested_at, :target_agent_count])
    |> validate_inclusion(:scope, @scopes)
    |> validate_inclusion(:state, @states)
    |> validate_number(:target_agent_count, greater_than_or_equal_to: 0)
    |> validate_length(:subject_user_id, min: 1, max: 320, count: :bytes)
    |> validate_length(:idempotency_digest, is: 32, count: :bytes)
    |> validate_length(:blocker_code, min: 1, max: 128, count: :bytes)
    |> validate_format(:blocker_code, ~r/^[a-z0-9_]+$/)
    |> unique_constraint(:subject_user_id,
      name: :privacy_erasure_requests_active_user_index
    )
    |> unique_constraint(:subject_agent_id,
      name: :privacy_erasure_requests_active_agent_index
    )
  end

  def scopes, do: @scopes
  def states, do: @states
end
