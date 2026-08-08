defmodule Maraithon.Repo.Migrations.AddEffectOwnerUserId do
  use Ecto.Migration

  def change do
    alter table(:effects) do
      add :owner_user_id, :string
    end
  end
end
