defmodule Maraithon.MobileNodes.Pairing do
  @moduledoc """
  One-time pairing record for narrow mobile/node access.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @statuses ~w(pending claimed expired revoked)

  schema "mobile_node_pairings" do
    field :user_id, :string
    field :code_hash, :binary
    field :code_nonce, :binary
    field :status, :string, default: "pending"
    field :allowed_commands, {:array, :string}, default: []
    field :expires_at, :utc_datetime_usec
    field :claimed_at, :utc_datetime_usec
    field :claimed_device_id, :string
    field :metadata, :map, default: %{}

    timestamps(type: :utc_datetime_usec)
  end

  @required_fields [:user_id, :code_hash, :code_nonce, :status, :allowed_commands, :expires_at]
  @optional_fields [:claimed_at, :claimed_device_id, :metadata]

  def changeset(pairing, attrs) do
    pairing
    |> cast(attrs || %{}, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_inclusion(:status, @statuses)
    |> validate_length(:user_id, min: 1, max: 320)
    |> validate_length(:claimed_device_id, max: 200)
    |> validate_map(:metadata)
    |> normalize_string(:user_id)
    |> normalize_string(:claimed_device_id)
  end

  def statuses, do: @statuses

  defp validate_map(changeset, field) do
    validate_change(changeset, field, fn ^field, value ->
      if is_map(value), do: [], else: [{field, "must be a map"}]
    end)
  end

  defp normalize_string(changeset, field) do
    case get_change(changeset, field) do
      value when is_binary(value) -> put_change(changeset, field, String.trim(value))
      _ -> changeset
    end
  end
end
