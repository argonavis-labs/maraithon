defmodule Maraithon.Repo.Migrations.AddChangelogToAgentPackageVersions do
  use Ecto.Migration

  def change do
    alter table(:agent_package_versions) do
      add :changelog, :text
    end
  end
end
