defmodule Maraithon.Repo.Migrations.AddPermanentTelegramWebhookDedupe do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    create unique_index(:background_jobs, [:dedupe_key],
             name: :background_jobs_telegram_webhook_dedupe_index,
             where: "job_type = 'telegram_webhook_event' AND dedupe_key IS NOT NULL",
             concurrently: true
           )
  end

  def down do
    drop index(:background_jobs, [:dedupe_key],
           name: :background_jobs_telegram_webhook_dedupe_index,
           concurrently: true
         )
  end
end
