defmodule Maraithon.Privacy.ErasureProviderRevocation do
  @moduledoc """
  Content-free outcome of attempting to revoke one external OAuth credential.

  `unavailable` never claims provider-side deletion. It records only an
  explicit operator decision to continue local erasure when a provider has no
  revocation API or ciphertext cannot be recovered.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @states ~w(pending confirmed unavailable failed)

  schema "privacy_erasure_provider_revocations" do
    field :request_id, Ecto.UUID
    field :credential_table, :string
    field :credential_row_id, :integer, redact: true
    field :provider_code, :string
    field :state, :string, default: "pending"
    field :attempt_count, :integer, default: 0
    field :error_code, :string
    field :last_attempted_at, :utc_datetime_usec
    field :completed_at, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(revocation, attrs) do
    revocation
    |> cast(attrs, [
      :request_id,
      :credential_table,
      :credential_row_id,
      :provider_code,
      :state,
      :attempt_count,
      :error_code,
      :last_attempted_at,
      :completed_at
    ])
    |> validate_required([
      :request_id,
      :credential_table,
      :credential_row_id,
      :provider_code,
      :state,
      :attempt_count
    ])
    |> validate_inclusion(:credential_table, ["oauth_tokens", "connected_accounts"])
    |> validate_inclusion(:state, @states)
    |> validate_number(:credential_row_id, greater_than_or_equal_to: 0)
    |> validate_number(:attempt_count, greater_than_or_equal_to: 0)
    |> validate_length(:provider_code, min: 1, max: 80, count: :bytes)
    |> validate_length(:error_code, min: 1, max: 128, count: :bytes)
    |> validate_format(:error_code, ~r/^[a-z0-9_]+$/)
    |> unique_constraint([:request_id, :credential_table, :credential_row_id],
      name: :privacy_erasure_provider_revocations_identity_index
    )
    |> foreign_key_constraint(:request_id)
  end
end
