defmodule Maraithon.Privacy.RetentionStatus do
  @moduledoc "Content-free durable health and fairness cursor for one retention handler."

  use Ecto.Schema

  @primary_key {:handler, :string, autogenerate: false}

  schema "privacy_retention_statuses" do
    field :tenant_cursor, :string, redact: true
    field :backlog_count, :integer
    field :oldest_age_seconds, :integer
    field :consecutive_failures, :integer
    field :alert_state, :string
    field :last_error_code, :string
    field :last_started_at, :utc_datetime_usec
    field :last_finished_at, :utc_datetime_usec
    field :last_succeeded_at, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec)
  end
end
