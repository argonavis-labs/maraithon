defmodule Maraithon.Todos.TrainingFeedback do
  @moduledoc false
  use Ecto.Schema
  @primary_key {:id, :binary_id, autogenerate: true}
  schema "todo_training_feedback" do
    field :user_id, :string
    field :todo_id, :binary_id
    field :example_id, :binary_id
    field :learning_event_id, :binary_id
    field :event, :string
    field :actor, :string
    field :label, :string
    field :strength, :string
    field :dedupe_key, :string
    field :payload, Maraithon.Encrypted.Map
    field :payload_hash, :string
    field :inserted_at, :utc_datetime_usec
  end
end
