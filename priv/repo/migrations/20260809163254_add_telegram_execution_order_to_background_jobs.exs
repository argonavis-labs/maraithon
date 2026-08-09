defmodule Maraithon.Repo.Migrations.AddTelegramExecutionOrderToBackgroundJobs do
  use Ecto.Migration

  def up do
    alter table(:background_jobs) do
      add :telegram_bot_id, :string
      add :telegram_update_id, :bigint
    end

    execute("""
    UPDATE background_jobs
    SET telegram_bot_id = split_part(dedupe_key, ':', 2),
        telegram_update_id = split_part(dedupe_key, ':', 3)::bigint
    WHERE job_type = 'telegram_webhook_event'
    """)

    execute("""
    ALTER TABLE background_jobs
    ADD CONSTRAINT background_jobs_telegram_order_fields
    CHECK (
      job_type <> 'telegram_webhook_event' OR
      (telegram_bot_id IS NOT NULL AND telegram_bot_id ~ '^[0-9]+$'
       AND telegram_update_id IS NOT NULL AND telegram_update_id >= 0
       AND dedupe_key IS NOT NULL
       AND dedupe_key = 'telegram-webhook:' || telegram_bot_id || ':' || telegram_update_id::text)
    )
    """)

    create index(:background_jobs, [:telegram_bot_id, :status, :telegram_update_id],
             name: :background_jobs_telegram_execution_order_index,
             where: "job_type = 'telegram_webhook_event' AND status IN ('pending', 'running')"
           )
  end

  def down do
    drop_if_exists index(:background_jobs, [:telegram_bot_id, :status, :telegram_update_id],
                     name: :background_jobs_telegram_execution_order_index
                   )

    execute("""
    ALTER TABLE background_jobs
    DROP CONSTRAINT IF EXISTS background_jobs_telegram_order_fields
    """)

    alter table(:background_jobs) do
      remove :telegram_bot_id
      remove :telegram_update_id
    end
  end
end
