defmodule Maraithon.Todos.Todo do
  @moduledoc """
  Persisted user-scoped todo items that can be managed by conversational operators.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @statuses ~w(open done dismissed snoozed)
  @attention_modes ~w(act_now monitor)
  @kinds ~w(general gmail_triage)

  schema "todos" do
    field :user_id, :string
    field :source, :string
    field :kind, :string, default: "general"
    field :attention_mode, :string, default: "act_now"
    field :title, :string
    field :summary, :string
    field :next_action, :string
    field :priority, :integer, default: 50
    field :status, :string, default: "open"
    field :snoozed_until, :utc_datetime_usec
    field :closed_at, :utc_datetime_usec
    field :source_item_id, :string
    field :source_occurred_at, :utc_datetime_usec
    field :dedupe_key, :string
    field :metadata, :map, default: %{}

    timestamps(type: :utc_datetime_usec)
  end

  @required_fields [
    :user_id,
    :source,
    :kind,
    :title,
    :summary,
    :next_action,
    :dedupe_key
  ]

  @optional_fields [
    :attention_mode,
    :priority,
    :status,
    :snoozed_until,
    :closed_at,
    :source_item_id,
    :source_occurred_at,
    :metadata
  ]

  def changeset(todo, attrs) do
    todo
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_inclusion(:kind, @kinds)
    |> validate_inclusion(:attention_mode, @attention_modes)
    |> validate_inclusion(:status, @statuses)
    |> validate_number(:priority, greater_than_or_equal_to: 0, less_than_or_equal_to: 100)
    |> validate_length(:source, min: 2, max: 100)
    |> validate_length(:title, min: 4, max: 240)
    |> validate_length(:summary, min: 4, max: 2_000)
    |> validate_length(:next_action, min: 4, max: 1_000)
    |> validate_length(:dedupe_key, min: 4, max: 255)
    |> validate_change(:metadata, fn :metadata, value ->
      if is_map(value), do: [], else: [metadata: "must be a map"]
    end)
    |> foreign_key_constraint(:user_id)
  end
end
