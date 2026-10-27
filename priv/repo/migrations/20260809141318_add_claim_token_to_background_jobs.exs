defmodule Maraithon.Repo.Migrations.AddClaimTokenToBackgroundJobs do
  use Ecto.Migration

  def change do
    alter table(:background_jobs) do
      add :claim_token, :uuid
    end

    create unique_index(:background_jobs, [:claim_token],
             where: "claim_token IS NOT NULL",
             name: :background_jobs_claim_token_index
           )
  end
end
