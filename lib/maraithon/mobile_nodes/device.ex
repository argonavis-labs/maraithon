defmodule Maraithon.MobileNodes.Device do
  @moduledoc """
  Registered mobile/node device identity and narrow command grants.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @statuses ~w(active revoked lost)

  schema "mobile_node_devices" do
    field :user_id, :string
    field :device_id, :string
    field :label, :string
    field :platform, :string
    field :status, :string, default: "active"
    field :public_key_fingerprint, :string
    field :capabilities, :map, default: %{}
    field :allowed_commands, {:array, :string}, default: []
    field :last_seen_at, :utc_datetime_usec
    field :metadata, :map, default: %{}

    timestamps(type: :utc_datetime_usec)
  end

  @required_fields [:user_id, :device_id, :status, :allowed_commands]
  @optional_fields [
    :label,
    :platform,
    :public_key_fingerprint,
    :capabilities,
    :last_seen_at,
    :metadata
  ]

  def changeset(device, attrs) do
    device
    |> cast(attrs || %{}, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_inclusion(:status, @statuses)
    |> validate_length(:user_id, min: 1, max: 320)
    |> validate_length(:device_id, min: 1, max: 200)
    |> validate_length(:label, max: 200)
    |> validate_length(:platform, max: 80)
    |> validate_length(:public_key_fingerprint, max: 200)
    |> validate_map(:capabilities)
    |> validate_map(:metadata)
    |> unique_constraint([:user_id, :device_id])
    |> normalize_string(:user_id)
    |> normalize_string(:device_id)
    |> normalize_string(:label)
    |> normalize_string(:platform)
    |> normalize_string(:public_key_fingerprint)
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
