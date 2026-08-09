defmodule Maraithon.Repo.Migrations.AddPermanentTelegramWebhookDedupe do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    # An interrupted CREATE INDEX CONCURRENTLY may leave an invalid index with
    # this name. Drop it first rather than silently accepting it via
    # create_if_not_exists.
    drop_if_exists index(:background_jobs, [:dedupe_key],
                     name: :background_jobs_telegram_webhook_dedupe_index,
                     concurrently: true
                   )

    create unique_index(:background_jobs, [:dedupe_key],
             name: :background_jobs_telegram_webhook_dedupe_index,
             where: "job_type = 'telegram_webhook_event' AND dedupe_key IS NOT NULL",
             concurrently: true
           )
  end

  def down do
    drop_if_exists index(:background_jobs, [:dedupe_key],
                     name: :background_jobs_telegram_webhook_dedupe_index,
                     concurrently: true
                   )
  end
end
