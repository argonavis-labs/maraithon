defmodule Maraithon.Todos.TodoLearningEvent do
  @moduledoc """
  Durable outbox record for one human resolution of a model-selected todo.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @outcomes ~w(bad weak_bad ok great)
  @resolution_statuses ~w(done dismissed)
  @statuses ~w(pending processing processed failed)

  schema "todo_learning_events" do
    field :user_id, :string
    belongs_to :todo, Maraithon.Todos.Todo
    field :outcome, :string
    field :signal_strength, :float
    field :resolution_status, :string
    field :opened_before_resolution, :boolean, default: false
    field :surface, :string
    field :status, :string, default: "pending"
    field :attempts, :integer, default: 0
    field :last_error, :string
    field :operation, :string
    belongs_to :memory, Maraithon.Memory.Item
    field :processed_at, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(event, attrs) do
    event
    |> cast(attrs, [
      :user_id,
      :todo_id,
      :outcome,
      :signal_strength,
      :resolution_status,
      :opened_before_resolution,
      :surface,
      :status,
      :attempts,
      :last_error,
      :operation,
      :memory_id,
      :processed_at
    ])
    |> validate_required([
      :user_id,
      :todo_id,
      :outcome,
      :signal_strength,
      :resolution_status,
      :opened_before_resolution,
      :status
    ])
    |> validate_inclusion(:outcome, @outcomes)
    |> validate_inclusion(:resolution_status, @resolution_statuses)
    |> validate_inclusion(:status, @statuses)
    |> validate_number(:signal_strength,
      greater_than_or_equal_to: -1.0,
      less_than_or_equal_to: 1.0
    )
    |> validate_number(:attempts, greater_than_or_equal_to: 0)
    |> validate_length(:surface, max: 100)
    |> validate_length(:operation, max: 100)
    |> foreign_key_constraint(:user_id)
    |> foreign_key_constraint(:todo_id)
    |> foreign_key_constraint(:memory_id)
  end
end
