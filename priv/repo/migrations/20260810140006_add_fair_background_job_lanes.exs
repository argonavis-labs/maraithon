defmodule Maraithon.Repo.Migrations.AddFairBackgroundJobLanes do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    # DDL transactions are disabled for the online indexes below, so every
    # step must tolerate a deploy interruption and safe migration retry.
    execute("ALTER TABLE background_jobs ADD COLUMN IF NOT EXISTS partition_key varchar(255)")
    execute("ALTER TABLE background_jobs ADD COLUMN IF NOT EXISTS rate_limit_key varchar(255)")

    drop_if_exists index(:background_jobs, [:queue, :partition_key, :status],
                     name: :background_jobs_partition_claim_index,
                     concurrently: true
                   )

    create index(:background_jobs, [:queue, :partition_key, :status],
             name: :background_jobs_partition_claim_index,
             where: "partition_key IS NOT NULL AND status IN ('pending', 'running')",
             concurrently: true
           )

    drop_if_exists index(:background_jobs, [:queue, :rate_limit_key, :status],
                     name: :background_jobs_rate_limit_claim_index,
                     concurrently: true
                   )

    create index(:background_jobs, [:queue, :rate_limit_key, :status],
             name: :background_jobs_rate_limit_claim_index,
             where: "rate_limit_key IS NOT NULL AND status IN ('pending', 'running')",
             concurrently: true
           )

    create_if_not_exists table(:background_job_partitions, primary_key: false) do
      add :queue, :string, null: false, primary_key: true
      add :partition_key, :string, null: false, primary_key: true
      add :last_started_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create_if_not_exists table(:background_job_rate_limits, primary_key: false) do
      add :queue, :string, null: false, primary_key: true
      add :rate_limit_key, :string, null: false, primary_key: true
      add :blocked_until, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create_if_not_exists index(:background_job_rate_limits, [:queue, :blocked_until],
                           name: :background_job_rate_limits_due_index
                         )
  end

  def down do
    raise "fair background job lanes are safety authority and cannot be rolled back automatically"
  end
end
