defmodule Maraithon.Repo.Migrations.AddFairBackgroundJobLanes do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    alter table(:background_jobs) do
      add :partition_key, :string
      add :rate_limit_key, :string
    end

    create index(:background_jobs, [:queue, :partition_key, :status],
             name: :background_jobs_partition_claim_index,
             where: "partition_key IS NOT NULL AND status IN ('pending', 'running')",
             concurrently: true
           )

    create index(:background_jobs, [:queue, :rate_limit_key, :status],
             name: :background_jobs_rate_limit_claim_index,
             where: "rate_limit_key IS NOT NULL AND status IN ('pending', 'running')",
             concurrently: true
           )

    create table(:background_job_partitions, primary_key: false) do
      add :queue, :string, null: false, primary_key: true
      add :partition_key, :string, null: false, primary_key: true
      add :last_started_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create table(:background_job_rate_limits, primary_key: false) do
      add :queue, :string, null: false, primary_key: true
      add :rate_limit_key, :string, null: false, primary_key: true
      add :blocked_until, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create index(:background_job_rate_limits, [:queue, :blocked_until],
             name: :background_job_rate_limits_due_index
           )
  end

  def down do
    raise "fair background job lanes are safety authority and cannot be rolled back automatically"
  end
end
