defmodule Maraithon.Repo.Migrations.CreateProactiveCandidates do
  use Ecto.Migration

  def change do
    create table(:proactive_candidates, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, type: :string, on_delete: :delete_all), null: false
      add :source, :string, null: false
      add :source_id, :string, null: false
      add :dedupe_key, :string, null: false
      add :title, :string, null: false
      add :body, :text, null: false
      add :urgency, :float, null: false, default: 0.0
      add :why_now, :text
      add :structured_data, :map, null: false, default: %{}
      add :telegram_opts, :map, null: false, default: %{}
      add :status, :string, null: false, default: "pending"
      add :disposition, :string
      add :plan_reason, :text
      add :planned_at, :utc_datetime_usec
      add :delivered_at, :utc_datetime_usec
      add :expires_at, :utc_datetime_usec, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create index(:proactive_candidates, [:user_id, :status])
    create index(:proactive_candidates, [:status, :inserted_at])

    create unique_index(:proactive_candidates, [:user_id, :dedupe_key],
             name: :proactive_candidates_live_dedupe_index,
             where: "status IN ('pending', 'planned')"
           )
  end
end
