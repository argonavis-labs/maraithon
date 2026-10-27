defmodule Maraithon.Repo.Migrations.AddEffectCompletionClaimProof do
  use Ecto.Migration

  def change do
    alter table(:effects) do
      add :completion_claimed_by, :string
      add :completion_claimed_at, :utc_datetime_usec
      add :agent_run_id, :binary_id
      add :agent_run_step_id, :binary_id
      add :result_envelope, :map
      add :result_dispatched_at, :utc_datetime_usec
      add :result_acknowledged_at, :utc_datetime_usec
    end
  end
end
