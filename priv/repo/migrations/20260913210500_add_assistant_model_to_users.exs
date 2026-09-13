defmodule Maraithon.Repo.Migrations.AddAssistantModelToUsers do
  use Ecto.Migration

  # One user-chosen model id that overrides every assistant call made on the
  # user's behalf. Nil keeps the configured workspace default.
  def change do
    alter table(:users) do
      add :assistant_model, :string
    end
  end
end
