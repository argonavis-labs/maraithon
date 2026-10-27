defmodule Maraithon.Repo.Migrations.CreateUserIdentityProfiles do
  use Ecto.Migration

  def change do
    create table(:user_identity_profiles, primary_key: false) do
      add :user_id, :string, primary_key: true
      add :display_name, :string
      add :emails, {:array, :string}, null: false, default: []
      add :phones, {:array, :string}, null: false, default: []
      add :confirmed_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end
  end
end
