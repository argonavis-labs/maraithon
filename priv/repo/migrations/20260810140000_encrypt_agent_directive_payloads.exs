defmodule Maraithon.Repo.Migrations.EncryptAgentDirectivePayloads do
  use Ecto.Migration

  def up do
    alter table(:agent_directives) do
      add_if_not_exists :payload_ciphertext, :binary
      add_if_not_exists :payload_encryption_version, :smallint
      add_if_not_exists :payload_purged_at, :utc_datetime_usec
    end

    create_if_not_exists index(:agent_directives, [:payload_purged_at, :id],
                           name: :agent_directives_payload_retention_index,
                           where:
                             "payload_purged_at IS NULL AND status IN ('completed', 'dead_letter', 'cancelled')"
                         )
  end

  def down do
    raise "encrypted Directive payload storage is irreversible after backfill"
  end
end
