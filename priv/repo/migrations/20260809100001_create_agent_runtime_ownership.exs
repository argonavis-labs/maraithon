defmodule Maraithon.Repo.Migrations.CreateAgentRuntimeOwnership do
  use Ecto.Migration

  def change do
    create table(:agent_runtime_leases, primary_key: false) do
      add :agent_id,
          references(:agents, type: :uuid, on_delete: :delete_all),
          primary_key: true

      add :owner_token, :uuid, null: false
      add :owner_node, :text, null: false
      add :claimed_at, :utc_datetime_usec, null: false
      add :lease_until, :utc_datetime_usec, null: false
      add :renewed_at, :utc_datetime_usec, null: false
      add :ready_at, :utc_datetime_usec
      add :draining_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:agent_runtime_leases, [:owner_token],
             name: :agent_runtime_leases_owner_token_unique_index
           )

    create index(:agent_runtime_leases, [:lease_until, :agent_id],
             name: :agent_runtime_leases_expiry_index
           )

    create index(:agent_runtime_leases, [:owner_node, :lease_until, :agent_id],
             name: :agent_runtime_leases_owner_expiry_index
           )

    create index(:agent_runtime_leases, [:agent_id, :lease_until],
             where: "ready_at IS NOT NULL AND draining_at IS NULL",
             name: :agent_runtime_leases_ready_index
           )

    create constraint(:agent_runtime_leases, :agent_runtime_leases_owner_node_check,
             check:
               "octet_length(owner_node) BETWEEN 1 AND 255 AND owner_node !~ '[[:space:][:cntrl:]]'"
           )

    create constraint(:agent_runtime_leases, :agent_runtime_leases_time_order_check,
             check:
               "claimed_at <= renewed_at AND renewed_at < lease_until AND " <>
                 "(ready_at IS NULL OR (claimed_at <= ready_at AND ready_at <= lease_until)) AND " <>
                 "(draining_at IS NULL OR (claimed_at <= draining_at AND ready_at IS NULL))"
           )

    create table(:agent_restart_guards, primary_key: false) do
      add :agent_id,
          references(:agents, type: :uuid, on_delete: :delete_all),
          primary_key: true

      add :generation, :uuid, null: false
      add :last_owner_token, :uuid
      add :blocked_until, :utc_datetime_usec
      add :window_started_at, :utc_datetime_usec
      add :crash_count, :integer, null: false, default: 0
      add :tripped, :boolean, null: false, default: false
      add :needs_recovery, :boolean, null: false, default: false
      add :last_reason, :text

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:agent_restart_guards, [:generation],
             name: :agent_restart_guards_generation_unique_index
           )

    create index(:agent_restart_guards, [:blocked_until, :agent_id],
             where: "needs_recovery = TRUE AND tripped = FALSE",
             name: :agent_restart_guards_due_recovery_index
           )

    create index(:agent_restart_guards, [:agent_id],
             where: "tripped = TRUE",
             name: :agent_restart_guards_tripped_index
           )

    create constraint(:agent_restart_guards, :agent_restart_guards_crash_count_check,
             check: "crash_count >= 0"
           )

    create constraint(:agent_restart_guards, :agent_restart_guards_window_check,
             check:
               "(crash_count = 0 AND window_started_at IS NULL) OR " <>
                 "(crash_count > 0 AND window_started_at IS NOT NULL)"
           )

    create constraint(:agent_restart_guards, :agent_restart_guards_recovery_owner_check,
             check: "needs_recovery = FALSE OR last_owner_token IS NOT NULL"
           )

    create constraint(:agent_restart_guards, :agent_restart_guards_reason_check,
             check:
               "last_reason IS NULL OR " <>
                 "(octet_length(last_reason) BETWEEN 1 AND 255 AND last_reason !~ '[[:cntrl:]]')"
           )
  end
end
