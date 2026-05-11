defmodule Maraithon.Repo.Migrations.CreateCompanionReleases do
  use Ecto.Migration

  def change do
    create table(:companion_releases, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :version, :string, null: false
      add :build_number, :string, null: false
      add :url, :text, null: false
      add :signature, :text, null: false
      add :min_system_version, :string
      add :notes_markdown, :text
      add :released_at, :utc_datetime_usec, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:companion_releases, [:version])
    create index(:companion_releases, [:released_at])
  end
end
