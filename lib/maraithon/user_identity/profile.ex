defmodule Maraithon.UserIdentity.Profile do
  @moduledoc """
  Durable, user-confirmed identity: who they are and the handles
  (emails/phones) that are theirs across channels.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:user_id, :string, autogenerate: false}

  schema "user_identity_profiles" do
    field :display_name, :string
    field :emails, {:array, :string}, default: []
    field :phones, {:array, :string}, default: []
    field :confirmed_at, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(profile, attrs) do
    profile
    |> cast(attrs, [:user_id, :display_name, :emails, :phones, :confirmed_at])
    |> validate_required([:user_id])
    |> validate_length(:display_name, max: 240)
    |> validate_length(:emails, max: 20)
    |> validate_length(:phones, max: 20)
  end
end
