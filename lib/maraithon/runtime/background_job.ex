defmodule Maraithon.Runtime.BackgroundJob do
  @moduledoc """
  Durable app-level background job record.

  These jobs are for work that should not block web, Telegram, or agent runtime
  request paths: source ingestion, relationship learning, open-loop refreshes,
  and other user-scoped follow-up work.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @statuses ~w(pending running completed failed cancelled)

  schema "background_jobs" do
    field :user_id, :string
    field :queue, :string, default: "default"
    field :job_type, :string
    field :payload, :map, default: %{}
    field :status, :string, default: "pending"
    field :dedupe_key, :string
    field :attempts, :integer, default: 0
    field :max_attempts, :integer, default: 3
    field :scheduled_at, :utc_datetime_usec
    field :claimed_by, :string
    field :claimed_at, :utc_datetime_usec
    field :completed_at, :utc_datetime_usec
    field :failed_at, :utc_datetime_usec
    field :cancelled_at, :utc_datetime_usec
    field :result, :map, default: %{}
    field :last_error, :string

    timestamps(type: :utc_datetime_usec)
  end

  @required_fields [:queue, :job_type, :scheduled_at]
  @optional_fields [
    :user_id,
    :payload,
    :status,
    :dedupe_key,
    :attempts,
    :max_attempts,
    :claimed_by,
    :claimed_at,
    :completed_at,
    :failed_at,
    :cancelled_at,
    :result,
    :last_error
  ]

  def changeset(job, attrs) do
    job
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_inclusion(:status, @statuses)
    |> validate_number(:attempts, greater_than_or_equal_to: 0)
    |> validate_number(:max_attempts, greater_than: 0, less_than_or_equal_to: 25)
    |> normalize_string(:queue)
    |> normalize_string(:job_type)
    |> normalize_string(:user_id)
    |> normalize_string(:dedupe_key)
    |> unique_constraint(:dedupe_key,
      name: :background_jobs_dedupe_key_index,
      message: "already has an active background job"
    )
  end

  def statuses, do: @statuses

  defp normalize_string(changeset, field) do
    case get_change(changeset, field) do
      value when is_binary(value) ->
        put_change(changeset, field, String.trim(value))

      _ ->
        changeset
    end
  end
end
