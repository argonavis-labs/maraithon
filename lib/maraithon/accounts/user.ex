defmodule Maraithon.Accounts.User do
  @moduledoc """
  Application user identity.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :string, autogenerate: false}
  @foreign_key_type :string

  schema "users" do
    field :email, :string
    field :is_admin, :boolean, default: false
    field :confirmed_at, :utc_datetime_usec
    # System-owned fence: new sessions, Agents, and credentials are refused
    # once a durable user erasure request exists.
    field :privacy_erasure_requested_at, :utc_datetime_usec
    # One setting that swaps the model behind every assistant call made for
    # this user. Nil keeps the configured workspace default.
    field :assistant_model, :string

    timestamps(type: :utc_datetime_usec)
  end

  @required_fields [:id, :email]
  @optional_fields [:is_admin, :confirmed_at]
  @assistant_model_format ~r/^[A-Za-z0-9][A-Za-z0-9._:\/-]{0,159}$/

  @doc "Sets or clears the user's chosen model id. Blank input clears it."
  def assistant_model_changeset(user, attrs) do
    user
    |> cast(attrs, [:assistant_model])
    |> update_change(:assistant_model, &normalize_assistant_model/1)
    |> validate_length(:assistant_model, max: 160)
    |> validate_format(:assistant_model, @assistant_model_format,
      message: "must be a provider model id such as meta/muse-spark-1.3-contributor"
    )
  end

  defp normalize_assistant_model(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_assistant_model(_value), do: nil

  def changeset(user, attrs) do
    user
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_format(:email, ~r/^[^\s]+@[^\s]+$/)
    |> validate_length(:email, max: 320)
    |> validate_length(:id, max: 320)
    |> unique_constraint(:email)
  end
end
