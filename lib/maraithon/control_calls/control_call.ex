defmodule Maraithon.ControlCalls.ControlCall do
  @moduledoc """
  Idempotency record for side-effecting control protocol calls.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @statuses ~w(pending completed failed)

  schema "control_calls" do
    field :user_id, :string
    field :method, :string
    field :idempotency_key, :string
    field :request_hash, :string
    field :status, :string, default: "pending"
    field :result, :map, default: %{}
    field :error, :map, default: %{}
    field :expires_at, :utc_datetime_usec
    field :completed_at, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(control_call, attrs) do
    control_call
    |> cast(attrs || %{}, [
      :user_id,
      :method,
      :idempotency_key,
      :request_hash,
      :status,
      :result,
      :error,
      :expires_at,
      :completed_at
    ])
    |> validate_required([:method, :idempotency_key, :request_hash, :status, :expires_at])
    |> validate_inclusion(:status, @statuses)
    |> validate_length(:method, min: 2, max: 120)
    |> validate_length(:idempotency_key, min: 8, max: 200)
    |> validate_length(:request_hash, is: 64)
    |> validate_length(:user_id, max: 320)
    |> validate_map(:result)
    |> validate_map(:error)
    |> unique_constraint([:method, :idempotency_key])
  end

  def statuses, do: @statuses

  defp validate_map(changeset, field) do
    validate_change(changeset, field, fn ^field, value ->
      if is_map(value), do: [], else: [{field, "must be a map"}]
    end)
  end
end
