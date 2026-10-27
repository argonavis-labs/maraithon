defmodule Maraithon.Crm.Ingest.Window do
  @moduledoc """
  Durable per-(user, source) window aggregating observations until ready to flush.

  Exactly one window per `(user_id, source)` is allowed in `open` status, enforced
  by a partial unique index. A window transitions through:

      open -> flushed -> completed | failed

  `flushed` means a `relationship_ingestion` background job has been enqueued
  for the window and the runtime should not enqueue another. `completed` is set
  once the job successfully runs both passes. `failed` records the last error
  for retries.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Maraithon.Accounts.User

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @statuses ~w(open flushed completed failed)
  @sources ~w(gmail google_calendar slack)

  schema "crm_ingest_windows" do
    field :source, :string
    field :status, :string, default: "open"
    field :opened_at, :utc_datetime_usec
    field :flushed_at, :utc_datetime_usec
    field :completed_at, :utc_datetime_usec
    field :failed_at, :utc_datetime_usec
    field :observation_count, :integer, default: 0
    field :flush_job_id, Ecto.UUID
    field :last_error, :string

    belongs_to :user, User, type: :string

    timestamps(type: :utc_datetime_usec)
  end

  def statuses, do: @statuses
  def sources, do: @sources

  @required_fields [:user_id, :source, :status, :opened_at]
  @optional_fields [
    :flushed_at,
    :completed_at,
    :failed_at,
    :observation_count,
    :flush_job_id,
    :last_error
  ]

  def changeset(window, attrs) do
    window
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:source, @sources)
    |> validate_number(:observation_count, greater_than_or_equal_to: 0)
    |> unique_constraint([:user_id, :source],
      name: :crm_ingest_windows_open_per_source_index,
      message: "open window already exists for this user and source"
    )
  end
end
