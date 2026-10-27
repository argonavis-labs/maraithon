defmodule Maraithon.Repo.Migrations.AddEffectFailureProvenance do
  use Ecto.Migration

  def change do
    alter table(:effects) do
      add :last_failure_code, :string
      add :last_failure_attempt, :integer
    end
  end
end
