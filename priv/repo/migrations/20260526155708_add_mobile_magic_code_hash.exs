defmodule Maraithon.Repo.Migrations.AddMobileMagicCodeHash do
  use Ecto.Migration

  def change do
    alter table(:user_magic_links) do
      add :code_hash, :binary
    end

    create index(:user_magic_links, [:code_hash])
  end
end
