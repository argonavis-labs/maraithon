defmodule Maraithon.Todos.TrainingExample do
  @moduledoc false
  use Ecto.Schema
  @primary_key {:id, :binary_id, autogenerate: true}
  schema "todo_training_examples" do
    field :user_id, :string
    field :origin, :string, default: "live"
    field :occurred_at, :utc_datetime_usec
    field :run_id, :binary_id
    field :todo_id, :binary_id
    field :candidate_index, :integer
    field :action, :string
    field :group_key, :string
    field :payload, Maraithon.Encrypted.Map, redact: true
    field :payload_hash, :string
    field :inserted_at, :utc_datetime_usec
  end
end
