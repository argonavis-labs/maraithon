defmodule Maraithon.Todos.TrainingRun do
  @moduledoc false
  use Ecto.Schema
  @primary_key {:id, :binary_id, autogenerate: true}
  schema "todo_training_runs" do
    field :user_id, :string
    field :version, :integer, default: 1
    field :status, :string, default: "pending"
    field :candidate_count, :integer
    field :payload, Maraithon.Encrypted.Map
    field :payload_hash, :string
    field :result, Maraithon.Encrypted.Map
    field :result_hash, :string
    field :completed_at, :utc_datetime_usec
    timestamps(type: :utc_datetime_usec)
  end
end
