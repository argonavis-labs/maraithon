defmodule Maraithon.Repo.Migrations.CreateRuntimeCoordinationAuthority do
  use Ecto.Migration

  @disable_ddl_transaction true
  @partition_count 64

  # This protocol is intentionally expansion-only. Production activation is a
  # separate, stopped-fleet operator transaction; there is no rollback path.
  def up do
    repo().checkout(
      fn ->
        repo().query!(
          "SELECT pg_catalog.pg_advisory_lock(20260810, 140004)",
          [],
          timeout: :infinity
        )

        try do
          migrate()
          flush()
        after
          repo().query!(
            "SELECT pg_catalog.pg_advisory_unlock(20260810, 140004)",
            [],
            timeout: :infinity
          )
        end
      end,
      timeout: :infinity
    )
  end

  defp migrate do
    execute("CREATE EXTENSION IF NOT EXISTS pgcrypto")

    execute("""
    CREATE OR REPLACE FUNCTION public.runtime_coordination_roles_ready()
    RETURNS boolean
    LANGUAGE sql
    STABLE
    SET search_path = pg_catalog, public
    AS $function$
      WITH canonical(role_name) AS (
        VALUES
          ('maraithon_object_owner'),
          ('maraithon_migrator'),
          ('maraithon_runtime'),
          ('maraithon_payload_verifier'),
          ('maraithon_incident_operator'),
          ('maraithon_activation_operator')
      ), roles AS (
        SELECT role_row.*
        FROM pg_catalog.pg_roles AS role_row
        JOIN canonical ON canonical.role_name = role_row.rolname
      ), relevant_memberships AS (
        SELECT member_role.rolname AS member_name, granted_role.rolname AS granted_name
        FROM pg_catalog.pg_auth_members AS membership
        JOIN pg_catalog.pg_roles AS member_role ON member_role.oid = membership.member
        JOIN pg_catalog.pg_roles AS granted_role ON granted_role.oid = membership.roleid
        WHERE member_role.rolname IN (SELECT role_name FROM canonical)
           OR granted_role.rolname IN (SELECT role_name FROM canonical)
      )
      SELECT
        (SELECT count(*) = 6 AND
                bool_and(NOT rolsuper AND NOT rolcreaterole AND NOT rolcreatedb AND
                         NOT rolreplication AND NOT rolbypassrls)
         FROM roles) AND
        (SELECT NOT rolcanlogin FROM roles
         WHERE rolname = 'maraithon_object_owner') AND
        (SELECT bool_and(rolcanlogin) FROM roles
         WHERE rolname <> 'maraithon_object_owner') AND
        (SELECT count(*) = 1 AND
                bool_and(member_name = 'maraithon_migrator' AND
                         granted_name = 'maraithon_object_owner')
         FROM relevant_memberships)
    $function$;
    """)

    execute("""
    DO $role_topology$
    BEGIN
      IF NOT public.runtime_coordination_roles_ready() THEN
        RAISE EXCEPTION 'canonical runtime coordination roles must be provisioned before migration'
          USING ERRCODE = 'invalid_authorization_specification';
      END IF;
    END;
    $role_topology$;
    """)

    execute("""
    CREATE OR REPLACE FUNCTION public.runtime_role_topology_fingerprint()
    RETURNS text
    LANGUAGE sql
    STABLE
    SET search_path = pg_catalog, public
    AS $function$
      WITH canonical(role_name) AS (
        VALUES
          ('maraithon_object_owner'),
          ('maraithon_migrator'),
          ('maraithon_runtime'),
          ('maraithon_payload_verifier'),
          ('maraithon_incident_operator'),
          ('maraithon_activation_operator')
      ), roles AS (
        SELECT pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
          'name', role_row.rolname,
          'superuser', role_row.rolsuper,
          'inherit', role_row.rolinherit,
          'create_role', role_row.rolcreaterole,
          'create_db', role_row.rolcreatedb,
          'can_login', role_row.rolcanlogin,
          'replication', role_row.rolreplication,
          'bypass_rls', role_row.rolbypassrls,
          'connection_limit', role_row.rolconnlimit,
          'valid_until', role_row.rolvaliduntil
        ) ORDER BY role_row.rolname) AS value
        FROM pg_catalog.pg_roles AS role_row
        JOIN canonical ON canonical.role_name = role_row.rolname
      ), memberships AS (
        SELECT COALESCE(pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
          'member', member_role.rolname,
          'granted', granted_role.rolname,
          'admin', membership.admin_option
        ) ORDER BY member_role.rolname, granted_role.rolname), '[]'::jsonb) AS value
        FROM pg_catalog.pg_auth_members AS membership
        JOIN pg_catalog.pg_roles AS member_role ON member_role.oid = membership.member
        JOIN pg_catalog.pg_roles AS granted_role ON granted_role.oid = membership.roleid
        WHERE member_role.rolname IN (SELECT role_name FROM canonical)
           OR granted_role.rolname IN (SELECT role_name FROM canonical)
      )
      SELECT encode(public.digest(convert_to(pg_catalog.jsonb_build_object(
        'roles', roles.value, 'memberships', memberships.value
      )::text, 'UTF8'), 'sha256'), 'hex')
      FROM roles, memberships
    $function$;
    """)

    create_if_not_exists table(:runtime_coordination_protocols, primary_key: false) do
      add :name, :string, primary_key: true
      add :mode, :string, null: false, default: "dark"
      add :partition_count, :smallint, null: false, default: @partition_count
      add :activation_epoch, :uuid
      add :activated_at, :utc_datetime_usec
      add :activation_evidence_id, :string
      add :activation_evidence_digest, :binary
      add :activated_by, :string
      add :exact_revision, :string
      add :manifest_digest, :binary, null: false
      timestamps(type: :utc_datetime_usec)
    end

    drop_if_exists constraint(
                     :runtime_coordination_protocols,
                     :runtime_coordination_protocol_shape
                   )

    create constraint(:runtime_coordination_protocols, :runtime_coordination_protocol_shape,
             check: """
             name = 'runtime' AND partition_count = #{@partition_count} AND
             ((mode = 'dark' AND activation_epoch IS NULL AND activated_at IS NULL AND
                activation_evidence_id IS NULL AND activation_evidence_digest IS NULL AND
                activated_by IS NULL AND exact_revision IS NULL) OR
              (mode = 'partition_fenced_v1' AND activation_epoch IS NOT NULL AND
               activated_at IS NOT NULL AND
               octet_length(activation_evidence_id) BETWEEN 1 AND 256 AND
               octet_length(activation_evidence_digest) = 32 AND
               octet_length(activated_by) BETWEEN 1 AND 320 AND
               octet_length(exact_revision) BETWEEN 7 AND 255)) AND
             octet_length(manifest_digest) = 32
             """
           )

    create_if_not_exists table(:runtime_coordination_manifests, primary_key: false) do
      add :name, :string, primary_key: true
      add :constraint_fingerprints, :map, null: false
      add :function_fingerprints, :map, null: false
      add :trigger_fingerprints, :map, null: false
      add :index_fingerprints, :map, null: false
      add :catalog_fingerprints, :map, null: false
      timestamps(type: :utc_datetime_usec)
    end

    drop_if_exists constraint(
                     :runtime_coordination_manifests,
                     :runtime_coordination_manifest_singleton
                   )

    create constraint(:runtime_coordination_manifests, :runtime_coordination_manifest_singleton,
             check: "name = 'runtime'"
           )

    alter table(:effect_execution_protocols) do
      add_if_not_exists :activation_evidence_id, :string
      add_if_not_exists :activation_evidence_digest, :binary
      add_if_not_exists :activated_by, :string
      add_if_not_exists :exact_revision, :string
    end

    drop_if_exists constraint(:effect_execution_protocols, :effect_activation_evidence_shape)

    create constraint(:effect_execution_protocols, :effect_activation_evidence_shape,
             check: """
             (activation_evidence_id IS NULL AND activation_evidence_digest IS NULL AND
              activated_by IS NULL AND exact_revision IS NULL) OR
             (octet_length(activation_evidence_id) BETWEEN 1 AND 256 AND
              octet_length(activation_evidence_digest) = 32 AND
              octet_length(activated_by) BETWEEN 1 AND 320 AND
              octet_length(exact_revision) BETWEEN 7 AND 255)
             """
           )

    create_if_not_exists table(:runtime_node_incarnations, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :activation_epoch, :uuid, null: false
      add :node_name, :string, null: false
      add :revision, :string, null: false
      add :state, :string, null: false
      add :lease_expires_at, :utc_datetime_usec, null: false
      add :ready_at, :utc_datetime_usec
      add :draining_at, :utc_datetime_usec
      add :revoked_at, :utc_datetime_usec
      add :metadata, :map, null: false, default: %{}
      timestamps(type: :utc_datetime_usec)
    end

    drop_if_exists constraint(:runtime_node_incarnations, :runtime_node_incarnations_shape)

    create constraint(:runtime_node_incarnations, :runtime_node_incarnations_shape,
             check: """
             octet_length(node_name) BETWEEN 1 AND 255 AND
             octet_length(revision) BETWEEN 1 AND 255 AND
             state IN ('joining', 'ready', 'draining', 'revoked') AND
             ((state = 'joining' AND ready_at IS NULL AND draining_at IS NULL AND revoked_at IS NULL) OR
              (state = 'ready' AND ready_at IS NOT NULL AND draining_at IS NULL AND revoked_at IS NULL) OR
              (state = 'draining' AND ready_at IS NULL AND draining_at IS NOT NULL AND revoked_at IS NULL) OR
              (state = 'revoked' AND ready_at IS NULL AND revoked_at IS NOT NULL))
             """
           )

    drop_invalid_index("runtime_node_incarnations_state_lease_expires_at_index")
    create_if_not_exists index(:runtime_node_incarnations, [:state, :lease_expires_at])
    drop_invalid_index("runtime_node_incarnations_node_name_inserted_at_index")
    create_if_not_exists index(:runtime_node_incarnations, [:node_name, :inserted_at])

    create_if_not_exists table(:runtime_leader_authorities, primary_key: false) do
      add :role, :string, primary_key: true
      add :activation_epoch, :uuid
      add :leader_epoch, :bigint, null: false, default: 0
      add :node_incarnation_id, :uuid
      add :action_token, :uuid
      add :state, :string, null: false, default: "unassigned"
      add :lease_expires_at, :utc_datetime_usec
      add :ready_at, :utc_datetime_usec
      add :draining_at, :utc_datetime_usec
      timestamps(type: :utc_datetime_usec)
    end

    drop_if_exists constraint(:runtime_leader_authorities, :runtime_leader_authorities_shape)

    create constraint(:runtime_leader_authorities, :runtime_leader_authorities_shape,
             check: """
             role = 'partition_planner' AND leader_epoch >= 0 AND
             ((state = 'unassigned' AND node_incarnation_id IS NULL AND action_token IS NULL AND
               lease_expires_at IS NULL AND ready_at IS NULL AND draining_at IS NULL) OR
              (state = 'preparing' AND activation_epoch IS NOT NULL AND
               node_incarnation_id IS NOT NULL AND action_token IS NOT NULL AND
               lease_expires_at IS NOT NULL AND ready_at IS NULL AND draining_at IS NULL) OR
              (state = 'ready' AND activation_epoch IS NOT NULL AND
               node_incarnation_id IS NOT NULL AND action_token IS NOT NULL AND
               lease_expires_at IS NOT NULL AND ready_at IS NOT NULL AND draining_at IS NULL) OR
              (state = 'draining' AND activation_epoch IS NOT NULL AND
               node_incarnation_id IS NOT NULL AND action_token IS NOT NULL AND
               lease_expires_at IS NOT NULL AND ready_at IS NULL AND draining_at IS NOT NULL))
             """
           )

    create_if_not_exists table(:runtime_partitions, primary_key: false) do
      add :partition_id, :smallint, primary_key: true
      add :activation_epoch, :uuid
      add :ownership_epoch, :bigint, null: false, default: 0
      add :owner_node_incarnation_id, :uuid
      add :transition_id, :uuid
      add :state, :string, null: false, default: "unassigned"
      add :lease_expires_at, :utc_datetime_usec
      add :ready_at, :utc_datetime_usec
      add :draining_at, :utc_datetime_usec
      add :last_moved_at, :utc_datetime_usec
      add :fair_sequence, :bigint, null: false, default: 0
      timestamps(type: :utc_datetime_usec)
    end

    drop_if_exists constraint(:runtime_partitions, :runtime_partitions_shape)

    create constraint(:runtime_partitions, :runtime_partitions_shape,
             check: """
             partition_id >= 0 AND partition_id < #{@partition_count} AND
             ownership_epoch >= 0 AND fair_sequence >= 0 AND
             ((state = 'unassigned' AND owner_node_incarnation_id IS NULL AND
               transition_id IS NULL AND lease_expires_at IS NULL AND ready_at IS NULL AND
               draining_at IS NULL) OR
              (state = 'preparing' AND activation_epoch IS NOT NULL AND ownership_epoch > 0 AND
               owner_node_incarnation_id IS NOT NULL AND transition_id IS NOT NULL AND
               lease_expires_at IS NOT NULL AND ready_at IS NULL AND draining_at IS NULL) OR
              (state = 'ready' AND activation_epoch IS NOT NULL AND ownership_epoch > 0 AND
               owner_node_incarnation_id IS NOT NULL AND transition_id IS NOT NULL AND
               lease_expires_at IS NOT NULL AND ready_at IS NOT NULL AND draining_at IS NULL) OR
              (state IN ('draining', 'blocked') AND activation_epoch IS NOT NULL AND
               ownership_epoch > 0 AND owner_node_incarnation_id IS NOT NULL AND
               transition_id IS NOT NULL AND ready_at IS NULL AND draining_at IS NOT NULL))
             """
           )

    drop_invalid_index("runtime_partitions_state_lease_expires_at_index")
    create_if_not_exists index(:runtime_partitions, [:state, :lease_expires_at])
    drop_invalid_index("runtime_partitions_owner_node_incarnation_id_state_index")
    create_if_not_exists index(:runtime_partitions, [:owner_node_incarnation_id, :state])

    create_if_not_exists table(:runtime_partition_transitions, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :activation_epoch, :uuid, null: false
      add :partition_id, :smallint, null: false
      add :partition_epoch, :bigint, null: false
      add :from_node_incarnation_id, :uuid
      add :to_node_incarnation_id, :uuid
      add :kind, :string, null: false
      add :state, :string, null: false
      add :leader_node_incarnation_id, :uuid, null: false
      add :leader_epoch, :bigint, null: false
      add :leader_action_token, :uuid, null: false
      add :requested_at, :utc_datetime_usec, null: false
      add :ready_at, :utc_datetime_usec
      add :completed_at, :utc_datetime_usec
      add :blocked_reason, :string
      timestamps(type: :utc_datetime_usec)
    end

    drop_if_exists constraint(
                     :runtime_partition_transitions,
                     :runtime_partition_transitions_shape
                   )

    create constraint(:runtime_partition_transitions, :runtime_partition_transitions_shape,
             check: """
             partition_id >= 0 AND partition_id < #{@partition_count} AND partition_epoch > 0 AND
             kind IN ('assign', 'rebalance', 'steal', 'shutdown', 'lease_expired') AND
             state IN ('preparing', 'ready', 'draining', 'blocked', 'completed') AND
             leader_epoch > 0 AND
             ((state = 'preparing' AND ready_at IS NULL AND completed_at IS NULL AND blocked_reason IS NULL) OR
              (state = 'ready' AND ready_at IS NOT NULL AND completed_at IS NULL AND blocked_reason IS NULL) OR
              (state = 'draining' AND completed_at IS NULL AND blocked_reason IS NULL) OR
              (state = 'blocked' AND completed_at IS NULL AND blocked_reason IS NOT NULL) OR
              (state = 'completed' AND completed_at IS NOT NULL))
             """
           )

    drop_invalid_index("runtime_partition_transitions_partition_id_partition_epoch_index")
    create_if_not_exists index(:runtime_partition_transitions, [:partition_id, :partition_epoch])
    drop_invalid_index("runtime_partition_transitions_state_requested_at_index")
    create_if_not_exists index(:runtime_partition_transitions, [:state, :requested_at])

    create_if_not_exists table(:runtime_task_assignments, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :activation_epoch, :uuid, null: false
      add :work_kind, :string, null: false
      add :work_id, :uuid, null: false
      add :claim_token, :uuid, null: false
      add :partition_id, :smallint, null: false
      add :partition_epoch, :bigint, null: false
      add :node_incarnation_id, :uuid, null: false
      add :supervisor_id, :uuid, null: false
      add :local_task_id, :uuid, null: false
      add :state, :string, null: false
      add :provider_boundary, :string, null: false, default: "not_entered"
      add :lease_expires_at, :utc_datetime_usec, null: false
      add :ready_at, :utc_datetime_usec
      add :termination_requested_at, :utc_datetime_usec
      add :termination_proven_at, :utc_datetime_usec
      add :settled_at, :utc_datetime_usec
      add :outcome, :string
      timestamps(type: :utc_datetime_usec)
    end

    drop_if_exists constraint(:runtime_task_assignments, :runtime_task_assignments_shape)

    create constraint(:runtime_task_assignments, :runtime_task_assignments_shape,
             check: """
             work_kind IN ('background_job', 'effect') AND
             partition_id >= 0 AND partition_id < #{@partition_count} AND partition_epoch > 0 AND
             state IN ('reserved', 'running', 'termination_requested', 'termination_proven',
                       'settled', 'outcome_ambiguous') AND
             provider_boundary IN ('not_entered', 'entered', 'outcome_known', 'outcome_unknown') AND
             ((state = 'reserved' AND ready_at IS NULL AND termination_requested_at IS NULL AND
               termination_proven_at IS NULL AND settled_at IS NULL AND outcome IS NULL) OR
              (state = 'running' AND ready_at IS NOT NULL AND termination_requested_at IS NULL AND
               termination_proven_at IS NULL AND settled_at IS NULL AND outcome IS NULL) OR
              (state = 'termination_requested' AND termination_requested_at IS NOT NULL AND
               termination_proven_at IS NULL AND settled_at IS NULL AND outcome IS NULL) OR
              (state = 'termination_proven' AND termination_requested_at IS NOT NULL AND
               termination_proven_at IS NOT NULL AND settled_at IS NULL AND outcome IS NULL) OR
              (state IN ('settled', 'outcome_ambiguous') AND settled_at IS NOT NULL AND
               outcome IS NOT NULL))
             """
           )

    drop_invalid_index("runtime_task_assignments_claim_token_index")

    create_if_not_exists unique_index(:runtime_task_assignments, [:claim_token],
                           name: :runtime_task_assignments_claim_token_index
                         )

    drop_invalid_index("runtime_task_assignments_physical_identity_index")

    create_if_not_exists unique_index(
                           :runtime_task_assignments,
                           [:node_incarnation_id, :supervisor_id, :local_task_id],
                           name: :runtime_task_assignments_physical_identity_index
                         )

    drop_invalid_index("runtime_task_assignments_active_work_index")

    create_if_not_exists unique_index(:runtime_task_assignments, [:work_kind, :work_id],
                           where:
                             "state IN ('reserved', 'running', 'termination_requested', 'termination_proven')",
                           name: :runtime_task_assignments_active_work_index
                         )

    drop_invalid_index("runtime_task_assignments_partition_id_partition_epoch_state_index")

    create_if_not_exists index(:runtime_task_assignments, [
                           :partition_id,
                           :partition_epoch,
                           :state
                         ])

    drop_invalid_index("runtime_task_assignments_state_lease_expires_at_index")
    create_if_not_exists index(:runtime_task_assignments, [:state, :lease_expires_at])

    create_if_not_exists table(:runtime_task_outcome_evidence, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :assignment_id, :uuid, null: false
      add :activation_epoch, :uuid, null: false
      add :claim_token, :uuid, null: false
      add :node_incarnation_id, :uuid, null: false
      add :supervisor_id, :uuid, null: false
      add :local_task_id, :uuid, null: false
      add :outcome, :string, null: false
      add :recorded_at, :utc_datetime_usec, null: false
      timestamps(type: :utc_datetime_usec)
    end

    drop_invalid_index("runtime_task_outcome_evidence_assignment_index")

    create_if_not_exists unique_index(:runtime_task_outcome_evidence, [:assignment_id],
                           name: :runtime_task_outcome_evidence_assignment_index
                         )

    drop_if_exists constraint(
                     :runtime_task_outcome_evidence,
                     :runtime_task_outcome_evidence_shape
                   )

    create constraint(:runtime_task_outcome_evidence, :runtime_task_outcome_evidence_shape,
             check: "octet_length(outcome) BETWEEN 1 AND 255"
           )

    create_if_not_exists table(:runtime_task_termination_proofs, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :assignment_id, :uuid, null: false
      add :activation_epoch, :uuid, null: false
      add :claim_token, :uuid, null: false
      add :node_incarnation_id, :uuid, null: false
      add :supervisor_id, :uuid, null: false
      add :local_task_id, :uuid, null: false
      add :proof_kind, :string, null: false
      add :evidence_id, :string, null: false
      add :evidence_digest, :binary, null: false
      add :proved_by, :string, null: false
      add :proved_at, :utc_datetime_usec, null: false
      timestamps(type: :utc_datetime_usec)
    end

    drop_invalid_index("runtime_task_termination_proofs_assignment_index")

    create_if_not_exists unique_index(:runtime_task_termination_proofs, [:assignment_id],
                           name: :runtime_task_termination_proofs_assignment_index
                         )

    drop_if_exists constraint(
                     :runtime_task_termination_proofs,
                     :runtime_task_termination_proofs_shape
                   )

    create constraint(:runtime_task_termination_proofs, :runtime_task_termination_proofs_shape,
             check: """
             proof_kind IN ('supervisor_down', 'external_destroyed') AND
             octet_length(evidence_id) BETWEEN 1 AND 256 AND
             octet_length(evidence_digest) = 32 AND
             octet_length(proved_by) BETWEEN 1 AND 320
             """
           )

    create_if_not_exists table(:runtime_tenant_fairness, primary_key: false) do
      add :tenant_key, :string, primary_key: true
      add :partition_id, :smallint, null: false
      add :max_concurrency, :smallint, null: false, default: 1
      add :rate_per_minute, :integer, null: false, default: 60
      add :burst, :integer, null: false, default: 10
      add :available_microunits, :bigint, null: false, default: 10_000_000
      add :refilled_at, :utc_datetime_usec, null: false
      add :last_served_sequence, :bigint, null: false, default: 0
      add :served_count, :bigint, null: false, default: 0
      timestamps(type: :utc_datetime_usec)
    end

    drop_if_exists constraint(:runtime_tenant_fairness, :runtime_tenant_fairness_bounds)

    create constraint(:runtime_tenant_fairness, :runtime_tenant_fairness_bounds,
             check: """
             octet_length(tenant_key) BETWEEN 1 AND 512 AND
             partition_id >= 0 AND partition_id < #{@partition_count} AND
             max_concurrency BETWEEN 1 AND 64 AND rate_per_minute BETWEEN 1 AND 100000 AND
             burst BETWEEN 1 AND 10000 AND available_microunits >= 0 AND
             last_served_sequence >= 0 AND served_count >= 0
             """
           )

    drop_invalid_index(
      "runtime_tenant_fairness_partition_id_last_served_sequence_tenant_key_index"
    )

    create_if_not_exists index(:runtime_tenant_fairness, [
                           :partition_id,
                           :last_served_sequence,
                           :tenant_key
                         ])

    create_if_not_exists table(:runtime_partition_rebalance_requests, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :activation_epoch, :uuid, null: false
      add :partition_id, :smallint, null: false
      add :partition_epoch, :bigint, null: false
      add :requester_node_incarnation_id, :uuid, null: false
      add :request_token, :uuid, null: false
      add :target_node_incarnation_id, :uuid
      add :reason, :string, null: false
      add :state, :string, null: false, default: "pending"
      add :requested_at, :utc_datetime_usec, null: false
      add :resolved_at, :utc_datetime_usec
      timestamps(type: :utc_datetime_usec)
    end

    drop_invalid_index("runtime_partition_rebalance_requests_pending_partition_index")

    create_if_not_exists unique_index(:runtime_partition_rebalance_requests, [:partition_id],
                           where: "state = 'pending'",
                           name: :runtime_partition_rebalance_requests_pending_partition_index
                         )

    drop_if_exists constraint(
                     :runtime_partition_rebalance_requests,
                     :runtime_partition_rebalance_requests_shape
                   )

    create constraint(
             :runtime_partition_rebalance_requests,
             :runtime_partition_rebalance_requests_shape,
             check: """
             partition_id >= 0 AND partition_id < #{@partition_count} AND partition_epoch > 0 AND
             octet_length(reason) BETWEEN 1 AND 255 AND
             state IN ('pending', 'accepted', 'rejected') AND
             ((state = 'pending' AND resolved_at IS NULL) OR
              (state IN ('accepted', 'rejected') AND resolved_at IS NOT NULL))
             """
           )

    alter table(:background_jobs) do
      add_if_not_exists :tenant_key, :string
      add_if_not_exists :partition_id, :smallint
      add_if_not_exists :coordination_activation_epoch, :uuid
      add_if_not_exists :coordination_partition_epoch, :bigint
      add_if_not_exists :coordination_node_incarnation_id, :uuid
      add_if_not_exists :coordination_task_assignment_id, :uuid
      add_if_not_exists :coordination_task_supervisor_id, :uuid
      add_if_not_exists :coordination_local_task_id, :uuid
    end

    alter table(:scheduled_jobs) do
      add_if_not_exists :tenant_key, :string
      add_if_not_exists :partition_id, :smallint
      add_if_not_exists :dispatch_token, :uuid
      add_if_not_exists :coordination_activation_epoch, :uuid
      add_if_not_exists :coordination_partition_epoch, :bigint
      add_if_not_exists :coordination_node_incarnation_id, :uuid
    end

    alter table(:agent_runtime_leases) do
      add_if_not_exists :coordination_activation_epoch, :uuid
      add_if_not_exists :coordination_partition_id, :smallint
      add_if_not_exists :coordination_partition_epoch, :bigint
      add_if_not_exists :coordination_node_incarnation_id, :uuid
    end

    alter table(:effects) do
      add_if_not_exists :coordination_activation_epoch, :uuid
      add_if_not_exists :coordination_partition_id, :smallint
      add_if_not_exists :coordination_partition_epoch, :bigint
      add_if_not_exists :coordination_node_incarnation_id, :uuid
      add_if_not_exists :coordination_task_assignment_id, :uuid
    end

    execute("DROP INDEX CONCURRENTLY IF EXISTS public.background_jobs_partition_due_index")

    create_if_not_exists index(:background_jobs, [:partition_id, :status, :scheduled_at],
                           name: :background_jobs_partition_due_index,
                           where: "status = 'pending'",
                           concurrently: true
                         )

    execute("DROP INDEX CONCURRENTLY IF EXISTS public.background_jobs_tenant_active_index")

    create_if_not_exists index(:background_jobs, [:tenant_key, :status],
                           name: :background_jobs_tenant_active_index,
                           where: "status IN ('pending', 'running')",
                           concurrently: true
                         )

    execute("DROP INDEX CONCURRENTLY IF EXISTS public.scheduled_jobs_partition_due_index")

    create_if_not_exists index(:scheduled_jobs, [:partition_id, :status, :fire_at],
                           name: :scheduled_jobs_partition_due_index,
                           where: "status = 'pending'",
                           concurrently: true
                         )

    execute(
      "DROP INDEX CONCURRENTLY IF EXISTS public.agent_runtime_leases_coordination_partition_index"
    )

    create_if_not_exists index(:agent_runtime_leases, [:coordination_partition_id, :lease_until],
                           name: :agent_runtime_leases_coordination_partition_index,
                           concurrently: true
                         )

    execute(
      "DROP INDEX CONCURRENTLY IF EXISTS public.effects_coordination_partition_pending_index"
    )

    create_if_not_exists index(:effects, [:coordination_partition_id, :status, :retry_after],
                           name: :effects_coordination_partition_pending_index,
                           where: "status = 'pending'",
                           concurrently: true
                         )

    execute("""
    CREATE OR REPLACE FUNCTION public.runtime_partition_for(tenant text)
    RETURNS smallint
    LANGUAGE sql
    IMMUTABLE
    STRICT
    SET search_path = pg_catalog, public
    AS $function$
      SELECT mod((('x' || substr(md5(tenant), 1, 8))::bit(32)::bigint),
                 #{@partition_count})::smallint
    $function$;
    """)

    execute("""
    CREATE OR REPLACE FUNCTION public.populate_runtime_work_partition()
    RETURNS trigger
    LANGUAGE plpgsql
    SET search_path = pg_catalog, public
    AS $function$
    DECLARE
      resolved_tenant text;
    BEGIN
      IF TG_TABLE_NAME = 'background_jobs' THEN
        resolved_tenant := COALESCE(NULLIF(btrim(NEW.tenant_key), ''),
          CASE
            WHEN NEW.user_id IS NOT NULL AND btrim(NEW.user_id) <> ''
              THEN 'user:' || NEW.user_id
            WHEN NEW.telegram_bot_id IS NOT NULL AND btrim(NEW.telegram_bot_id) <> ''
              THEN 'telegram:' || NEW.telegram_bot_id
            ELSE 'system:' || COALESCE(NULLIF(btrim(NEW.queue), ''), 'default')
          END);
        NEW.tenant_key := resolved_tenant;
        NEW.partition_id := public.runtime_partition_for(resolved_tenant);
      ELSIF TG_TABLE_NAME = 'scheduled_jobs' THEN
        IF NEW.tenant_key IS NULL OR btrim(NEW.tenant_key) = '' THEN
          SELECT 'user:' || agent.user_id INTO resolved_tenant
          FROM public.agents AS agent
          WHERE agent.id = NEW.agent_id AND agent.user_id IS NOT NULL;
          IF resolved_tenant IS NULL THEN
            -- Expansion must not change legacy scheduling while coordination is
            -- dark. The activation backfill barrier still rejects these null
            -- tenant rows before partition-fenced mode can be enabled.
            IF EXISTS (
              SELECT 1 FROM public.runtime_coordination_protocols
              WHERE name = 'runtime' AND mode = 'dark'
            ) THEN
              NEW.tenant_key := NULL;
              NEW.partition_id := NULL;
              RETURN NEW;
            END IF;

            RAISE EXCEPTION 'scheduled job tenant is unavailable'
              USING ERRCODE = 'check_violation';
          END IF;
          NEW.tenant_key := resolved_tenant;
        ELSE
          resolved_tenant := NEW.tenant_key;
        END IF;
        NEW.partition_id := public.runtime_partition_for(resolved_tenant);
      END IF;
      RETURN NEW;
    END;
    $function$;
    """)

    execute(
      "DROP TRIGGER IF EXISTS populate_background_job_partition_trigger ON public.background_jobs"
    )

    execute("""
    CREATE TRIGGER populate_background_job_partition_trigger
      BEFORE INSERT OR UPDATE OF user_id, queue, telegram_bot_id, tenant_key
      ON public.background_jobs
      FOR EACH ROW EXECUTE FUNCTION public.populate_runtime_work_partition()
    """)

    execute(
      "DROP TRIGGER IF EXISTS populate_scheduled_job_partition_trigger ON public.scheduled_jobs"
    )

    execute("""
    CREATE TRIGGER populate_scheduled_job_partition_trigger
      BEFORE INSERT OR UPDATE OF agent_id, tenant_key
      ON public.scheduled_jobs
      FOR EACH ROW EXECUTE FUNCTION public.populate_runtime_work_partition()
    """)

    # Existing rows remain nullable during the expansion. A bounded operator
    # backfill uses SKIP LOCKED; activation repeats the zero-null proof while
    # holding the work tables in SHARE mode. No migration-time table rewrite.
    execute(
      "ALTER TABLE public.background_jobs DROP CONSTRAINT IF EXISTS background_jobs_partition_shape"
    )

    execute("""
    ALTER TABLE public.background_jobs
      ADD CONSTRAINT background_jobs_partition_shape CHECK (
        (tenant_key IS NULL AND partition_id IS NULL) OR
        (octet_length(tenant_key) BETWEEN 1 AND 512 AND
         partition_id >= 0 AND partition_id < #{@partition_count})
      ) NOT VALID
    """)

    execute(
      "ALTER TABLE public.scheduled_jobs DROP CONSTRAINT IF EXISTS scheduled_jobs_partition_shape"
    )

    execute("""
    ALTER TABLE public.scheduled_jobs
      ADD CONSTRAINT scheduled_jobs_partition_shape CHECK (
        (tenant_key IS NULL AND partition_id IS NULL) OR
        (octet_length(tenant_key) BETWEEN 1 AND 512 AND
         partition_id >= 0 AND partition_id < #{@partition_count})
      ) NOT VALID
    """)

    execute(
      "ALTER TABLE public.background_jobs VALIDATE CONSTRAINT background_jobs_partition_shape"
    )

    execute(
      "ALTER TABLE public.scheduled_jobs VALIDATE CONSTRAINT scheduled_jobs_partition_shape"
    )

    execute("""
    CREATE OR REPLACE FUNCTION public.runtime_coordination_acl_ready()
    RETURNS boolean
    LANGUAGE plpgsql
    STABLE
    SET search_path = pg_catalog, public
    AS $function$
    DECLARE
      relation_name text;
      function_name text;
    BEGIN
      IF NOT public.runtime_coordination_roles_ready() THEN
        RETURN false;
      END IF;

      IF NOT EXISTS (
        SELECT 1 FROM pg_catalog.pg_namespace AS namespace
        JOIN pg_catalog.pg_roles AS owner_role ON owner_role.oid = namespace.nspowner
        WHERE namespace.nspname = 'public'
          AND owner_role.rolname = 'maraithon_object_owner'
          AND NOT EXISTS (
            SELECT 1 FROM pg_catalog.aclexplode(COALESCE(
              namespace.nspacl, pg_catalog.acldefault('n', namespace.nspowner))) AS privilege
            WHERE privilege.grantee = 0
          )
      ) OR NOT (
        has_schema_privilege('maraithon_runtime', 'public', 'USAGE') AND
        has_schema_privilege('maraithon_payload_verifier', 'public', 'USAGE') AND
        has_schema_privilege('maraithon_incident_operator', 'public', 'USAGE') AND
        has_schema_privilege('maraithon_activation_operator', 'public', 'USAGE')
      ) THEN
        RETURN false;
      END IF;

      FOREACH relation_name IN ARRAY ARRAY[
        'runtime_coordination_protocols', 'runtime_coordination_manifests',
        'runtime_node_incarnations', 'runtime_leader_authorities', 'runtime_partitions',
        'runtime_partition_transitions', 'runtime_task_assignments',
        'runtime_task_outcome_evidence', 'runtime_task_termination_proofs',
        'runtime_tenant_fairness', 'runtime_partition_rebalance_requests',
        'effect_execution_protocols', 'effect_execution_protocol_manifests',
        'effect_termination_attestations', 'effects', 'agent_runtime_leases',
        'agent_directives', 'agent_runs', 'agent_run_steps', 'background_jobs',
        'scheduled_jobs', 'agent_termination_incidents', 'agent_termination_proofs',
        'schema_migrations'
      ] LOOP
        IF NOT EXISTS (
          SELECT 1 FROM pg_catalog.pg_class AS relation
          JOIN pg_catalog.pg_namespace AS namespace ON namespace.oid = relation.relnamespace
          JOIN pg_catalog.pg_roles AS owner_role ON owner_role.oid = relation.relowner
          WHERE namespace.nspname = 'public' AND relation.relname = relation_name
            AND owner_role.rolname = 'maraithon_object_owner'
        ) THEN
          RETURN false;
        END IF;
      END LOOP;

      FOREACH function_name IN ARRAY ARRAY[
        'runtime_partition_for(text)', 'runtime_coordination_roles_ready()',
        'runtime_role_topology_fingerprint()', 'runtime_coordination_acl_ready()',
        'runtime_catalog_table_fingerprint(regclass)',
        'populate_runtime_work_partition()', 'enforce_effect_activation_evidence()',
        'enforce_runtime_coordination_protocol()',
        'reject_runtime_coordination_evidence_mutation()',
        'enforce_runtime_partition_transition()', 'enforce_runtime_node_incarnation()',
        'enforce_runtime_leader_authority()', 'enforce_runtime_partition_authority()',
        'enforce_runtime_task_assignment()', 'enforce_runtime_task_outcome_evidence()',
        'enforce_runtime_task_termination_proof()',
        'runtime_task_authority_valid(uuid,uuid,smallint,bigint,uuid,uuid)',
        'enforce_runtime_work_role()',
        'enforce_coordinated_background_job()', 'enforce_coordinated_scheduled_job()',
        'enforce_coordinated_agent_directive()', 'enforce_coordinated_agent_lease()',
        'enforce_coordinated_effect()', 'enforce_effect_assignment_final_pair()',
        'enforce_agent_termination_incident()',
        'enforce_agent_termination_proof()',
        'enforce_agent_termination_partition_release()',
        'runtime_coordination_catalog_ready_count()'
      ] LOOP
        IF NOT EXISTS (
          SELECT 1 FROM pg_catalog.pg_proc AS procedure
          JOIN pg_catalog.pg_roles AS owner_role ON owner_role.oid = procedure.proowner
          WHERE procedure.oid = ('public.' || function_name)::regprocedure
            AND owner_role.rolname = 'maraithon_object_owner'
        ) OR EXISTS (
          SELECT 1
          FROM pg_catalog.aclexplode(COALESCE(
            (SELECT procedure.proacl FROM pg_catalog.pg_proc AS procedure
             WHERE procedure.oid = ('public.' || function_name)::regprocedure),
            pg_catalog.acldefault('f',
              (SELECT procedure.proowner FROM pg_catalog.pg_proc AS procedure
               WHERE procedure.oid = ('public.' || function_name)::regprocedure))
          )) AS privilege
          WHERE privilege.grantee = 0
        ) THEN
          RETURN false;
        END IF;
      END LOOP;

      -- PUBLIC receives no authority over the durable coordination ledger.
      IF EXISTS (
        SELECT 1
        FROM pg_catalog.pg_class AS relation
        JOIN pg_catalog.pg_namespace AS namespace ON namespace.oid = relation.relnamespace
        CROSS JOIN LATERAL pg_catalog.aclexplode(
          COALESCE(relation.relacl, pg_catalog.acldefault('r', relation.relowner))) AS privilege
        WHERE namespace.nspname = 'public'
          AND relation.relname = ANY(ARRAY[
            'runtime_coordination_protocols', 'runtime_coordination_manifests',
            'runtime_node_incarnations', 'runtime_leader_authorities', 'runtime_partitions',
            'runtime_partition_transitions', 'runtime_task_assignments',
            'runtime_task_outcome_evidence', 'runtime_task_termination_proofs',
            'runtime_tenant_fairness', 'runtime_partition_rebalance_requests',
            'effect_execution_protocols', 'effect_execution_protocol_manifests',
            'effect_termination_attestations', 'effects', 'agent_runtime_leases',
            'agent_directives', 'agent_runs', 'agent_run_steps', 'background_jobs',
            'scheduled_jobs', 'agent_termination_incidents', 'agent_termination_proofs',
            'schema_migrations'
          ]) AND privilege.grantee = 0
      ) THEN
        RETURN false;
      END IF;

      -- All allowed privileges are relation-level and reviewed below. Any
      -- column-specific ACL can bypass a negative table privilege proof.
      IF EXISTS (
        SELECT 1
        FROM pg_catalog.pg_attribute AS attribute
        JOIN pg_catalog.pg_class AS relation ON relation.oid = attribute.attrelid
        JOIN pg_catalog.pg_namespace AS namespace ON namespace.oid = relation.relnamespace
        WHERE namespace.nspname = 'public' AND attribute.attnum > 0
          AND NOT attribute.attisdropped AND attribute.attacl IS NOT NULL
          AND relation.relname = ANY(ARRAY[
            'runtime_coordination_protocols', 'runtime_coordination_manifests',
            'runtime_node_incarnations', 'runtime_leader_authorities', 'runtime_partitions',
            'runtime_partition_transitions', 'runtime_task_assignments',
            'runtime_task_outcome_evidence', 'runtime_task_termination_proofs',
            'runtime_tenant_fairness', 'runtime_partition_rebalance_requests',
            'effect_execution_protocols', 'effect_execution_protocol_manifests',
            'effect_termination_attestations', 'effects', 'agent_runtime_leases',
            'agent_directives', 'agent_runs', 'agent_run_steps', 'background_jobs',
            'scheduled_jobs', 'agent_termination_incidents', 'agent_termination_proofs',
            'schema_migrations'
          ])
      ) THEN
        RETURN false;
      END IF;

      -- Runtime has only worker ledger access. Row triggers further restrict
      -- local proof/outcome inserts to the exact live task incarnation.
      IF NOT (
        (has_table_privilege('maraithon_runtime', 'public.runtime_coordination_protocols', 'SELECT') AND
          has_table_privilege('maraithon_runtime', 'public.runtime_coordination_protocols', 'UPDATE')) AND
        has_table_privilege('maraithon_runtime', 'public.runtime_coordination_manifests', 'SELECT') AND
        (has_table_privilege('maraithon_runtime', 'public.runtime_node_incarnations', 'SELECT') AND
          has_table_privilege('maraithon_runtime', 'public.runtime_node_incarnations', 'INSERT') AND
          has_table_privilege('maraithon_runtime', 'public.runtime_node_incarnations', 'UPDATE')) AND
        (has_table_privilege('maraithon_runtime', 'public.runtime_leader_authorities', 'SELECT') AND
          has_table_privilege('maraithon_runtime', 'public.runtime_leader_authorities', 'UPDATE')) AND
        (has_table_privilege('maraithon_runtime', 'public.runtime_partitions', 'SELECT') AND
          has_table_privilege('maraithon_runtime', 'public.runtime_partitions', 'UPDATE')) AND
        (has_table_privilege('maraithon_runtime', 'public.runtime_partition_transitions', 'SELECT') AND
          has_table_privilege('maraithon_runtime', 'public.runtime_partition_transitions', 'INSERT') AND
          has_table_privilege('maraithon_runtime', 'public.runtime_partition_transitions', 'UPDATE')) AND
        (has_table_privilege('maraithon_runtime', 'public.runtime_task_assignments', 'SELECT') AND
          has_table_privilege('maraithon_runtime', 'public.runtime_task_assignments', 'INSERT') AND
          has_table_privilege('maraithon_runtime', 'public.runtime_task_assignments', 'UPDATE')) AND
        (has_table_privilege('maraithon_runtime', 'public.runtime_task_outcome_evidence', 'SELECT') AND
          has_table_privilege('maraithon_runtime', 'public.runtime_task_outcome_evidence', 'INSERT')) AND
        (has_table_privilege('maraithon_runtime', 'public.runtime_task_termination_proofs', 'SELECT') AND
          has_table_privilege('maraithon_runtime', 'public.runtime_task_termination_proofs', 'INSERT')) AND
        (has_table_privilege('maraithon_runtime', 'public.runtime_tenant_fairness', 'SELECT') AND
          has_table_privilege('maraithon_runtime', 'public.runtime_tenant_fairness', 'INSERT') AND
          has_table_privilege('maraithon_runtime', 'public.runtime_tenant_fairness', 'UPDATE')) AND
        (has_table_privilege('maraithon_runtime', 'public.runtime_partition_rebalance_requests', 'SELECT') AND
          has_table_privilege('maraithon_runtime', 'public.runtime_partition_rebalance_requests', 'INSERT') AND
          has_table_privilege('maraithon_runtime', 'public.runtime_partition_rebalance_requests', 'UPDATE')) AND
        (has_table_privilege('maraithon_runtime', 'public.effect_execution_protocols', 'SELECT') AND
          has_table_privilege('maraithon_runtime', 'public.effect_execution_protocols', 'UPDATE')) AND
        has_table_privilege('maraithon_runtime', 'public.effect_termination_attestations', 'SELECT') AND
        (has_table_privilege('maraithon_runtime', 'public.agent_termination_incidents', 'SELECT') AND
          has_table_privilege('maraithon_runtime', 'public.agent_termination_incidents', 'INSERT') AND
          has_table_privilege('maraithon_runtime', 'public.agent_termination_incidents', 'UPDATE')) AND
        (has_table_privilege('maraithon_runtime', 'public.agent_termination_proofs', 'SELECT') AND
          has_table_privilege('maraithon_runtime', 'public.agent_termination_proofs', 'INSERT'))
      ) OR
        has_table_privilege('maraithon_runtime', 'public.runtime_coordination_protocols', 'INSERT') OR
        has_table_privilege('maraithon_runtime', 'public.runtime_coordination_protocols', 'DELETE') OR
        has_table_privilege('maraithon_runtime', 'public.runtime_coordination_protocols', 'TRUNCATE') OR
        has_table_privilege('maraithon_runtime', 'public.effect_execution_protocols', 'INSERT') OR
        has_table_privilege('maraithon_runtime', 'public.effect_execution_protocols', 'DELETE') OR
        has_table_privilege('maraithon_runtime', 'public.effect_execution_protocols', 'TRUNCATE') OR
        has_table_privilege('maraithon_runtime', 'public.runtime_coordination_manifests', 'INSERT') OR
        has_table_privilege('maraithon_runtime', 'public.runtime_coordination_manifests', 'UPDATE') OR
        has_table_privilege('maraithon_runtime', 'public.runtime_coordination_manifests', 'DELETE') OR
        has_table_privilege('maraithon_runtime', 'public.runtime_coordination_manifests', 'TRUNCATE') OR
        has_table_privilege('maraithon_runtime', 'public.runtime_task_outcome_evidence', 'UPDATE') OR
        has_table_privilege('maraithon_runtime', 'public.runtime_task_outcome_evidence', 'DELETE') OR
        has_table_privilege('maraithon_runtime', 'public.runtime_task_outcome_evidence', 'TRUNCATE') OR
        has_table_privilege('maraithon_runtime', 'public.runtime_task_termination_proofs', 'UPDATE') OR
        has_table_privilege('maraithon_runtime', 'public.runtime_task_termination_proofs', 'DELETE') OR
        has_table_privilege('maraithon_runtime', 'public.runtime_task_termination_proofs', 'TRUNCATE') OR
        has_table_privilege('maraithon_runtime', 'public.effect_termination_attestations', 'INSERT') OR
        has_table_privilege('maraithon_runtime', 'public.effect_termination_attestations', 'UPDATE') OR
        has_table_privilege('maraithon_runtime', 'public.effect_termination_attestations', 'DELETE') OR
        has_table_privilege('maraithon_runtime', 'public.effect_termination_attestations', 'TRUNCATE') OR
        has_table_privilege('maraithon_runtime', 'public.agent_termination_incidents', 'DELETE') OR
        has_table_privilege('maraithon_runtime', 'public.agent_termination_incidents', 'TRUNCATE') OR
        has_table_privilege('maraithon_runtime', 'public.agent_termination_proofs', 'UPDATE') OR
        has_table_privilege('maraithon_runtime', 'public.agent_termination_proofs', 'DELETE') OR
        has_table_privilege('maraithon_runtime', 'public.agent_termination_proofs', 'TRUNCATE') THEN
        RETURN false;
      END IF;

      IF NOT (
        (has_table_privilege('maraithon_incident_operator',
          'public.runtime_coordination_protocols', 'SELECT') AND
          has_table_privilege('maraithon_incident_operator',
            'public.runtime_coordination_protocols', 'UPDATE')) AND
        (has_table_privilege('maraithon_incident_operator',
          'public.runtime_node_incarnations', 'SELECT') AND
          has_table_privilege('maraithon_incident_operator',
            'public.runtime_node_incarnations', 'UPDATE')) AND
        (has_table_privilege('maraithon_incident_operator',
          'public.runtime_partitions', 'SELECT') AND
          has_table_privilege('maraithon_incident_operator',
            'public.runtime_partitions', 'UPDATE')) AND
        (has_table_privilege('maraithon_incident_operator', 'public.runtime_task_assignments', 'SELECT') AND
          has_table_privilege('maraithon_incident_operator', 'public.runtime_task_assignments', 'UPDATE')) AND
        (has_table_privilege('maraithon_incident_operator', 'public.runtime_task_termination_proofs', 'SELECT') AND
          has_table_privilege('maraithon_incident_operator', 'public.runtime_task_termination_proofs', 'INSERT')) AND
        (has_table_privilege('maraithon_incident_operator', 'public.effect_termination_attestations', 'SELECT') AND
          has_table_privilege('maraithon_incident_operator', 'public.effect_termination_attestations', 'INSERT')) AND
        has_table_privilege('maraithon_incident_operator', 'public.agent_runtime_leases', 'SELECT') AND
        (has_table_privilege('maraithon_incident_operator', 'public.agent_termination_incidents', 'SELECT') AND
          has_table_privilege('maraithon_incident_operator', 'public.agent_termination_incidents', 'UPDATE')) AND
        (has_table_privilege('maraithon_incident_operator', 'public.agent_termination_proofs', 'SELECT') AND
          has_table_privilege('maraithon_incident_operator', 'public.agent_termination_proofs', 'INSERT'))
      ) OR has_table_privilege('maraithon_incident_operator',
             'public.runtime_task_outcome_evidence', 'INSERT') OR
           has_table_privilege('maraithon_incident_operator',
             'public.runtime_task_outcome_evidence', 'UPDATE') OR
           has_table_privilege('maraithon_incident_operator',
             'public.runtime_task_outcome_evidence', 'DELETE') OR
           has_table_privilege('maraithon_incident_operator',
             'public.runtime_task_outcome_evidence', 'TRUNCATE') OR
           has_table_privilege('maraithon_incident_operator',
             'public.runtime_coordination_protocols', 'INSERT') OR
           has_table_privilege('maraithon_incident_operator',
             'public.runtime_coordination_protocols', 'DELETE') OR
           has_table_privilege('maraithon_incident_operator',
             'public.runtime_coordination_protocols', 'TRUNCATE') OR
           has_table_privilege('maraithon_incident_operator',
             'public.runtime_node_incarnations', 'INSERT') OR
           has_table_privilege('maraithon_incident_operator',
             'public.runtime_node_incarnations', 'DELETE') OR
           has_table_privilege('maraithon_incident_operator',
             'public.runtime_node_incarnations', 'TRUNCATE') OR
           has_table_privilege('maraithon_incident_operator',
             'public.runtime_partitions', 'INSERT') OR
           has_table_privilege('maraithon_incident_operator',
             'public.runtime_partitions', 'DELETE') OR
           has_table_privilege('maraithon_incident_operator',
             'public.runtime_partitions', 'TRUNCATE') OR
           has_table_privilege('maraithon_incident_operator',
             'public.effect_termination_attestations', 'UPDATE') OR
           has_table_privilege('maraithon_incident_operator',
             'public.effect_termination_attestations', 'DELETE') OR
           has_table_privilege('maraithon_incident_operator',
             'public.effect_termination_attestations', 'TRUNCATE') OR
           has_table_privilege('maraithon_incident_operator',
             'public.agent_runtime_leases', 'INSERT') OR
           has_table_privilege('maraithon_incident_operator',
             'public.agent_runtime_leases', 'UPDATE') OR
           has_table_privilege('maraithon_incident_operator',
             'public.agent_runtime_leases', 'DELETE') OR
           has_table_privilege('maraithon_incident_operator',
             'public.agent_runtime_leases', 'TRUNCATE') OR
           has_table_privilege('maraithon_incident_operator',
             'public.agent_termination_incidents', 'INSERT') OR
           has_table_privilege('maraithon_incident_operator',
             'public.agent_termination_incidents', 'DELETE') OR
           has_table_privilege('maraithon_incident_operator',
             'public.agent_termination_incidents', 'TRUNCATE') OR
           has_table_privilege('maraithon_incident_operator',
             'public.agent_termination_proofs', 'UPDATE') OR
           has_table_privilege('maraithon_incident_operator',
             'public.agent_termination_proofs', 'DELETE') OR
           has_table_privilege('maraithon_incident_operator',
             'public.agent_termination_proofs', 'TRUNCATE') THEN
        RETURN false;
      END IF;

      IF NOT (
        (has_table_privilege('maraithon_activation_operator', 'public.runtime_coordination_protocols', 'SELECT') AND
          has_table_privilege('maraithon_activation_operator', 'public.runtime_coordination_protocols', 'UPDATE')) AND
        has_table_privilege('maraithon_activation_operator',
          'public.runtime_coordination_manifests', 'SELECT') AND
        (has_table_privilege('maraithon_activation_operator', 'public.runtime_node_incarnations', 'SELECT') AND
          has_table_privilege('maraithon_activation_operator', 'public.runtime_node_incarnations', 'UPDATE')) AND
        (has_table_privilege('maraithon_activation_operator', 'public.runtime_task_assignments', 'SELECT') AND
          has_table_privilege('maraithon_activation_operator', 'public.runtime_task_assignments', 'UPDATE')) AND
        (has_table_privilege('maraithon_activation_operator', 'public.effect_execution_protocols', 'SELECT') AND
          has_table_privilege('maraithon_activation_operator', 'public.effect_execution_protocols', 'UPDATE')) AND
        has_table_privilege('maraithon_activation_operator',
          'public.schema_migrations', 'SELECT') AND
        has_table_privilege('maraithon_runtime',
          'public.schema_migrations', 'SELECT') AND
        has_table_privilege('maraithon_runtime',
          'public.effect_execution_protocol_manifests', 'SELECT')
      ) OR has_table_privilege('maraithon_activation_operator',
             'public.runtime_task_assignments', 'INSERT') OR
           has_table_privilege('maraithon_activation_operator',
             'public.runtime_task_assignments', 'DELETE') OR
           has_table_privilege('maraithon_activation_operator',
             'public.runtime_task_assignments', 'TRUNCATE') OR
           has_table_privilege('maraithon_activation_operator',
             'public.runtime_task_termination_proofs', 'INSERT') OR
           has_table_privilege('maraithon_activation_operator',
             'public.runtime_task_termination_proofs', 'UPDATE') OR
           has_table_privilege('maraithon_activation_operator',
             'public.runtime_task_termination_proofs', 'DELETE') OR
           has_table_privilege('maraithon_activation_operator',
             'public.runtime_task_termination_proofs', 'TRUNCATE') OR
           has_table_privilege('maraithon_activation_operator',
             'public.agent_termination_incidents', 'SELECT') OR
           has_table_privilege('maraithon_activation_operator',
             'public.agent_termination_incidents', 'INSERT') OR
           has_table_privilege('maraithon_activation_operator',
             'public.agent_termination_incidents', 'UPDATE') OR
           has_table_privilege('maraithon_activation_operator',
             'public.agent_termination_incidents', 'DELETE') OR
           has_table_privilege('maraithon_activation_operator',
             'public.agent_termination_incidents', 'TRUNCATE') OR
           has_table_privilege('maraithon_activation_operator',
             'public.agent_termination_proofs', 'SELECT') OR
           has_table_privilege('maraithon_activation_operator',
             'public.agent_termination_proofs', 'INSERT') OR
           has_table_privilege('maraithon_activation_operator',
             'public.agent_termination_proofs', 'UPDATE') OR
           has_table_privilege('maraithon_activation_operator',
             'public.agent_termination_proofs', 'DELETE') OR
           has_table_privilege('maraithon_activation_operator',
             'public.agent_termination_proofs', 'TRUNCATE') THEN
        RETURN false;
      END IF;

      IF NOT (
        has_table_privilege('maraithon_payload_verifier',
          'public.runtime_coordination_protocols', 'SELECT') AND
        has_table_privilege('maraithon_payload_verifier',
          'public.runtime_coordination_manifests', 'SELECT') AND
        has_table_privilege('maraithon_payload_verifier',
          'public.runtime_task_assignments', 'SELECT') AND
        has_table_privilege('maraithon_payload_verifier',
          'public.runtime_task_outcome_evidence', 'SELECT') AND
        has_table_privilege('maraithon_payload_verifier',
          'public.runtime_task_termination_proofs', 'SELECT')
      ) OR has_table_privilege('maraithon_payload_verifier',
             'public.runtime_task_outcome_evidence', 'INSERT') OR
           has_table_privilege('maraithon_payload_verifier',
             'public.runtime_task_outcome_evidence', 'UPDATE') OR
           has_table_privilege('maraithon_payload_verifier',
             'public.runtime_task_outcome_evidence', 'DELETE') OR
           has_table_privilege('maraithon_payload_verifier',
             'public.runtime_task_outcome_evidence', 'TRUNCATE') OR
           has_table_privilege('maraithon_payload_verifier',
             'public.runtime_task_termination_proofs', 'INSERT') OR
           has_table_privilege('maraithon_payload_verifier',
             'public.runtime_task_termination_proofs', 'UPDATE') OR
           has_table_privilege('maraithon_payload_verifier',
             'public.runtime_task_termination_proofs', 'DELETE') OR
           has_table_privilege('maraithon_payload_verifier',
             'public.runtime_task_termination_proofs', 'TRUNCATE') OR
           has_table_privilege('maraithon_payload_verifier',
             'public.agent_termination_incidents', 'SELECT') OR
           has_table_privilege('maraithon_payload_verifier',
             'public.agent_termination_incidents', 'INSERT') OR
           has_table_privilege('maraithon_payload_verifier',
             'public.agent_termination_incidents', 'UPDATE') OR
           has_table_privilege('maraithon_payload_verifier',
             'public.agent_termination_incidents', 'DELETE') OR
           has_table_privilege('maraithon_payload_verifier',
             'public.agent_termination_incidents', 'TRUNCATE') OR
           has_table_privilege('maraithon_payload_verifier',
             'public.agent_termination_proofs', 'SELECT') OR
           has_table_privilege('maraithon_payload_verifier',
             'public.agent_termination_proofs', 'INSERT') OR
           has_table_privilege('maraithon_payload_verifier',
             'public.agent_termination_proofs', 'UPDATE') OR
           has_table_privilege('maraithon_payload_verifier',
             'public.agent_termination_proofs', 'DELETE') OR
           has_table_privilege('maraithon_payload_verifier',
             'public.agent_termination_proofs', 'TRUNCATE') THEN
        RETURN false;
      END IF;

      RETURN true;
    END;
    $function$;
    """)

    execute("""
    CREATE OR REPLACE FUNCTION public.enforce_effect_activation_evidence()
    RETURNS trigger
    LANGUAGE plpgsql
    SET search_path = pg_catalog, public
    AS $function$
    BEGIN
      IF (NEW.activation_evidence_id IS DISTINCT FROM OLD.activation_evidence_id OR
          NEW.activation_evidence_digest IS DISTINCT FROM OLD.activation_evidence_digest OR
          NEW.activated_by IS DISTINCT FROM OLD.activated_by OR
          NEW.exact_revision IS DISTINCT FROM OLD.exact_revision) AND
         current_user IS DISTINCT FROM 'maraithon_activation_operator' THEN
        RAISE EXCEPTION 'Effect activation evidence requires activation operator role'
          USING ERRCODE = 'insufficient_privilege';
      END IF;
      IF OLD.activation_evidence_digest IS NOT NULL AND (
        NEW.activation_evidence_id IS DISTINCT FROM OLD.activation_evidence_id OR
        NEW.activation_evidence_digest IS DISTINCT FROM OLD.activation_evidence_digest OR
        NEW.activated_by IS DISTINCT FROM OLD.activated_by OR
        NEW.exact_revision IS DISTINCT FROM OLD.exact_revision
      ) THEN
        RAISE EXCEPTION 'Effect activation evidence is immutable'
          USING ERRCODE = 'check_violation';
      END IF;
      IF OLD.activation_evidence_digest IS NULL AND NEW.activation_evidence_digest IS NOT NULL AND
         current_setting('maraithon.effect_activation_evidence', true)
           IS DISTINCT FROM 'ATTEST_STOPPED_FLEET_EVIDENCE' THEN
        RAISE EXCEPTION 'Effect activation evidence requires operator attestation'
          USING ERRCODE = 'check_violation';
      END IF;
      RETURN NEW;
    END;
    $function$;
    """)

    execute(
      "DROP TRIGGER IF EXISTS enforce_effect_activation_evidence_trigger ON public.effect_execution_protocols"
    )

    execute("""
    CREATE TRIGGER enforce_effect_activation_evidence_trigger
      BEFORE UPDATE ON public.effect_execution_protocols
      FOR EACH ROW EXECUTE FUNCTION public.enforce_effect_activation_evidence()
    """)

    execute("""
    CREATE OR REPLACE FUNCTION public.enforce_runtime_coordination_protocol()
    RETURNS trigger
    LANGUAGE plpgsql
    SET search_path = pg_catalog, public
    AS $function$
    DECLARE
      effect_evidence_id text;
      effect_evidence_digest bytea;
      effect_activated_by text;
      effect_exact_revision text;
    BEGIN
      IF TG_OP IN ('UPDATE', 'DELETE') AND
         current_user IS DISTINCT FROM 'maraithon_activation_operator' THEN
        RAISE EXCEPTION 'runtime coordination protocol requires activation operator role'
          USING ERRCODE = 'insufficient_privilege';
      END IF;
      IF TG_OP IN ('DELETE', 'TRUNCATE') THEN
        RAISE EXCEPTION 'runtime coordination protocol is irreversible'
          USING ERRCODE = 'check_violation';
      END IF;

      IF TG_OP = 'INSERT' AND NEW.name <> 'runtime' THEN
        RAISE EXCEPTION 'invalid runtime coordination singleton'
          USING ERRCODE = 'check_violation';
      END IF;

      IF TG_OP = 'UPDATE' THEN
        IF NEW.name IS DISTINCT FROM OLD.name OR
           NEW.partition_count IS DISTINCT FROM OLD.partition_count OR
           NEW.manifest_digest IS DISTINCT FROM OLD.manifest_digest OR
           (OLD.mode = 'partition_fenced_v1' AND
            (NEW.mode IS DISTINCT FROM OLD.mode OR
             NEW.activation_epoch IS DISTINCT FROM OLD.activation_epoch OR
             NEW.activated_at IS DISTINCT FROM OLD.activated_at OR
             NEW.activation_evidence_id IS DISTINCT FROM OLD.activation_evidence_id OR
             NEW.activation_evidence_digest IS DISTINCT FROM OLD.activation_evidence_digest OR
             NEW.activated_by IS DISTINCT FROM OLD.activated_by OR
             NEW.exact_revision IS DISTINCT FROM OLD.exact_revision)) THEN
          RAISE EXCEPTION 'runtime coordination authority is immutable'
            USING ERRCODE = 'check_violation';
        END IF;

        IF OLD.mode = 'dark' AND NEW.mode = 'partition_fenced_v1' THEN
          IF current_setting('maraithon.runtime_coordination_activation', true)
               IS DISTINCT FROM 'ACTIVATE_PARTITION_FENCED_V1' THEN
            RAISE EXCEPTION 'runtime coordination activation requires stopped-fleet confirmation'
              USING ERRCODE = 'check_violation';
          END IF;
          IF NEW.activation_epoch IS NULL OR NEW.activation_evidence_id IS NULL OR
             NEW.activation_evidence_digest IS NULL OR NEW.activated_by IS NULL OR
             NEW.exact_revision IS NULL THEN
            RAISE EXCEPTION 'runtime coordination activation identity and evidence are required'
              USING ERRCODE = 'check_violation';
          END IF;

          -- The trigger repeats the full cutover proof. An application
          -- preflight or custom GUC is never activation authority by itself.
          -- Consistent lock order after the already-locked coordination row:
          -- Effect protocol, then durable work roots, then coordination roots.
          SELECT activation_evidence_id, activation_evidence_digest, activated_by,
                 exact_revision
          INTO effect_evidence_id, effect_evidence_digest, effect_activated_by,
               effect_exact_revision
          FROM public.effect_execution_protocols
          WHERE name = 'effects' AND mode = 'generation_fenced_v1'
          FOR SHARE;
          IF NOT FOUND OR effect_evidence_digest IS NULL OR
             effect_evidence_id IS DISTINCT FROM NEW.activation_evidence_id OR
             effect_evidence_digest IS DISTINCT FROM NEW.activation_evidence_digest OR
             effect_activated_by IS DISTINCT FROM NEW.activated_by OR
             effect_exact_revision IS DISTINCT FROM NEW.exact_revision THEN
            RAISE EXCEPTION 'coordination evidence must match exact Effect stopped-fleet evidence'
              USING ERRCODE = 'check_violation';
          END IF;

          LOCK TABLE public.effects IN SHARE MODE;
          LOCK TABLE public.agent_runtime_leases IN SHARE MODE;
          LOCK TABLE public.agent_directives IN SHARE MODE;
          LOCK TABLE public.agent_runs IN SHARE MODE;
          LOCK TABLE public.agent_run_steps IN SHARE MODE;
          LOCK TABLE public.background_jobs IN SHARE MODE;
          LOCK TABLE public.scheduled_jobs IN SHARE MODE;
          LOCK TABLE public.runtime_node_incarnations IN SHARE MODE;
          LOCK TABLE public.runtime_task_assignments IN SHARE MODE;

          IF (SELECT count(*) FROM public.schema_migrations
              WHERE version = 20260810140004) <> 1 OR
             public.runtime_coordination_catalog_ready_count() <> 114 OR
             NOT public.runtime_coordination_roles_ready() OR
             NOT public.runtime_coordination_acl_ready() OR
             NEW.manifest_digest IS DISTINCT FROM (
               SELECT public.digest(convert_to(pg_catalog.jsonb_build_object(
                 'constraints', manifest.constraint_fingerprints,
                 'functions', manifest.function_fingerprints,
                 'triggers', manifest.trigger_fingerprints,
                 'indexes', manifest.index_fingerprints,
                 'catalogs', manifest.catalog_fingerprints
               )::text, 'UTF8'), 'sha256')
               FROM public.runtime_coordination_manifests AS manifest
               WHERE manifest.name = 'runtime'
             ) THEN
            RAISE EXCEPTION 'runtime coordination catalog attestation failed'
              USING ERRCODE = 'check_violation';
          END IF;

          IF EXISTS (SELECT 1 FROM public.background_jobs
                     WHERE tenant_key IS NULL OR partition_id IS NULL) OR
             EXISTS (SELECT 1 FROM public.scheduled_jobs
                     WHERE tenant_key IS NULL OR partition_id IS NULL) THEN
            RAISE EXCEPTION 'bounded runtime partition backfill is incomplete'
              USING ERRCODE = 'check_violation';
          END IF;

          IF EXISTS (SELECT 1 FROM public.agent_runtime_leases) OR
             EXISTS (SELECT 1 FROM public.agent_directives WHERE status = 'processing') OR
             EXISTS (SELECT 1 FROM public.agent_runs WHERE status = 'running') OR
             EXISTS (SELECT 1 FROM public.agent_run_steps WHERE status = 'requested') OR
             EXISTS (SELECT 1 FROM public.effects
                     WHERE status IN ('pending', 'claimed', 'cancelling')) OR
             EXISTS (SELECT 1 FROM public.background_jobs WHERE status = 'running') OR
             EXISTS (SELECT 1 FROM public.scheduled_jobs WHERE status = 'dispatched') OR
             EXISTS (SELECT 1 FROM public.runtime_node_incarnations WHERE state <> 'revoked') OR
             EXISTS (SELECT 1 FROM public.runtime_task_assignments
                     WHERE state IN ('reserved', 'running', 'termination_requested',
                                     'termination_proven')) THEN
            RAISE EXCEPTION 'runtime coordination activation requires a quiescent stopped fleet'
              USING ERRCODE = 'check_violation';
          END IF;

          NEW.activated_at := timezone('UTC', clock_timestamp());
        ELSIF NEW.mode IS DISTINCT FROM OLD.mode OR
              NEW.activation_epoch IS DISTINCT FROM OLD.activation_epoch OR
              NEW.activated_at IS DISTINCT FROM OLD.activated_at THEN
          RAISE EXCEPTION 'invalid runtime coordination protocol transition'
            USING ERRCODE = 'check_violation';
        END IF;
      END IF;
      RETURN NEW;
    END;
    $function$;
    """)

    execute(
      "DROP TRIGGER IF EXISTS enforce_runtime_coordination_protocol_trigger ON public.runtime_coordination_protocols"
    )

    execute("""
    CREATE TRIGGER enforce_runtime_coordination_protocol_trigger
      BEFORE INSERT OR UPDATE OR DELETE ON public.runtime_coordination_protocols
      FOR EACH ROW EXECUTE FUNCTION public.enforce_runtime_coordination_protocol()
    """)

    execute(
      "DROP TRIGGER IF EXISTS reject_runtime_coordination_protocol_truncate_trigger ON public.runtime_coordination_protocols"
    )

    execute("""
    CREATE TRIGGER reject_runtime_coordination_protocol_truncate_trigger
      BEFORE TRUNCATE ON public.runtime_coordination_protocols
      FOR EACH STATEMENT EXECUTE FUNCTION public.enforce_runtime_coordination_protocol()
    """)

    execute("""
    CREATE OR REPLACE FUNCTION public.reject_runtime_coordination_evidence_mutation()
    RETURNS trigger
    LANGUAGE plpgsql
    SET search_path = pg_catalog, public
    AS $function$
    BEGIN
      RAISE EXCEPTION 'runtime coordination evidence is append-only'
        USING ERRCODE = 'check_violation';
    END;
    $function$;
    """)

    for table <- [
          "runtime_coordination_manifests",
          "runtime_task_termination_proofs"
        ] do
      execute("DROP TRIGGER IF EXISTS reject_#{table}_mutation_trigger ON public.#{table}")

      execute("""
      CREATE TRIGGER reject_#{table}_mutation_trigger
        BEFORE UPDATE OR DELETE ON public.#{table}
        FOR EACH ROW EXECUTE FUNCTION public.reject_runtime_coordination_evidence_mutation()
      """)

      execute("DROP TRIGGER IF EXISTS reject_#{table}_truncate_trigger ON public.#{table}")

      execute("""
      CREATE TRIGGER reject_#{table}_truncate_trigger
        BEFORE TRUNCATE ON public.#{table}
        FOR EACH STATEMENT EXECUTE FUNCTION public.reject_runtime_coordination_evidence_mutation()
      """)
    end

    execute("""
    CREATE OR REPLACE FUNCTION public.enforce_runtime_partition_transition()
    RETURNS trigger
    LANGUAGE plpgsql
    SET search_path = pg_catalog, public
    AS $function$
    BEGIN
      IF current_user IS DISTINCT FROM 'maraithon_runtime' THEN
        RAISE EXCEPTION 'runtime coordination mutation requires executor role'
          USING ERRCODE = 'insufficient_privilege';
      END IF;
      IF TG_OP = 'DELETE' THEN
        RAISE EXCEPTION 'runtime partition transition history is irreversible'
          USING ERRCODE = 'check_violation';
      END IF;
      IF NEW.id IS DISTINCT FROM OLD.id OR
         NEW.activation_epoch IS DISTINCT FROM OLD.activation_epoch OR
         NEW.partition_id IS DISTINCT FROM OLD.partition_id OR
         NEW.partition_epoch IS DISTINCT FROM OLD.partition_epoch OR
         NEW.from_node_incarnation_id IS DISTINCT FROM OLD.from_node_incarnation_id OR
         NEW.to_node_incarnation_id IS DISTINCT FROM OLD.to_node_incarnation_id OR
         NEW.kind IS DISTINCT FROM OLD.kind OR
         NEW.leader_node_incarnation_id IS DISTINCT FROM OLD.leader_node_incarnation_id OR
         NEW.leader_epoch IS DISTINCT FROM OLD.leader_epoch OR
         NEW.leader_action_token IS DISTINCT FROM OLD.leader_action_token OR
         NEW.requested_at IS DISTINCT FROM OLD.requested_at OR
         (OLD.state = 'preparing' AND NEW.state NOT IN ('preparing', 'ready', 'draining', 'blocked')) OR
         (OLD.state = 'ready' AND NEW.state NOT IN ('ready', 'draining', 'blocked')) OR
         (OLD.state = 'draining' AND NEW.state NOT IN ('draining', 'blocked', 'completed')) OR
         (OLD.state = 'blocked' AND NEW.state NOT IN ('blocked', 'completed')) OR
         (OLD.state = 'completed' AND NEW IS DISTINCT FROM OLD) THEN
        RAISE EXCEPTION 'runtime partition transition is stale or non-monotone'
          USING ERRCODE = 'check_violation';
      END IF;
      RETURN NEW;
    END;
    $function$;
    """)

    execute(
      "DROP TRIGGER IF EXISTS enforce_runtime_partition_transition_trigger ON public.runtime_partition_transitions"
    )

    execute("""
    CREATE TRIGGER enforce_runtime_partition_transition_trigger
      BEFORE UPDATE OR DELETE ON public.runtime_partition_transitions
      FOR EACH ROW EXECUTE FUNCTION public.enforce_runtime_partition_transition()
    """)

    execute(
      "DROP TRIGGER IF EXISTS reject_runtime_partition_transitions_truncate_trigger ON public.runtime_partition_transitions"
    )

    execute("""
    CREATE TRIGGER reject_runtime_partition_transitions_truncate_trigger
      BEFORE TRUNCATE ON public.runtime_partition_transitions
      FOR EACH STATEMENT EXECUTE FUNCTION public.reject_runtime_coordination_evidence_mutation()
    """)

    execute("""
    CREATE OR REPLACE FUNCTION public.enforce_runtime_node_incarnation()
    RETURNS trigger
    LANGUAGE plpgsql
    SET search_path = pg_catalog, public
    AS $function$
    DECLARE
      requested_id uuid;
      leader_authorized boolean;
      unresolved_tasks bigint;
      live_leases bigint;
    BEGIN
      IF current_user IS DISTINCT FROM 'maraithon_runtime' THEN
        RAISE EXCEPTION 'runtime coordination mutation requires executor role'
          USING ERRCODE = 'insufficient_privilege';
      END IF;
      IF TG_OP = 'DELETE' THEN
        RAISE EXCEPTION 'runtime node incarnation history is immutable'
          USING ERRCODE = 'check_violation';
      END IF;

      BEGIN
        requested_id := nullif(current_setting('maraithon.runtime_node_action', true), '')::uuid;
      EXCEPTION WHEN invalid_text_representation THEN
        requested_id := NULL;
      END;

      SELECT EXISTS (
        SELECT 1 FROM public.runtime_leader_authorities AS leader
        WHERE leader.role = 'partition_planner' AND leader.state = 'ready'
          AND leader.action_token::text =
                current_setting('maraithon.runtime_leader_action', true)
          AND leader.lease_expires_at > timezone('UTC', clock_timestamp())
      ) INTO leader_authorized;

      IF requested_id IS DISTINCT FROM NEW.id AND NOT leader_authorized THEN
        RAISE EXCEPTION 'runtime node mutation requires its exact incarnation token'
          USING ERRCODE = 'check_violation';
      END IF;

      IF TG_OP = 'INSERT' THEN
        IF NOT EXISTS (
          SELECT 1 FROM public.runtime_coordination_protocols AS protocol
          WHERE protocol.name = 'runtime' AND protocol.mode = 'partition_fenced_v1'
            AND protocol.activation_epoch = NEW.activation_epoch
            AND protocol.exact_revision = NEW.revision
        ) THEN
          RAISE EXCEPTION 'runtime node cannot join an inactive protocol'
            USING ERRCODE = 'check_violation';
        END IF;
      ELSE
        IF NEW.id IS DISTINCT FROM OLD.id OR
           NEW.activation_epoch IS DISTINCT FROM OLD.activation_epoch OR
           NEW.node_name IS DISTINCT FROM OLD.node_name OR
           NEW.revision IS DISTINCT FROM OLD.revision OR
           NEW.metadata IS DISTINCT FROM OLD.metadata OR
           NEW.lease_expires_at < OLD.lease_expires_at OR
           (OLD.state = 'revoked' AND NEW IS DISTINCT FROM OLD) OR
           (OLD.state = 'draining' AND NEW.state NOT IN ('draining', 'revoked')) OR
           (OLD.state = 'ready' AND NEW.state NOT IN ('ready', 'draining', 'revoked')) OR
           (OLD.state = 'joining' AND NEW.state NOT IN ('joining', 'ready', 'draining', 'revoked')) THEN
          RAISE EXCEPTION 'stale or non-monotone runtime node incarnation mutation'
            USING ERRCODE = 'check_violation';
        END IF;
        IF OLD.lease_expires_at <= timezone('UTC', clock_timestamp()) AND
           NEW.lease_expires_at > OLD.lease_expires_at THEN
          RAISE EXCEPTION 'expired runtime node incarnation cannot be revived'
            USING ERRCODE = 'check_violation';
        END IF;
        IF NEW.state = 'revoked' AND OLD.state <> 'revoked' THEN
          SELECT count(*) INTO unresolved_tasks
          FROM public.runtime_task_assignments
          WHERE node_incarnation_id = OLD.id
            AND state IN ('reserved', 'running', 'termination_requested', 'termination_proven');
          SELECT count(*) INTO live_leases
          FROM public.agent_runtime_leases
          WHERE coordination_node_incarnation_id = OLD.id
            AND lease_until > timezone('UTC', clock_timestamp());
          IF unresolved_tasks <> 0 OR live_leases <> 0 THEN
            RAISE EXCEPTION 'node revocation requires exact task proof and Agent lease drain'
              USING ERRCODE = 'check_violation';
          END IF;
        END IF;
      END IF;
      RETURN NEW;
    END;
    $function$;
    """)

    execute(
      "DROP TRIGGER IF EXISTS enforce_runtime_node_incarnation_trigger ON public.runtime_node_incarnations"
    )

    execute("""
    CREATE TRIGGER enforce_runtime_node_incarnation_trigger
      BEFORE INSERT OR UPDATE OR DELETE ON public.runtime_node_incarnations
      FOR EACH ROW EXECUTE FUNCTION public.enforce_runtime_node_incarnation()
    """)

    execute("""
    CREATE OR REPLACE FUNCTION public.enforce_runtime_leader_authority()
    RETURNS trigger
    LANGUAGE plpgsql
    SET search_path = pg_catalog, public
    AS $function$
    DECLARE node_valid boolean;
    BEGIN
      IF current_user IS DISTINCT FROM 'maraithon_runtime' THEN
        RAISE EXCEPTION 'runtime coordination mutation requires executor role'
          USING ERRCODE = 'insufficient_privilege';
      END IF;
      IF TG_OP = 'DELETE' THEN
        RAISE EXCEPTION 'runtime leader authority is irreversible'
          USING ERRCODE = 'check_violation';
      END IF;
      IF NEW.role IS DISTINCT FROM OLD.role OR NEW.leader_epoch < OLD.leader_epoch THEN
        RAISE EXCEPTION 'runtime leader epoch is monotone'
          USING ERRCODE = 'check_violation';
      END IF;
      IF NEW.state <> 'unassigned' THEN
        IF current_setting('maraithon.runtime_leader_action', true)
             IS DISTINCT FROM NEW.action_token::text THEN
          RAISE EXCEPTION 'runtime leader action token is required'
            USING ERRCODE = 'check_violation';
        END IF;
        SELECT EXISTS (
          SELECT 1 FROM public.runtime_node_incarnations AS node
          WHERE node.id = NEW.node_incarnation_id
            AND node.activation_epoch = NEW.activation_epoch
            AND node.state = 'ready' AND node.ready_at IS NOT NULL
            AND node.lease_expires_at > timezone('UTC', clock_timestamp())
        ) INTO node_valid;
        IF NOT node_valid THEN
          RAISE EXCEPTION 'runtime leader requires a ready node incarnation'
            USING ERRCODE = 'check_violation';
        END IF;
      END IF;
      IF OLD.state = 'ready' AND OLD.lease_expires_at <= timezone('UTC', clock_timestamp()) AND
         NEW.node_incarnation_id = OLD.node_incarnation_id THEN
        RAISE EXCEPTION 'expired leader incarnation cannot be revived'
          USING ERRCODE = 'check_violation';
      END IF;
      IF NEW.node_incarnation_id IS DISTINCT FROM OLD.node_incarnation_id AND
         NEW.leader_epoch <> OLD.leader_epoch + 1 THEN
        RAISE EXCEPTION 'leader takeover must advance its epoch exactly once'
          USING ERRCODE = 'check_violation';
      END IF;
      RETURN NEW;
    END;
    $function$;
    """)

    execute(
      "DROP TRIGGER IF EXISTS enforce_runtime_leader_authority_trigger ON public.runtime_leader_authorities"
    )

    execute("""
    CREATE TRIGGER enforce_runtime_leader_authority_trigger
      BEFORE UPDATE OR DELETE ON public.runtime_leader_authorities
      FOR EACH ROW EXECUTE FUNCTION public.enforce_runtime_leader_authority()
    """)

    execute("""
    CREATE OR REPLACE FUNCTION public.enforce_runtime_partition_authority()
    RETURNS trigger
    LANGUAGE plpgsql
    SET search_path = pg_catalog, public
    AS $function$
    DECLARE
      leader_valid boolean;
      node_valid boolean;
      unresolved_tasks bigint;
      live_agents bigint;
    BEGIN
      IF current_user IS DISTINCT FROM 'maraithon_runtime' THEN
        RAISE EXCEPTION 'runtime coordination mutation requires executor role'
          USING ERRCODE = 'insufficient_privilege';
      END IF;
      IF TG_OP = 'DELETE' THEN
        RAISE EXCEPTION 'runtime partition authority is irreversible'
          USING ERRCODE = 'check_violation';
      END IF;
      IF NEW.partition_id IS DISTINCT FROM OLD.partition_id OR
         NEW.ownership_epoch < OLD.ownership_epoch OR NEW.fair_sequence < OLD.fair_sequence THEN
        RAISE EXCEPTION 'runtime partition epochs are monotone'
          USING ERRCODE = 'check_violation';
      END IF;

      SELECT EXISTS (
        SELECT 1 FROM public.runtime_leader_authorities AS leader
        WHERE leader.role = 'partition_planner' AND leader.state = 'ready'
          AND leader.action_token::text = current_setting('maraithon.runtime_leader_action', true)
          AND leader.lease_expires_at > timezone('UTC', clock_timestamp())
      ) INTO leader_valid;

      SELECT EXISTS (
        SELECT 1 FROM public.runtime_node_incarnations AS node
        WHERE node.id = COALESCE(NEW.owner_node_incarnation_id, OLD.owner_node_incarnation_id)
          AND node.state IN ('ready', 'draining')
          AND node.id::text = current_setting('maraithon.runtime_node_action', true)
          AND node.lease_expires_at > timezone('UTC', clock_timestamp())
      ) INTO node_valid;

      IF OLD.state = 'unassigned' AND NEW.state = 'preparing' THEN
        IF NOT leader_valid OR NEW.ownership_epoch <> OLD.ownership_epoch + 1 THEN
          RAISE EXCEPTION 'partition assignment requires exact ready leader epoch'
            USING ERRCODE = 'check_violation';
        END IF;
      ELSIF OLD.state = 'preparing' AND NEW.state = 'ready' THEN
        IF NOT node_valid OR NEW.ownership_epoch <> OLD.ownership_epoch THEN
          RAISE EXCEPTION 'partition readiness must be published by its target incarnation last'
            USING ERRCODE = 'check_violation';
        END IF;
      ELSIF OLD.state = 'ready' AND NEW.state IN ('draining', 'blocked') THEN
        IF NOT (leader_valid OR node_valid) THEN
          RAISE EXCEPTION 'partition drain requires exact leader or owner incarnation'
            USING ERRCODE = 'check_violation';
        END IF;
      ELSIF OLD.state IN ('draining', 'blocked') AND NEW.state = 'unassigned' THEN
        IF NOT leader_valid THEN
          RAISE EXCEPTION 'partition release requires exact ready leader'
            USING ERRCODE = 'check_violation';
        END IF;
        SELECT count(*) INTO unresolved_tasks
        FROM public.runtime_task_assignments AS assignment
        WHERE assignment.partition_id = OLD.partition_id
          AND assignment.partition_epoch = OLD.ownership_epoch
          AND assignment.state IN ('reserved', 'running', 'termination_requested', 'termination_proven');
        SELECT count(*) INTO live_agents
        FROM public.agent_runtime_leases AS lease
        WHERE lease.coordination_partition_id = OLD.partition_id
          AND lease.coordination_partition_epoch = OLD.ownership_epoch;
        IF unresolved_tasks <> 0 OR live_agents <> 0 THEN
          RAISE EXCEPTION 'partition cannot move before exact task proof and Agent lease drain'
            USING ERRCODE = 'check_violation';
        END IF;
      ELSIF NEW.owner_node_incarnation_id IS DISTINCT FROM OLD.owner_node_incarnation_id OR
            NEW.ownership_epoch IS DISTINCT FROM OLD.ownership_epoch OR
            NEW.transition_id IS DISTINCT FROM OLD.transition_id OR
            NEW.activation_epoch IS DISTINCT FROM OLD.activation_epoch THEN
        RAISE EXCEPTION 'partition ownership can change only through a serialized transition'
          USING ERRCODE = 'check_violation';
      ELSIF NEW.lease_expires_at > OLD.lease_expires_at AND NOT node_valid THEN
        RAISE EXCEPTION 'partition renewal requires exact owner incarnation'
          USING ERRCODE = 'check_violation';
      END IF;

      IF OLD.lease_expires_at IS NOT NULL AND
         OLD.lease_expires_at <= timezone('UTC', clock_timestamp()) AND
         NEW.lease_expires_at > OLD.lease_expires_at AND NEW.state <> 'unassigned' THEN
        RAISE EXCEPTION 'expired partition epoch cannot be revived'
          USING ERRCODE = 'check_violation';
      END IF;
      RETURN NEW;
    END;
    $function$;
    """)

    execute(
      "DROP TRIGGER IF EXISTS enforce_runtime_partition_authority_trigger ON public.runtime_partitions"
    )

    execute("""
    CREATE TRIGGER enforce_runtime_partition_authority_trigger
      BEFORE UPDATE OR DELETE ON public.runtime_partitions
      FOR EACH ROW EXECUTE FUNCTION public.enforce_runtime_partition_authority()
    """)

    execute("""
    CREATE OR REPLACE FUNCTION public.enforce_runtime_task_outcome_evidence()
    RETURNS trigger
    LANGUAGE plpgsql
    SET search_path = pg_catalog, public
    AS $function$
    DECLARE
      assignment_row public.runtime_task_assignments%ROWTYPE;
    BEGIN
      IF current_user IS DISTINCT FROM 'maraithon_runtime' THEN
        RAISE EXCEPTION 'runtime coordination mutation requires executor role'
          USING ERRCODE = 'insufficient_privilege';
      END IF;
      IF TG_OP <> 'INSERT' THEN
        RAISE EXCEPTION 'runtime task outcome evidence is immutable'
          USING ERRCODE = 'check_violation';
      END IF;
      IF current_setting('maraithon.runtime_task_action', true)
           IS DISTINCT FROM NEW.assignment_id::text THEN
        RAISE EXCEPTION 'runtime task outcome evidence requires exact task action'
          USING ERRCODE = 'check_violation';
      END IF;
      SELECT * INTO assignment_row FROM public.runtime_task_assignments
      WHERE id = NEW.assignment_id FOR UPDATE;
      IF NOT FOUND OR assignment_row.state <> 'running' OR
         assignment_row.provider_boundary <> 'entered' OR
         assignment_row.activation_epoch IS DISTINCT FROM NEW.activation_epoch OR
         assignment_row.claim_token IS DISTINCT FROM NEW.claim_token OR
         assignment_row.node_incarnation_id IS DISTINCT FROM NEW.node_incarnation_id OR
         assignment_row.supervisor_id IS DISTINCT FROM NEW.supervisor_id OR
         assignment_row.local_task_id IS DISTINCT FROM NEW.local_task_id OR
         assignment_row.lease_expires_at <= timezone('UTC', clock_timestamp()) OR
         NOT public.runtime_task_authority_valid(
           assignment_row.id, assignment_row.activation_epoch, assignment_row.partition_id,
           assignment_row.partition_epoch, assignment_row.node_incarnation_id,
           assignment_row.claim_token) THEN
        RAISE EXCEPTION 'runtime task outcome evidence lacks live exact authority'
          USING ERRCODE = 'check_violation';
      END IF;
      UPDATE public.runtime_task_assignments
      SET provider_boundary = 'outcome_known',
          updated_at = timezone('UTC', clock_timestamp())
      WHERE id = NEW.assignment_id AND state = 'running' AND provider_boundary = 'entered';
      IF NOT FOUND THEN
        RAISE EXCEPTION 'runtime task provider boundary changed while recording outcome'
          USING ERRCODE = 'check_violation';
      END IF;
      RETURN NEW;
    END;
    $function$;
    """)

    execute(
      "DROP TRIGGER IF EXISTS enforce_runtime_task_outcome_evidence_trigger ON public.runtime_task_outcome_evidence"
    )

    execute("""
    CREATE TRIGGER enforce_runtime_task_outcome_evidence_trigger
      BEFORE INSERT OR UPDATE OR DELETE ON public.runtime_task_outcome_evidence
      FOR EACH ROW EXECUTE FUNCTION public.enforce_runtime_task_outcome_evidence()
    """)

    execute(
      "DROP TRIGGER IF EXISTS reject_runtime_task_outcome_evidence_truncate_trigger ON public.runtime_task_outcome_evidence"
    )

    execute("""
    CREATE TRIGGER reject_runtime_task_outcome_evidence_truncate_trigger
      BEFORE TRUNCATE ON public.runtime_task_outcome_evidence
      FOR EACH STATEMENT EXECUTE FUNCTION public.reject_runtime_coordination_evidence_mutation()
    """)

    execute("""
    CREATE OR REPLACE FUNCTION public.enforce_runtime_task_assignment()
    RETURNS trigger
    LANGUAGE plpgsql
    SET search_path = pg_catalog, public
    AS $function$
    DECLARE
      authority_valid boolean;
      proof_valid boolean;
      outcome_evidence_valid boolean;
      ready_authority_required boolean;
      runtime_protocol_mode text;
      effect_protocol_mode text;
    BEGIN
      IF current_user NOT IN ('maraithon_runtime', 'maraithon_incident_operator') THEN
        RAISE EXCEPTION 'runtime task assignment mutation requires an authorized exact role'
          USING ERRCODE = 'insufficient_privilege';
      END IF;

      SELECT mode INTO STRICT runtime_protocol_mode
      FROM public.runtime_coordination_protocols
      WHERE name = 'runtime';

      SELECT mode INTO STRICT effect_protocol_mode
      FROM public.effect_execution_protocols
      WHERE name = 'effects';

      IF runtime_protocol_mode <> 'partition_fenced_v1' OR
         effect_protocol_mode <> 'generation_fenced_v1' THEN
        RAISE EXCEPTION 'runtime task assignment requires the active exact protocol pair'
          USING ERRCODE = 'check_violation';
      END IF;

      IF current_user = 'maraithon_incident_operator' AND
         (TG_OP <> 'UPDATE' OR OLD.state <> 'termination_requested' OR
          NEW.state <> 'termination_proven') THEN
        RAISE EXCEPTION 'incident operator may only attach external termination proof'
          USING ERRCODE = 'insufficient_privilege';
      END IF;
      IF TG_OP = 'DELETE' THEN
        RAISE EXCEPTION 'runtime task assignment history is immutable'
          USING ERRCODE = 'check_violation';
      END IF;

      IF current_setting('maraithon.runtime_task_action', true)
           IS DISTINCT FROM COALESCE(NEW.id, OLD.id)::text THEN
        RAISE EXCEPTION 'runtime task action requires its exact assignment incarnation'
          USING ERRCODE = 'check_violation';
      END IF;

      IF TG_OP = 'INSERT' AND NEW.work_kind = 'effect' AND
         (NEW.state <> 'reserved' OR NEW.provider_boundary <> 'not_entered') THEN
        RAISE EXCEPTION 'Effect task assignments must begin reserved before provider entry'
          USING ERRCODE = 'check_violation';
      END IF;

      IF TG_OP = 'INSERT' THEN
        SELECT EXISTS (
          SELECT 1
          FROM public.runtime_coordination_protocols AS protocol
          JOIN public.runtime_node_incarnations AS node
            ON node.id = NEW.node_incarnation_id
           AND node.activation_epoch = protocol.activation_epoch
           AND node.state = 'ready' AND node.ready_at IS NOT NULL
           AND node.lease_expires_at > timezone('UTC', clock_timestamp())
          JOIN public.runtime_partitions AS partition
            ON partition.partition_id = NEW.partition_id
           AND partition.activation_epoch = protocol.activation_epoch
           AND partition.ownership_epoch = NEW.partition_epoch
           AND partition.owner_node_incarnation_id = NEW.node_incarnation_id
           AND partition.state = 'ready' AND partition.ready_at IS NOT NULL
           AND partition.lease_expires_at > timezone('UTC', clock_timestamp())
          WHERE protocol.name = 'runtime' AND protocol.mode = 'partition_fenced_v1'
            AND protocol.activation_epoch = NEW.activation_epoch
        ) INTO authority_valid;
        IF NOT authority_valid THEN
          RAISE EXCEPTION 'runtime task reservation lacks ready partition authority'
            USING ERRCODE = 'check_violation';
        END IF;
      ELSE
        IF NEW.id IS DISTINCT FROM OLD.id OR
           NEW.activation_epoch IS DISTINCT FROM OLD.activation_epoch OR
           NEW.work_kind IS DISTINCT FROM OLD.work_kind OR
           NEW.work_id IS DISTINCT FROM OLD.work_id OR
           NEW.claim_token IS DISTINCT FROM OLD.claim_token OR
           NEW.partition_id IS DISTINCT FROM OLD.partition_id OR
           NEW.partition_epoch IS DISTINCT FROM OLD.partition_epoch OR
           NEW.node_incarnation_id IS DISTINCT FROM OLD.node_incarnation_id OR
           NEW.supervisor_id IS DISTINCT FROM OLD.supervisor_id OR
           NEW.local_task_id IS DISTINCT FROM OLD.local_task_id OR
           NEW.ready_at IS DISTINCT FROM OLD.ready_at AND OLD.ready_at IS NOT NULL OR
           (OLD.provider_boundary = 'not_entered' AND
            NEW.provider_boundary NOT IN ('not_entered', 'entered')) OR
           (OLD.provider_boundary = 'entered' AND
            NEW.provider_boundary NOT IN ('entered', 'outcome_known', 'outcome_unknown')) OR
           (OLD.provider_boundary IN ('outcome_known', 'outcome_unknown') AND
            NEW.provider_boundary IS DISTINCT FROM OLD.provider_boundary) THEN
          RAISE EXCEPTION 'runtime task incarnation identity is immutable'
            USING ERRCODE = 'check_violation';
        END IF;

        IF OLD.state = 'reserved' AND NEW.state NOT IN ('reserved', 'running', 'termination_requested', 'settled') OR
           OLD.state = 'running' AND NEW.state NOT IN ('running', 'termination_requested', 'settled') OR
           OLD.state = 'termination_requested' AND
             NEW.state NOT IN ('termination_requested', 'termination_proven', 'settled') OR
           OLD.state = 'termination_proven' AND
             NEW.state NOT IN ('termination_proven', 'settled', 'outcome_ambiguous') OR
           OLD.state IN ('settled', 'outcome_ambiguous') AND NEW IS DISTINCT FROM OLD THEN
          RAISE EXCEPTION 'runtime task assignment transition is not monotone'
            USING ERRCODE = 'check_violation';
        END IF;

        IF OLD.provider_boundary = 'not_entered' AND NEW.provider_boundary = 'entered' AND
           NEW.state <> 'running' THEN
          RAISE EXCEPTION 'provider entry requires a running exact task'
            USING ERRCODE = 'check_violation';
        END IF;

        IF ((OLD.state = 'reserved' AND NEW.state = 'running') OR
            (OLD.provider_boundary = 'not_entered' AND NEW.provider_boundary = 'entered')) AND
           NEW.lease_expires_at <= timezone('UTC', clock_timestamp()) THEN
          RAISE EXCEPTION 'expired task incarnation cannot activate or enter a provider'
            USING ERRCODE = 'check_violation';
        END IF;

        IF OLD.provider_boundary = 'entered' AND NEW.provider_boundary = 'outcome_known' THEN
          SELECT EXISTS (
            SELECT 1 FROM public.runtime_task_outcome_evidence AS evidence
            WHERE evidence.assignment_id = OLD.id
              AND evidence.activation_epoch = OLD.activation_epoch
              AND evidence.claim_token = OLD.claim_token
              AND evidence.node_incarnation_id = OLD.node_incarnation_id
              AND evidence.supervisor_id = OLD.supervisor_id
              AND evidence.local_task_id = OLD.local_task_id
          ) INTO outcome_evidence_valid;
          -- The evidence BEFORE trigger advances this boundary before its row is
          -- visible, so only that trigger is allowed to make this same-state step.
          IF NOT outcome_evidence_valid AND pg_trigger_depth() = 1 THEN
            RAISE EXCEPTION 'provider outcome boundary requires exact durable evidence'
              USING ERRCODE = 'check_violation';
          END IF;
        END IF;

        IF NEW.state = 'settled' AND NEW.state IS DISTINCT FROM OLD.state THEN
          IF NEW.provider_boundary = 'not_entered' THEN
            IF NEW.outcome IS DISTINCT FROM 'cancelled_before_provider' THEN
              RAISE EXCEPTION 'pre-provider settlement has a fixed cancellation outcome'
                USING ERRCODE = 'check_violation';
            END IF;
          ELSIF NEW.provider_boundary = 'outcome_known' THEN
            SELECT EXISTS (
              SELECT 1 FROM public.runtime_task_outcome_evidence AS evidence
              WHERE evidence.assignment_id = NEW.id
                AND evidence.activation_epoch = NEW.activation_epoch
                AND evidence.claim_token = NEW.claim_token
                AND evidence.node_incarnation_id = NEW.node_incarnation_id
                AND evidence.supervisor_id = NEW.supervisor_id
                AND evidence.local_task_id = NEW.local_task_id
                AND evidence.outcome = NEW.outcome
            ) INTO outcome_evidence_valid;
            IF NOT outcome_evidence_valid THEN
              RAISE EXCEPTION 'provider settlement requires matching exact outcome evidence'
                USING ERRCODE = 'check_violation';
            END IF;
          ELSE
            RAISE EXCEPTION 'unknown provider outcome cannot be settled'
              USING ERRCODE = 'check_violation';
          END IF;
        END IF;

        IF NEW.state = 'outcome_ambiguous' AND NEW.state IS DISTINCT FROM OLD.state AND
           (NEW.provider_boundary NOT IN ('entered', 'outcome_unknown') OR
            NEW.outcome IS DISTINCT FROM 'provider_outcome_ambiguous') THEN
          RAISE EXCEPTION 'termination proof can only record content-free provider ambiguity'
            USING ERRCODE = 'check_violation';
        END IF;

        IF (NEW.state = 'running' AND NEW.state IS DISTINCT FROM OLD.state) OR
           (OLD.state = 'running' AND NEW.state = 'settled') OR
           (OLD.provider_boundary = 'not_entered' AND NEW.provider_boundary = 'entered') OR
           (OLD.provider_boundary = 'entered' AND NEW.provider_boundary = 'outcome_known') OR
           NEW.lease_expires_at > OLD.lease_expires_at THEN
          ready_authority_required :=
            (NEW.state = 'running' AND NEW.state IS DISTINCT FROM OLD.state) OR
            (OLD.provider_boundary = 'not_entered' AND NEW.provider_boundary = 'entered') OR
            NEW.lease_expires_at > OLD.lease_expires_at;

          SELECT EXISTS (
            SELECT 1 FROM public.runtime_partitions AS partition
            JOIN public.runtime_node_incarnations AS node
              ON node.id = NEW.node_incarnation_id
             AND node.activation_epoch = NEW.activation_epoch
             AND node.state = ANY(
                   CASE WHEN ready_authority_required THEN ARRAY['ready']::text[]
                        ELSE ARRAY['ready', 'draining']::text[] END)
             AND (NOT ready_authority_required OR node.ready_at IS NOT NULL)
             AND node.lease_expires_at > timezone('UTC', clock_timestamp())
            WHERE partition.partition_id = NEW.partition_id
              AND partition.activation_epoch = NEW.activation_epoch
              AND partition.ownership_epoch = NEW.partition_epoch
              AND partition.owner_node_incarnation_id = NEW.node_incarnation_id
              AND partition.state = ANY(
                    CASE WHEN ready_authority_required THEN ARRAY['ready']::text[]
                         ELSE ARRAY['ready', 'draining']::text[] END)
              AND (NOT ready_authority_required OR partition.ready_at IS NOT NULL)
              AND partition.lease_expires_at > timezone('UTC', clock_timestamp())
            FOR SHARE OF partition, node
          ) INTO authority_valid;
          IF NOT authority_valid THEN
            RAISE EXCEPTION 'stale runtime task cannot activate, enter, renew, or settle'
              USING ERRCODE = 'check_violation';
          END IF;
        END IF;

        IF OLD.lease_expires_at <= timezone('UTC', clock_timestamp()) AND
           NEW.lease_expires_at > OLD.lease_expires_at THEN
          RAISE EXCEPTION 'expired task incarnation cannot be revived'
            USING ERRCODE = 'check_violation';
        END IF;

        IF NEW.state = 'termination_proven' AND OLD.state <> 'termination_proven' THEN
          SELECT EXISTS (
            SELECT 1 FROM public.runtime_task_termination_proofs AS proof
            WHERE proof.assignment_id = OLD.id
              AND proof.activation_epoch = OLD.activation_epoch
              AND proof.claim_token = OLD.claim_token
              AND proof.node_incarnation_id = OLD.node_incarnation_id
              AND proof.supervisor_id = OLD.supervisor_id
              AND proof.local_task_id = OLD.local_task_id
          ) INTO proof_valid;
          IF NOT proof_valid THEN
            RAISE EXCEPTION 'runtime task termination requires exact physical proof'
              USING ERRCODE = 'check_violation';
          END IF;
        END IF;
      END IF;
      RETURN NEW;
    END;
    $function$;
    """)

    execute(
      "DROP TRIGGER IF EXISTS enforce_runtime_task_assignment_trigger ON public.runtime_task_assignments"
    )

    execute("""
    CREATE TRIGGER enforce_runtime_task_assignment_trigger
      BEFORE INSERT OR UPDATE OR DELETE ON public.runtime_task_assignments
      FOR EACH ROW EXECUTE FUNCTION public.enforce_runtime_task_assignment()
    """)

    execute("""
    CREATE OR REPLACE FUNCTION public.enforce_runtime_task_termination_proof()
    RETURNS trigger
    LANGUAGE plpgsql
    SET search_path = pg_catalog, public
    AS $function$
    DECLARE
      proof_valid boolean;
      confirmation text;
    BEGIN
      IF (NEW.proof_kind = 'supervisor_down' AND
          current_user IS DISTINCT FROM 'maraithon_runtime') OR
         (NEW.proof_kind = 'external_destroyed' AND
          current_user IS DISTINCT FROM 'maraithon_incident_operator') THEN
        RAISE EXCEPTION 'task termination proof kind is not authorized for current role'
          USING ERRCODE = 'insufficient_privilege';
      END IF;
      confirmation := current_setting('maraithon.runtime_task_termination_proof', true);
      IF NEW.proof_kind = 'supervisor_down' THEN
        IF confirmation IS DISTINCT FROM 'LOCAL_TASK_SUPERVISOR_PROOF' THEN
          RAISE EXCEPTION 'local task termination proof confirmation is required'
            USING ERRCODE = 'check_violation';
        END IF;
      ELSIF confirmation IS DISTINCT FROM 'PHYSICAL_TASK_TERMINATED' THEN
        RAISE EXCEPTION 'external task termination proof confirmation is required'
          USING ERRCODE = 'check_violation';
      END IF;

      SELECT EXISTS (
        SELECT 1 FROM public.runtime_task_assignments AS assignment
        WHERE assignment.id = NEW.assignment_id
          AND assignment.state = 'termination_requested'
          AND assignment.activation_epoch = NEW.activation_epoch
          AND assignment.claim_token = NEW.claim_token
          AND assignment.node_incarnation_id = NEW.node_incarnation_id
          AND assignment.supervisor_id = NEW.supervisor_id
          AND assignment.local_task_id = NEW.local_task_id
        FOR SHARE
      ) INTO proof_valid;
      IF NOT proof_valid THEN
        RAISE EXCEPTION 'task termination proof does not match a fenced incarnation'
          USING ERRCODE = 'check_violation';
      END IF;
      NEW.proved_at := timezone('UTC', clock_timestamp());
      RETURN NEW;
    END;
    $function$;
    """)

    execute(
      "DROP TRIGGER IF EXISTS enforce_runtime_task_termination_proof_trigger ON public.runtime_task_termination_proofs"
    )

    execute("""
    CREATE TRIGGER enforce_runtime_task_termination_proof_trigger
      BEFORE INSERT ON public.runtime_task_termination_proofs
      FOR EACH ROW EXECUTE FUNCTION public.enforce_runtime_task_termination_proof()
    """)

    execute("""
    CREATE OR REPLACE FUNCTION public.runtime_task_authority_valid(
      requested_assignment uuid,
      requested_activation uuid,
      requested_partition smallint,
      requested_epoch bigint,
      requested_node uuid,
      requested_claim uuid
    ) RETURNS boolean
    LANGUAGE sql
    STABLE
    SET search_path = pg_catalog, public
    AS $function$
      SELECT EXISTS (
        SELECT 1
        FROM public.runtime_task_assignments AS assignment
        JOIN public.runtime_partitions AS partition
          ON partition.partition_id = assignment.partition_id
         AND partition.activation_epoch = assignment.activation_epoch
         AND partition.ownership_epoch = assignment.partition_epoch
         AND partition.owner_node_incarnation_id = assignment.node_incarnation_id
         AND partition.state IN ('ready', 'draining')
         AND partition.lease_expires_at > timezone('UTC', clock_timestamp())
        JOIN public.runtime_node_incarnations AS node
          ON node.id = assignment.node_incarnation_id
         AND node.activation_epoch = assignment.activation_epoch
         AND node.state IN ('ready', 'draining')
         AND node.lease_expires_at > timezone('UTC', clock_timestamp())
        WHERE assignment.id = requested_assignment
          AND assignment.activation_epoch = requested_activation
          AND assignment.partition_id = requested_partition
          AND assignment.partition_epoch = requested_epoch
          AND assignment.node_incarnation_id = requested_node
          AND assignment.claim_token = requested_claim
          AND assignment.state = 'running'
          AND assignment.lease_expires_at > timezone('UTC', clock_timestamp())
      )
    $function$;
    """)

    execute("""
    CREATE OR REPLACE FUNCTION public.enforce_runtime_work_role()
    RETURNS trigger
    LANGUAGE plpgsql
    SET search_path = pg_catalog, public
    AS $function$
    BEGIN
      IF current_user IS DISTINCT FROM 'maraithon_runtime' AND NOT (
        current_user = 'maraithon_migrator' AND EXISTS (
          SELECT 1 FROM public.runtime_coordination_protocols
          WHERE name = 'runtime' AND mode = 'dark'
        )
      ) THEN
        RAISE EXCEPTION 'durable runtime work mutation requires executor role'
          USING ERRCODE = 'insufficient_privilege';
      END IF;
      RETURN COALESCE(NEW, OLD);
    END;
    $function$;
    """)

    for table <- ["agent_runs", "agent_run_steps"] do
      execute("DROP TRIGGER IF EXISTS enforce_#{table}_runtime_role_trigger ON public.#{table}")

      execute("""
      CREATE TRIGGER enforce_#{table}_runtime_role_trigger
        BEFORE INSERT OR UPDATE OR DELETE ON public.#{table}
        FOR EACH ROW EXECUTE FUNCTION public.enforce_runtime_work_role()
      """)
    end

    execute("""
    CREATE OR REPLACE FUNCTION public.enforce_coordinated_background_job()
    RETURNS trigger
    LANGUAGE plpgsql
    SET search_path = pg_catalog, public
    AS $function$
    DECLARE
      protocol_mode text;
      terminal_valid boolean;
      terminal_state text;
      terminal_outcome text;
    BEGIN
      IF current_user IS DISTINCT FROM 'maraithon_runtime' AND NOT (
        current_user = 'maraithon_migrator' AND EXISTS (
          SELECT 1 FROM public.runtime_coordination_protocols
          WHERE name = 'runtime' AND mode = 'dark'
        )
      ) THEN
        RAISE EXCEPTION 'coordinated work mutation requires executor role'
          USING ERRCODE = 'insufficient_privilege';
      END IF;
      SELECT mode INTO STRICT protocol_mode
      FROM public.runtime_coordination_protocols WHERE name = 'runtime';
      IF protocol_mode = 'dark' THEN RETURN NEW; END IF;
      IF protocol_mode <> 'partition_fenced_v1' THEN
        RAISE EXCEPTION 'unknown runtime coordination protocol'
          USING ERRCODE = 'check_violation';
      END IF;

      IF NEW.status = 'running' THEN
        IF NEW.claim_token IS NULL OR NEW.coordination_activation_epoch IS NULL OR
           NEW.coordination_partition_epoch IS NULL OR
           NEW.coordination_node_incarnation_id IS NULL OR
           NEW.coordination_task_assignment_id IS NULL OR
           NEW.coordination_task_supervisor_id IS NULL OR
           NEW.coordination_local_task_id IS NULL THEN
          RAISE EXCEPTION 'coordinated background job requires exact task incarnation'
            USING ERRCODE = 'check_violation';
        END IF;
      END IF;

      IF OLD.status <> 'running' AND NEW.status = 'running' THEN
        IF NOT public.runtime_task_authority_valid(
          NEW.coordination_task_assignment_id, NEW.coordination_activation_epoch,
          NEW.partition_id, NEW.coordination_partition_epoch,
          NEW.coordination_node_incarnation_id, NEW.claim_token) THEN
          RAISE EXCEPTION 'background job activation requires ready task and partition authority'
            USING ERRCODE = 'check_violation';
        END IF;
      END IF;

      IF OLD.status = 'running' AND NEW.status IS DISTINCT FROM OLD.status THEN
        SELECT assignment.state, assignment.outcome,
          assignment.activation_epoch = OLD.coordination_activation_epoch AND
          assignment.claim_token = OLD.claim_token AND
          assignment.node_incarnation_id = OLD.coordination_node_incarnation_id AND
          assignment.supervisor_id = OLD.coordination_task_supervisor_id AND
          assignment.local_task_id = OLD.coordination_local_task_id AND
          assignment.partition_id = OLD.partition_id AND
          assignment.partition_epoch = OLD.coordination_partition_epoch AND
          assignment.state IN ('settled', 'outcome_ambiguous')
        INTO terminal_state, terminal_outcome, terminal_valid
        FROM public.runtime_task_assignments AS assignment
        WHERE assignment.id = OLD.coordination_task_assignment_id;

        IF NOT COALESCE(terminal_valid, false) OR
           current_setting('maraithon.runtime_task_action', true)
             IS DISTINCT FROM OLD.coordination_task_assignment_id::text THEN
          RAISE EXCEPTION 'background terminal mutation requires exact terminal task evidence'
            USING ERRCODE = 'check_violation';
        END IF;
        IF terminal_state = 'settled' AND (
             (NEW.status = 'completed' AND terminal_outcome <> 'completed') OR
             (NEW.status = 'pending' AND terminal_outcome NOT IN
               ('retry_scheduled', 'cancelled_before_provider')) OR
             (NEW.status = 'failed' AND terminal_outcome <> 'failed')
           ) THEN
          RAISE EXCEPTION 'background terminal row does not match durable task outcome'
            USING ERRCODE = 'check_violation';
        END IF;
        IF terminal_state = 'outcome_ambiguous' AND
           (NEW.status <> 'failed' OR terminal_outcome <> 'provider_outcome_ambiguous' OR
            NEW.last_error <> 'provider_outcome_ambiguous') THEN
          RAISE EXCEPTION 'ambiguous provider outcome is content-free and non-retryable'
            USING ERRCODE = 'check_violation';
        END IF;
      END IF;

      IF OLD.status = 'running' AND NEW.status = 'running' AND (
        NEW.claim_token IS DISTINCT FROM OLD.claim_token OR
        NEW.coordination_activation_epoch IS DISTINCT FROM OLD.coordination_activation_epoch OR
        NEW.coordination_partition_epoch IS DISTINCT FROM OLD.coordination_partition_epoch OR
        NEW.coordination_node_incarnation_id IS DISTINCT FROM OLD.coordination_node_incarnation_id OR
        NEW.coordination_task_assignment_id IS DISTINCT FROM OLD.coordination_task_assignment_id OR
        NEW.coordination_task_supervisor_id IS DISTINCT FROM OLD.coordination_task_supervisor_id OR
        NEW.coordination_local_task_id IS DISTINCT FROM OLD.coordination_local_task_id
      ) THEN
        RAISE EXCEPTION 'background task incarnation identity is immutable'
          USING ERRCODE = 'check_violation';
      END IF;
      RETURN NEW;
    EXCEPTION WHEN no_data_found THEN
      RAISE EXCEPTION 'runtime coordination protocol row is missing'
        USING ERRCODE = 'check_violation';
    END;
    $function$;
    """)

    execute(
      "DROP TRIGGER IF EXISTS enforce_coordinated_background_job_trigger ON public.background_jobs"
    )

    execute("""
    CREATE TRIGGER enforce_coordinated_background_job_trigger
      BEFORE UPDATE ON public.background_jobs
      FOR EACH ROW EXECUTE FUNCTION public.enforce_coordinated_background_job()
    """)

    execute("""
    CREATE OR REPLACE FUNCTION public.enforce_coordinated_scheduled_job()
    RETURNS trigger
    LANGUAGE plpgsql
    SET search_path = pg_catalog, public
    AS $function$
    DECLARE
      protocol_mode text;
      authority_valid boolean;
      ready_authority_required boolean;
    BEGIN
      IF current_user IS DISTINCT FROM 'maraithon_runtime' AND NOT (
        current_user = 'maraithon_migrator' AND EXISTS (
          SELECT 1 FROM public.runtime_coordination_protocols
          WHERE name = 'runtime' AND mode = 'dark'
        )
      ) THEN
        RAISE EXCEPTION 'coordinated work mutation requires executor role'
          USING ERRCODE = 'insufficient_privilege';
      END IF;
      SELECT mode INTO STRICT protocol_mode
      FROM public.runtime_coordination_protocols WHERE name = 'runtime';
      IF protocol_mode = 'dark' THEN RETURN NEW; END IF;

      IF OLD.dispatch_token IS NOT NULL AND NEW.dispatch_token IS DISTINCT FROM OLD.dispatch_token THEN
        RAISE EXCEPTION 'scheduled dispatch incarnation is immutable'
          USING ERRCODE = 'check_violation';
      END IF;

      IF NEW.status IS DISTINCT FROM OLD.status AND
         (NEW.status IN ('dispatched', 'delivered') OR OLD.status = 'dispatched') THEN
        IF NEW.dispatch_token IS NULL OR
           current_setting('maraithon.runtime_schedule_action', true)
             IS DISTINCT FROM NEW.dispatch_token::text OR
           NEW.coordination_activation_epoch IS NULL OR
           NEW.coordination_partition_epoch IS NULL OR
           NEW.coordination_node_incarnation_id IS NULL THEN
          RAISE EXCEPTION 'scheduled action requires exact dispatch and partition incarnation'
            USING ERRCODE = 'check_violation';
        END IF;

        ready_authority_required := OLD.status <> 'dispatched';
        SELECT EXISTS (
          SELECT 1 FROM public.runtime_partitions AS partition
          JOIN public.runtime_node_incarnations AS node
            ON node.id = NEW.coordination_node_incarnation_id
           AND node.activation_epoch = NEW.coordination_activation_epoch
           AND node.state = ANY(
                 CASE WHEN ready_authority_required THEN ARRAY['ready']::text[]
                      ELSE ARRAY['ready', 'draining']::text[] END)
           AND (NOT ready_authority_required OR node.ready_at IS NOT NULL)
           AND node.lease_expires_at > timezone('UTC', clock_timestamp())
          WHERE partition.partition_id = NEW.partition_id
            AND partition.activation_epoch = NEW.coordination_activation_epoch
            AND partition.ownership_epoch = NEW.coordination_partition_epoch
            AND partition.owner_node_incarnation_id = NEW.coordination_node_incarnation_id
            AND partition.state = ANY(
                  CASE WHEN ready_authority_required THEN ARRAY['ready']::text[]
                       ELSE ARRAY['ready', 'draining']::text[] END)
            AND (NOT ready_authority_required OR partition.ready_at IS NOT NULL)
            AND partition.lease_expires_at > timezone('UTC', clock_timestamp())
          FOR SHARE OF partition, node
        ) INTO authority_valid;
        IF NOT authority_valid THEN
          RAISE EXCEPTION 'stale scheduler action cannot mutate after partition epoch loss'
            USING ERRCODE = 'check_violation';
        END IF;
      END IF;
      RETURN NEW;
    EXCEPTION WHEN no_data_found THEN
      RAISE EXCEPTION 'runtime coordination protocol row is missing'
        USING ERRCODE = 'check_violation';
    END;
    $function$;
    """)

    execute(
      "DROP TRIGGER IF EXISTS enforce_coordinated_scheduled_job_trigger ON public.scheduled_jobs"
    )

    execute("""
    CREATE TRIGGER enforce_coordinated_scheduled_job_trigger
      BEFORE UPDATE ON public.scheduled_jobs
      FOR EACH ROW EXECUTE FUNCTION public.enforce_coordinated_scheduled_job()
    """)

    execute("""
    CREATE OR REPLACE FUNCTION public.enforce_coordinated_agent_directive()
    RETURNS trigger
    LANGUAGE plpgsql
    SET search_path = pg_catalog, public
    AS $function$
    DECLARE
      protocol_mode text;
      authority_valid boolean;
      reconciler_valid boolean;
      activating boolean := false;
      directive_row public.agent_directives%ROWTYPE;
    BEGIN
      IF current_user IS DISTINCT FROM 'maraithon_runtime' AND NOT (
        current_user = 'maraithon_migrator' AND EXISTS (
          SELECT 1 FROM public.runtime_coordination_protocols
          WHERE name = 'runtime' AND mode = 'dark'
        )
      ) THEN
        RAISE EXCEPTION 'coordinated work mutation requires executor role'
          USING ERRCODE = 'insufficient_privilege';
      END IF;
      SELECT mode INTO STRICT protocol_mode
      FROM public.runtime_coordination_protocols WHERE name = 'runtime';
      IF protocol_mode = 'dark' THEN RETURN COALESCE(NEW, OLD); END IF;
      IF TG_OP = 'INSERT' THEN RETURN NEW; END IF;
      directive_row := CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;
      IF TG_OP = 'UPDATE' THEN
        activating := OLD.status <> 'processing' AND NEW.status = 'processing';
      END IF;

      IF OLD.status = 'processing' OR activating THEN
        SELECT EXISTS (
          SELECT 1 FROM public.agent_runtime_leases AS lease
          JOIN public.runtime_partitions AS partition
            ON partition.partition_id = lease.coordination_partition_id
           AND partition.activation_epoch = lease.coordination_activation_epoch
           AND partition.ownership_epoch = lease.coordination_partition_epoch
           AND partition.owner_node_incarnation_id = lease.coordination_node_incarnation_id
           AND partition.state = ANY(
                 CASE WHEN activating THEN ARRAY['ready']::text[]
                      ELSE ARRAY['ready', 'draining']::text[] END)
           AND (NOT activating OR partition.ready_at IS NOT NULL)
           AND partition.lease_expires_at > timezone('UTC', clock_timestamp())
          JOIN public.runtime_node_incarnations AS node
            ON node.id = lease.coordination_node_incarnation_id
           AND node.activation_epoch = lease.coordination_activation_epoch
           AND node.state = ANY(
                 CASE WHEN activating THEN ARRAY['ready']::text[]
                      ELSE ARRAY['ready', 'draining']::text[] END)
           AND (NOT activating OR node.ready_at IS NOT NULL)
           AND node.lease_expires_at > timezone('UTC', clock_timestamp())
          WHERE lease.agent_id = directive_row.agent_id
            AND lease.owner_token = COALESCE(directive_row.claimed_by_generation,
                                             OLD.claimed_by_generation)
            AND lease.lease_until > timezone('UTC', clock_timestamp())
            AND (NOT activating OR (lease.ready_at IS NOT NULL AND lease.draining_at IS NULL))
        ) INTO authority_valid;

        SELECT EXISTS (
          SELECT 1 FROM public.runtime_partitions AS partition
          JOIN public.runtime_node_incarnations AS node
            ON node.id = partition.owner_node_incarnation_id
           AND node.activation_epoch = partition.activation_epoch
           AND node.state = 'ready' AND node.ready_at IS NOT NULL
           AND node.lease_expires_at > timezone('UTC', clock_timestamp())
          WHERE partition.partition_id = public.runtime_partition_for('user:' || directive_row.user_id)
            AND partition.state = 'ready' AND partition.ready_at IS NOT NULL
            AND partition.owner_node_incarnation_id::text =
                  current_setting('maraithon.runtime_node_action', true)
            AND current_setting('maraithon.runtime_agent_reconciliation', true) =
                  directive_row.agent_id::text
            AND partition.lease_expires_at > timezone('UTC', clock_timestamp())
        ) INTO reconciler_valid;

        IF NOT authority_valid AND NOT reconciler_valid THEN
          RAISE EXCEPTION 'stale Agent Directive owner cannot mutate after partition epoch loss'
            USING ERRCODE = 'check_violation';
        END IF;
      END IF;
      RETURN COALESCE(NEW, OLD);
    EXCEPTION WHEN no_data_found THEN
      RAISE EXCEPTION 'runtime coordination protocol row is missing'
        USING ERRCODE = 'check_violation';
    END;
    $function$;
    """)

    execute(
      "DROP TRIGGER IF EXISTS enforce_coordinated_agent_directive_trigger ON public.agent_directives"
    )

    execute("""
    CREATE TRIGGER enforce_coordinated_agent_directive_trigger
      BEFORE INSERT OR UPDATE OR DELETE ON public.agent_directives
      FOR EACH ROW EXECUTE FUNCTION public.enforce_coordinated_agent_directive()
    """)

    execute("""
    CREATE OR REPLACE FUNCTION public.enforce_coordinated_agent_lease()
    RETURNS trigger
    LANGUAGE plpgsql
    SET search_path = pg_catalog, public
    AS $function$
    DECLARE
      protocol_mode text;
      authority_valid boolean;
      termination_valid boolean;
      ready_authority_required boolean;
    BEGIN
      IF current_user IS DISTINCT FROM 'maraithon_runtime' AND NOT (
        current_user = 'maraithon_migrator' AND EXISTS (
          SELECT 1 FROM public.runtime_coordination_protocols
          WHERE name = 'runtime' AND mode = 'dark'
        )
      ) THEN
        RAISE EXCEPTION 'coordinated work mutation requires executor role'
          USING ERRCODE = 'insufficient_privilege';
      END IF;
      SELECT mode INTO STRICT protocol_mode
      FROM public.runtime_coordination_protocols WHERE name = 'runtime';

      IF TG_OP = 'DELETE' THEN
        SELECT EXISTS (
          SELECT 1
          FROM public.agent_termination_incidents AS incident
          JOIN public.agent_termination_proofs AS proof
            ON proof.incident_id = incident.id
           AND proof.agent_id = incident.agent_id
           AND proof.lease_token = incident.lease_token
          WHERE incident.id::text =
                  current_setting('maraithon.agent_termination_reconciliation', true)
            AND incident.status = 'proven'
            AND incident.agent_id = OLD.agent_id
            AND incident.lease_token = OLD.owner_token
            AND incident.activation_epoch IS NOT DISTINCT FROM
                  OLD.coordination_activation_epoch
            AND incident.node_incarnation_id IS NOT DISTINCT FROM
                  OLD.coordination_node_incarnation_id
            AND incident.partition_id IS NOT DISTINCT FROM
                  OLD.coordination_partition_id
            AND incident.partition_epoch IS NOT DISTINCT FROM
                  OLD.coordination_partition_epoch
        ) INTO termination_valid;

        IF NOT termination_valid THEN
          RAISE EXCEPTION 'Agent lease deletion requires exact physical termination proof'
            USING ERRCODE = 'check_violation';
        END IF;
        RETURN OLD;
      END IF;

      IF protocol_mode = 'dark' THEN RETURN NEW; END IF;

      IF NEW.coordination_activation_epoch IS NULL OR
         NEW.coordination_partition_id IS NULL OR
         NEW.coordination_partition_epoch IS NULL OR
         NEW.coordination_node_incarnation_id IS NULL THEN
        RAISE EXCEPTION 'exact Agent lease requires partition incarnation authority'
          USING ERRCODE = 'check_violation';
      END IF;

      IF TG_OP = 'UPDATE' AND (
        NEW.coordination_activation_epoch IS DISTINCT FROM OLD.coordination_activation_epoch OR
        NEW.coordination_partition_id IS DISTINCT FROM OLD.coordination_partition_id OR
        NEW.coordination_partition_epoch IS DISTINCT FROM OLD.coordination_partition_epoch OR
        NEW.coordination_node_incarnation_id IS DISTINCT FROM OLD.coordination_node_incarnation_id
      ) THEN
        RAISE EXCEPTION 'Agent lease partition incarnation is immutable'
          USING ERRCODE = 'check_violation';
      END IF;

      ready_authority_required := TG_OP = 'INSERT' OR (
        TG_OP = 'UPDATE' AND (
          NEW.lease_until > OLD.lease_until OR
          (OLD.ready_at IS NULL AND NEW.ready_at IS NOT NULL) OR
          (OLD.draining_at IS NOT NULL AND NEW.draining_at IS NULL)
        )
      );

      SELECT EXISTS (
        SELECT 1 FROM public.agents AS agent
        JOIN public.runtime_partitions AS partition
          ON partition.partition_id = NEW.coordination_partition_id
         AND partition.partition_id = public.runtime_partition_for('user:' || agent.user_id)
        JOIN public.runtime_node_incarnations AS node
          ON node.id = NEW.coordination_node_incarnation_id
         AND node.activation_epoch = NEW.coordination_activation_epoch
         AND node.state = ANY(
               CASE WHEN ready_authority_required THEN ARRAY['ready']::text[]
                    ELSE ARRAY['ready', 'draining']::text[] END)
         AND (NOT ready_authority_required OR node.ready_at IS NOT NULL)
         AND node.lease_expires_at > timezone('UTC', clock_timestamp())
        WHERE agent.id = NEW.agent_id
          AND partition.activation_epoch = NEW.coordination_activation_epoch
          AND partition.ownership_epoch = NEW.coordination_partition_epoch
          AND partition.owner_node_incarnation_id = NEW.coordination_node_incarnation_id
          AND partition.state = ANY(
                CASE WHEN ready_authority_required THEN ARRAY['ready']::text[]
                     ELSE ARRAY['ready', 'draining']::text[] END)
          AND (NOT ready_authority_required OR partition.ready_at IS NOT NULL)
          AND partition.lease_expires_at > timezone('UTC', clock_timestamp())
      ) INTO authority_valid;
      IF NOT authority_valid THEN
        RAISE EXCEPTION 'stale or mismatched partition cannot mutate Agent lease'
          USING ERRCODE = 'check_violation';
      END IF;
      RETURN NEW;
    EXCEPTION WHEN no_data_found THEN
      RAISE EXCEPTION 'runtime coordination protocol row is missing'
        USING ERRCODE = 'check_violation';
    END;
    $function$;
    """)

    execute(
      "DROP TRIGGER IF EXISTS enforce_coordinated_agent_lease_trigger ON public.agent_runtime_leases"
    )

    execute("""
    CREATE TRIGGER enforce_coordinated_agent_lease_trigger
      BEFORE INSERT OR UPDATE OR DELETE ON public.agent_runtime_leases
      FOR EACH ROW EXECUTE FUNCTION public.enforce_coordinated_agent_lease()
    """)

    execute("""
    CREATE OR REPLACE FUNCTION public.enforce_coordinated_effect()
    RETURNS trigger
    LANGUAGE plpgsql
    SET search_path = pg_catalog, public
    AS $function$
    DECLARE
      runtime_protocol_mode text;
      effect_protocol_mode text;
      pending_authority_valid boolean;
      reservation_valid boolean;
      entry_valid boolean;
    BEGIN
      IF current_user IS DISTINCT FROM 'maraithon_runtime' AND NOT (
        current_user = 'maraithon_migrator' AND EXISTS (
          SELECT 1 FROM public.runtime_coordination_protocols
          WHERE name = 'runtime' AND mode = 'dark'
        )
      ) THEN
        RAISE EXCEPTION 'coordinated work mutation requires executor role'
          USING ERRCODE = 'insufficient_privilege';
      END IF;

      -- Fact validation follows the canonical protocol order. Callers acquire
      -- the authoritative row locks before DML; this trigger never introduces
      -- an assignment-to-protocol lock inversion.
      SELECT mode INTO STRICT runtime_protocol_mode
      FROM public.runtime_coordination_protocols
      WHERE name = 'runtime';

      SELECT mode INTO STRICT effect_protocol_mode
      FROM public.effect_execution_protocols
      WHERE name = 'effects';

      IF runtime_protocol_mode = 'dark' AND effect_protocol_mode = 'legacy' THEN
        RETURN NEW;
      ELSIF runtime_protocol_mode <> 'partition_fenced_v1' OR
            effect_protocol_mode <> 'generation_fenced_v1' THEN
        RAISE EXCEPTION 'Effect mutation requires a canonical runtime and Effect protocol pair'
          USING ERRCODE = 'check_violation';
      END IF;

      IF NEW.runtime_owner_generation IS NULL THEN
        IF NEW.status IN ('pending', 'claimed', 'executing', 'cancelling') THEN
          RAISE EXCEPTION 'active exact Effect requires durable runtime ownership'
            USING ERRCODE = 'check_violation';
        END IF;
        RETURN NEW;
      END IF;

      IF NEW.coordination_activation_epoch IS NULL OR
         NEW.coordination_partition_id IS NULL OR
         NEW.coordination_partition_epoch IS NULL OR
         NEW.coordination_node_incarnation_id IS NULL THEN
        RAISE EXCEPTION 'exact Effect requires partition incarnation authority'
          USING ERRCODE = 'check_violation';
      END IF;

      IF TG_OP = 'INSERT' OR
         (TG_OP = 'UPDATE' AND OLD.status = 'pending' AND NEW.status = 'pending') THEN
        SELECT EXISTS (
          SELECT 1
          FROM public.agent_runtime_leases AS lease
          JOIN public.runtime_partitions AS partition
            ON partition.partition_id = lease.coordination_partition_id
           AND partition.activation_epoch = lease.coordination_activation_epoch
           AND partition.ownership_epoch = lease.coordination_partition_epoch
           AND partition.owner_node_incarnation_id = lease.coordination_node_incarnation_id
           AND partition.state = 'ready' AND partition.ready_at IS NOT NULL
           AND partition.lease_expires_at > timezone('UTC', clock_timestamp())
          JOIN public.runtime_node_incarnations AS node
            ON node.id = lease.coordination_node_incarnation_id
           AND node.activation_epoch = lease.coordination_activation_epoch
           AND node.state = 'ready' AND node.ready_at IS NOT NULL
           AND node.lease_expires_at > timezone('UTC', clock_timestamp())
          WHERE lease.agent_id = NEW.agent_id
            AND lease.owner_token = NEW.runtime_owner_generation
            AND lease.ready_at IS NOT NULL AND lease.draining_at IS NULL
            AND lease.lease_until > timezone('UTC', clock_timestamp())
            AND lease.coordination_activation_epoch = NEW.coordination_activation_epoch
            AND lease.coordination_partition_id = NEW.coordination_partition_id
            AND lease.coordination_partition_epoch = NEW.coordination_partition_epoch
            AND lease.coordination_node_incarnation_id = NEW.coordination_node_incarnation_id
        ) INTO pending_authority_valid;
        IF NOT pending_authority_valid THEN
          RAISE EXCEPTION 'exact pending Effect lacks a live ready Agent partition authority'
            USING ERRCODE = 'check_violation';
        END IF;
      END IF;

      IF TG_OP = 'UPDATE' AND OLD.status = 'pending' AND NEW.status = 'claimed' THEN
        SELECT EXISTS (
          SELECT 1 FROM public.runtime_task_assignments AS assignment
          JOIN public.runtime_partitions AS partition
            ON partition.partition_id = assignment.partition_id
           AND partition.activation_epoch = assignment.activation_epoch
           AND partition.ownership_epoch = assignment.partition_epoch
           AND partition.owner_node_incarnation_id = assignment.node_incarnation_id
           AND partition.state = 'ready' AND partition.ready_at IS NOT NULL
           AND partition.lease_expires_at > timezone('UTC', clock_timestamp())
          JOIN public.runtime_node_incarnations AS node
            ON node.id = assignment.node_incarnation_id
           AND node.activation_epoch = assignment.activation_epoch
           AND node.state = 'ready' AND node.ready_at IS NOT NULL
           AND node.lease_expires_at > timezone('UTC', clock_timestamp())
          JOIN public.agent_runtime_leases AS lease
            ON lease.agent_id = NEW.agent_id
           AND lease.owner_token = NEW.runtime_owner_generation
           AND lease.ready_at IS NOT NULL AND lease.draining_at IS NULL
           AND lease.lease_until > timezone('UTC', clock_timestamp())
           AND lease.coordination_activation_epoch = assignment.activation_epoch
           AND lease.coordination_partition_id = assignment.partition_id
           AND lease.coordination_partition_epoch = assignment.partition_epoch
           AND lease.coordination_node_incarnation_id = assignment.node_incarnation_id
          WHERE assignment.id = NEW.coordination_task_assignment_id
            AND assignment.work_kind = 'effect' AND assignment.work_id = NEW.id
            AND assignment.claim_token = NEW.claim_token
            AND assignment.activation_epoch = NEW.coordination_activation_epoch
            AND assignment.partition_id = NEW.coordination_partition_id
            AND assignment.partition_epoch = NEW.coordination_partition_epoch
            AND assignment.node_incarnation_id = NEW.coordination_node_incarnation_id
            AND assignment.supervisor_id = NEW.claim_supervisor_id
            AND assignment.local_task_id = NEW.claim_task_id
            AND assignment.state = 'reserved'
            AND assignment.provider_boundary = 'not_entered'
            AND assignment.lease_expires_at > timezone('UTC', clock_timestamp())
        ) INTO reservation_valid;
        IF NOT reservation_valid THEN
          RAISE EXCEPTION 'Effect claim is not coupled to an exact supervised task reservation'
            USING ERRCODE = 'check_violation';
        END IF;
      ELSIF TG_OP = 'UPDATE' AND OLD.status = 'claimed' AND NEW.status = 'executing' THEN
        SELECT EXISTS (
          SELECT 1 FROM public.runtime_task_assignments AS assignment
          JOIN public.runtime_partitions AS partition
            ON partition.partition_id = assignment.partition_id
           AND partition.activation_epoch = assignment.activation_epoch
           AND partition.ownership_epoch = assignment.partition_epoch
           AND partition.owner_node_incarnation_id = assignment.node_incarnation_id
           AND partition.state = 'ready' AND partition.ready_at IS NOT NULL
           AND partition.lease_expires_at > timezone('UTC', clock_timestamp())
          JOIN public.runtime_node_incarnations AS node
            ON node.id = assignment.node_incarnation_id
           AND node.activation_epoch = assignment.activation_epoch
           AND node.state = 'ready' AND node.ready_at IS NOT NULL
           AND node.lease_expires_at > timezone('UTC', clock_timestamp())
          JOIN public.agent_runtime_leases AS lease
            ON lease.agent_id = NEW.agent_id
           AND lease.owner_token = NEW.runtime_owner_generation
           AND lease.ready_at IS NOT NULL AND lease.draining_at IS NULL
           AND lease.lease_until > timezone('UTC', clock_timestamp())
           AND lease.coordination_activation_epoch = assignment.activation_epoch
           AND lease.coordination_partition_id = assignment.partition_id
           AND lease.coordination_partition_epoch = assignment.partition_epoch
           AND lease.coordination_node_incarnation_id = assignment.node_incarnation_id
          WHERE assignment.id = NEW.coordination_task_assignment_id
            AND assignment.work_kind = 'effect' AND assignment.work_id = NEW.id
            AND assignment.claim_token = NEW.claim_token
            AND assignment.activation_epoch = NEW.coordination_activation_epoch
            AND assignment.partition_id = NEW.coordination_partition_id
            AND assignment.partition_epoch = NEW.coordination_partition_epoch
            AND assignment.node_incarnation_id = NEW.coordination_node_incarnation_id
            AND assignment.supervisor_id = NEW.claim_supervisor_id
            AND assignment.local_task_id = NEW.claim_task_id
            AND assignment.state = 'running'
            AND assignment.provider_boundary = 'entered'
            AND assignment.lease_expires_at > timezone('UTC', clock_timestamp())
        ) INTO entry_valid;
        IF NOT entry_valid THEN
          RAISE EXCEPTION 'Effect provider entry lacks a ready running exact task'
            USING ERRCODE = 'check_violation';
        END IF;
      ELSIF TG_OP = 'UPDATE' AND OLD.status IN ('claimed', 'executing', 'cancelling') AND
            NEW.status IN ('claimed', 'executing', 'cancelling', 'pending',
                           'completed', 'failed', 'cancelled') THEN
        IF NOT public.runtime_task_authority_valid(
          OLD.coordination_task_assignment_id, OLD.coordination_activation_epoch,
          OLD.coordination_partition_id, OLD.coordination_partition_epoch,
          OLD.coordination_node_incarnation_id, OLD.claim_token) AND NOT EXISTS (
            SELECT 1 FROM public.runtime_task_assignments AS terminal_assignment
            WHERE terminal_assignment.id = OLD.coordination_task_assignment_id
              AND terminal_assignment.activation_epoch = OLD.coordination_activation_epoch
              AND terminal_assignment.claim_token = OLD.claim_token
              AND terminal_assignment.node_incarnation_id = OLD.coordination_node_incarnation_id
              AND terminal_assignment.supervisor_id = OLD.claim_supervisor_id
              AND terminal_assignment.local_task_id = OLD.claim_task_id
              AND terminal_assignment.state IN ('settled', 'outcome_ambiguous')
          ) THEN
          RAISE EXCEPTION 'stale Effect task cannot mutate after partition epoch loss'
            USING ERRCODE = 'check_violation';
        END IF;
      END IF;

      IF TG_OP = 'UPDATE' AND OLD.coordination_activation_epoch IS NOT NULL AND (
        NEW.coordination_activation_epoch IS DISTINCT FROM OLD.coordination_activation_epoch OR
        NEW.coordination_partition_id IS DISTINCT FROM OLD.coordination_partition_id OR
        NEW.coordination_partition_epoch IS DISTINCT FROM OLD.coordination_partition_epoch OR
        NEW.coordination_node_incarnation_id IS DISTINCT FROM OLD.coordination_node_incarnation_id
      ) THEN
        RAISE EXCEPTION 'Effect coordination incarnation is immutable'
          USING ERRCODE = 'check_violation';
      END IF;

      IF TG_OP = 'UPDATE' AND OLD.coordination_task_assignment_id IS NOT NULL AND
         NEW.coordination_task_assignment_id IS DISTINCT FROM OLD.coordination_task_assignment_id AND
         NOT (OLD.status IN ('claimed', 'executing', 'cancelling') AND NEW.status = 'pending' AND
              NEW.coordination_task_assignment_id IS NULL) THEN
        RAISE EXCEPTION 'Effect task assignment incarnation is immutable'
          USING ERRCODE = 'check_violation';
      END IF;

      RETURN NEW;
    EXCEPTION WHEN no_data_found THEN
      RAISE EXCEPTION 'runtime or Effect protocol row is missing'
        USING ERRCODE = 'check_violation';
    END;
    $function$;
    """)

    execute("DROP TRIGGER IF EXISTS enforce_coordinated_effect_trigger ON public.effects")

    execute("""
    CREATE TRIGGER enforce_coordinated_effect_trigger
      BEFORE INSERT OR UPDATE ON public.effects
      FOR EACH ROW EXECUTE FUNCTION public.enforce_coordinated_effect()
    """)

    execute("""
    CREATE OR REPLACE FUNCTION public.enforce_effect_assignment_final_pair()
    RETURNS trigger
    LANGUAGE plpgsql
    SET search_path = pg_catalog, public
    AS $function$
    DECLARE
      runtime_protocol_mode text;
      effect_protocol_mode text;
      effect_id uuid;
      effect_row record;
      assignment_row record;
      pair_valid boolean;
    BEGIN
      SELECT mode INTO STRICT runtime_protocol_mode
      FROM public.runtime_coordination_protocols
      WHERE name = 'runtime';

      SELECT mode INTO STRICT effect_protocol_mode
      FROM public.effect_execution_protocols
      WHERE name = 'effects';

      IF runtime_protocol_mode = 'dark' AND effect_protocol_mode = 'legacy' THEN
        RETURN NEW;
      ELSIF runtime_protocol_mode <> 'partition_fenced_v1' OR
            effect_protocol_mode <> 'generation_fenced_v1' THEN
        RAISE EXCEPTION 'Effect assignment proof requires a canonical protocol pair'
          USING ERRCODE = 'check_violation';
      END IF;

      IF TG_RELID = 'public.runtime_task_assignments'::regclass AND
         NEW.work_kind <> 'effect' THEN
        RETURN NEW;
      END IF;

      effect_id := CASE
        WHEN TG_RELID = 'public.effects'::regclass THEN NEW.id
        ELSE NEW.work_id
      END;

      SELECT * INTO effect_row
      FROM public.effects
      WHERE id = effect_id;

      IF NOT FOUND THEN
        RAISE EXCEPTION 'Effect assignment final proof is missing its Effect'
          USING ERRCODE = 'check_violation';
      END IF;

      IF effect_row.runtime_owner_generation IS NULL THEN
        IF EXISTS (
          SELECT 1 FROM public.runtime_task_assignments AS active_assignment
          WHERE active_assignment.work_kind = 'effect'
            AND active_assignment.work_id = effect_row.id
            AND active_assignment.state IN (
              'reserved', 'running', 'termination_requested', 'termination_proven'
            )
        ) THEN
          RAISE EXCEPTION 'uncoordinated Effect cannot retain active task authority'
            USING ERRCODE = 'check_violation';
        END IF;
        RETURN NEW;
      END IF;

      IF effect_row.status = 'pending' THEN
        IF effect_row.coordination_task_assignment_id IS NOT NULL OR EXISTS (
          SELECT 1 FROM public.runtime_task_assignments AS active_assignment
          WHERE active_assignment.work_kind = 'effect'
            AND active_assignment.work_id = effect_row.id
            AND active_assignment.state IN (
              'reserved', 'running', 'termination_requested', 'termination_proven'
            )
        ) THEN
          RAISE EXCEPTION 'pending Effect cannot retain active task authority'
            USING ERRCODE = 'check_violation';
        END IF;

        IF TG_RELID = 'public.runtime_task_assignments'::regclass AND
           NEW.state NOT IN ('settled', 'outcome_ambiguous') THEN
          RAISE EXCEPTION 'active Effect assignment must be linked by its Effect'
            USING ERRCODE = 'check_violation';
        END IF;
        RETURN NEW;
      END IF;

      IF effect_row.coordination_task_assignment_id IS NULL THEN
        RAISE EXCEPTION 'active or terminal coordinated Effect is missing its assignment'
          USING ERRCODE = 'check_violation';
      END IF;

      SELECT * INTO assignment_row
      FROM public.runtime_task_assignments
      WHERE id = effect_row.coordination_task_assignment_id;

      IF NOT FOUND THEN
        RAISE EXCEPTION 'Effect assignment final proof is missing its task assignment'
          USING ERRCODE = 'check_violation';
      END IF;

      IF assignment_row.work_kind <> 'effect' OR
         assignment_row.work_id IS DISTINCT FROM effect_row.id OR
         assignment_row.claim_token IS DISTINCT FROM effect_row.claim_token OR
         assignment_row.activation_epoch IS DISTINCT FROM effect_row.coordination_activation_epoch OR
         assignment_row.partition_id IS DISTINCT FROM effect_row.coordination_partition_id OR
         assignment_row.partition_epoch IS DISTINCT FROM effect_row.coordination_partition_epoch OR
         assignment_row.node_incarnation_id IS DISTINCT FROM effect_row.coordination_node_incarnation_id OR
         assignment_row.supervisor_id IS DISTINCT FROM effect_row.claim_supervisor_id OR
         assignment_row.local_task_id IS DISTINCT FROM effect_row.claim_task_id THEN
        RAISE EXCEPTION 'Effect and task assignment identities do not match'
          USING ERRCODE = 'check_violation';
      END IF;

      pair_valid := CASE effect_row.status
        WHEN 'claimed' THEN
          assignment_row.state IN ('reserved', 'running') AND
          assignment_row.provider_boundary = 'not_entered'
        WHEN 'executing' THEN
          assignment_row.state = 'running' AND
          assignment_row.provider_boundary = 'entered'
        WHEN 'cancelling' THEN
          assignment_row.state IN ('termination_requested', 'termination_proven') AND
          assignment_row.provider_boundary IN ('not_entered', 'entered', 'outcome_unknown')
        WHEN 'completed' THEN
          assignment_row.state = 'settled' AND
          assignment_row.provider_boundary = 'outcome_known' AND
          assignment_row.outcome = 'completed'
        WHEN 'failed' THEN
          CASE
            WHEN effect_row.error = 'effect_outcome_ambiguous' THEN
              assignment_row.state = 'outcome_ambiguous' AND
              assignment_row.provider_boundary = 'outcome_unknown' AND
              assignment_row.outcome = 'provider_outcome_ambiguous'
            ELSE
              assignment_row.state = 'settled' AND (
                (assignment_row.provider_boundary = 'outcome_known' AND
                 assignment_row.outcome = 'failed') OR
                (assignment_row.provider_boundary = 'not_entered' AND
                 assignment_row.outcome = 'cancelled_before_provider')
              )
          END
        WHEN 'cancelled' THEN
          assignment_row.state = 'settled' AND
          assignment_row.provider_boundary = 'not_entered' AND
          assignment_row.outcome = 'cancelled_before_provider'
        ELSE false
      END;

      IF pair_valid IS NOT TRUE THEN
        RAISE EXCEPTION 'Effect and task assignment final states are inconsistent'
          USING ERRCODE = 'check_violation';
      END IF;

      RETURN NEW;
    EXCEPTION WHEN no_data_found THEN
      RAISE EXCEPTION 'runtime or Effect protocol row is missing'
        USING ERRCODE = 'check_violation';
    END;
    $function$;
    """)

    execute(
      "DROP TRIGGER IF EXISTS enforce_effect_assignment_final_pair_effect_trigger ON public.effects"
    )

    execute("""
    CREATE CONSTRAINT TRIGGER enforce_effect_assignment_final_pair_effect_trigger
      AFTER INSERT OR UPDATE ON public.effects
      DEFERRABLE INITIALLY DEFERRED
      FOR EACH ROW EXECUTE FUNCTION public.enforce_effect_assignment_final_pair()
    """)

    execute(
      "DROP TRIGGER IF EXISTS enforce_effect_assignment_final_pair_assignment_trigger " <>
        "ON public.runtime_task_assignments"
    )

    execute("""
    CREATE CONSTRAINT TRIGGER enforce_effect_assignment_final_pair_assignment_trigger
      AFTER INSERT OR UPDATE ON public.runtime_task_assignments
      DEFERRABLE INITIALLY DEFERRED
      FOR EACH ROW EXECUTE FUNCTION public.enforce_effect_assignment_final_pair()
    """)

    # Physical Agent termination is a durable evidence protocol. Expiry and
    # topology uncertainty remain fences; only a proof bound to one immutable
    # lease identity permits reconciliation and partition release.
    create_if_not_exists table(:agent_termination_incidents, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :activation_epoch, :uuid
      add :node_incarnation_id, :uuid
      add :partition_id, :smallint
      add :partition_epoch, :bigint
      add :agent_id, :uuid, null: false
      add :lease_token, :uuid, null: false
      add :owner_node, :text, null: false
      add :status, :text, null: false, default: "requested"
      add :request_reason, :text, null: false
      add :requested_at, :utc_datetime_usec, null: false
      add :last_requested_at, :utc_datetime_usec, null: false
      add :request_count, :integer, null: false, default: 1
      add :proof_id, :uuid
      add :proof_kind, :text
      add :proved_at, :utc_datetime_usec
      add :reconcile_attempts, :integer, null: false, default: 0
      add :retry_at, :utc_datetime_usec, null: false
      add :last_error, :text
      add :reconciled_at, :utc_datetime_usec
      add :reconciliation_policy, :map, null: false, default: %{}
      timestamps(type: :utc_datetime_usec)
    end

    create_if_not_exists unique_index(:agent_termination_incidents, [:lease_token],
                           name: :agent_termination_incidents_lease_token_index
                         )

    create_if_not_exists unique_index(:agent_termination_incidents, [:agent_id],
                           where: "status IN ('requested', 'proven')",
                           name: :agent_termination_incidents_open_agent_index
                         )

    create_if_not_exists index(
                           :agent_termination_incidents,
                           [:status, :retry_at, :requested_at, :id],
                           name: :agent_termination_incidents_due_index,
                           where: "status IN ('requested', 'proven')"
                         )

    create_if_not_exists index(
                           :agent_termination_incidents,
                           [
                             :activation_epoch,
                             :node_incarnation_id,
                             :partition_id,
                             :partition_epoch
                           ],
                           name: :agent_termination_incidents_coordination_index
                         )

    execute("""
    ALTER TABLE public.agent_termination_incidents
      DROP CONSTRAINT IF EXISTS agent_termination_incidents_shape,
      ADD CONSTRAINT agent_termination_incidents_shape CHECK (
        octet_length(owner_node) BETWEEN 1 AND 255 AND
        octet_length(request_reason) BETWEEN 1 AND 255 AND
        request_count > 0 AND reconcile_attempts >= 0 AND
        status IN ('requested', 'proven', 'reconciled') AND
        ((activation_epoch IS NULL AND node_incarnation_id IS NULL AND
          partition_id IS NULL AND partition_epoch IS NULL) OR
         (activation_epoch IS NOT NULL AND node_incarnation_id IS NOT NULL AND
          partition_id BETWEEN 0 AND 63 AND partition_epoch > 0)) AND
        ((status = 'requested' AND proof_id IS NULL AND proof_kind IS NULL AND
          proved_at IS NULL AND reconciled_at IS NULL) OR
         (status = 'proven' AND proof_id IS NOT NULL AND proof_kind IS NOT NULL AND
          proved_at IS NOT NULL AND reconciled_at IS NULL) OR
         (status = 'reconciled' AND proof_id IS NOT NULL AND proof_kind IS NOT NULL AND
          proved_at IS NOT NULL AND reconciled_at IS NOT NULL)) AND
        (last_error IS NULL OR octet_length(last_error) BETWEEN 1 AND 255)
      ) NOT VALID
    """)

    execute(
      "ALTER TABLE public.agent_termination_incidents VALIDATE CONSTRAINT agent_termination_incidents_shape"
    )

    create_if_not_exists table(:agent_termination_proofs, primary_key: false) do
      add :id, :uuid, primary_key: true

      add :incident_id,
          references(:agent_termination_incidents,
            column: :id,
            type: :uuid,
            on_delete: :restrict
          ),
          null: false

      add :activation_epoch, :uuid
      add :node_incarnation_id, :uuid
      add :partition_id, :smallint
      add :partition_epoch, :bigint
      add :agent_id, :uuid, null: false
      add :lease_token, :uuid, null: false
      add :proof_kind, :text, null: false
      add :local_pid, :text
      add :monitor_started_at, :utc_datetime_usec
      add :down_reason, :text
      add :evidence_id, :text
      add :evidence_digest, :binary
      add :attestation_signature, :binary
      add :proved_by, :text, null: false
      add :proved_at, :utc_datetime_usec, null: false
      timestamps(type: :utc_datetime_usec)
    end

    create_if_not_exists unique_index(:agent_termination_proofs, [:incident_id],
                           name: :agent_termination_proofs_incident_index
                         )

    create_if_not_exists unique_index(:agent_termination_proofs, [:lease_token],
                           name: :agent_termination_proofs_lease_token_index
                         )

    create_if_not_exists index(
                           :agent_termination_proofs,
                           [:activation_epoch, :node_incarnation_id, :agent_id, :lease_token],
                           name: :agent_termination_proofs_exact_identity_index
                         )

    execute("""
    ALTER TABLE public.agent_termination_proofs
      DROP CONSTRAINT IF EXISTS agent_termination_proofs_shape,
      ADD CONSTRAINT agent_termination_proofs_shape CHECK (
        proof_kind IN ('local_down', 'external_node_destroyed') AND
        octet_length(proved_by) BETWEEN 1 AND 320 AND
        ((activation_epoch IS NULL AND node_incarnation_id IS NULL AND
          partition_id IS NULL AND partition_epoch IS NULL) OR
         (activation_epoch IS NOT NULL AND node_incarnation_id IS NOT NULL AND
          partition_id BETWEEN 0 AND 63 AND partition_epoch > 0)) AND
        ((proof_kind = 'local_down' AND
          octet_length(local_pid) BETWEEN 1 AND 255 AND monitor_started_at IS NOT NULL AND
          octet_length(down_reason) BETWEEN 1 AND 255 AND
          evidence_id IS NULL AND evidence_digest IS NULL AND
          attestation_signature IS NULL) OR
         (proof_kind = 'external_node_destroyed' AND
          activation_epoch IS NOT NULL AND node_incarnation_id IS NOT NULL AND
          local_pid IS NULL AND monitor_started_at IS NULL AND down_reason IS NULL AND
          octet_length(evidence_id) BETWEEN 1 AND 256 AND
          octet_length(evidence_digest) = 32 AND
          octet_length(attestation_signature) = 64))
      ) NOT VALID
    """)

    execute(
      "ALTER TABLE public.agent_termination_proofs VALIDATE CONSTRAINT agent_termination_proofs_shape"
    )

    execute("""
    CREATE OR REPLACE FUNCTION public.enforce_agent_termination_incident()
    RETURNS trigger
    LANGUAGE plpgsql
    SET search_path = pg_catalog, public
    AS $function$
    BEGIN
      IF TG_OP IN ('DELETE', 'TRUNCATE') THEN
        RAISE EXCEPTION 'Agent termination incidents are durable reconciliation facts'
          USING ERRCODE = 'check_violation';
      END IF;

      IF TG_OP = 'UPDATE' THEN
        IF NEW.id IS DISTINCT FROM OLD.id OR
           NEW.activation_epoch IS DISTINCT FROM OLD.activation_epoch OR
           NEW.node_incarnation_id IS DISTINCT FROM OLD.node_incarnation_id OR
           NEW.partition_id IS DISTINCT FROM OLD.partition_id OR
           NEW.partition_epoch IS DISTINCT FROM OLD.partition_epoch OR
           NEW.agent_id IS DISTINCT FROM OLD.agent_id OR
           NEW.lease_token IS DISTINCT FROM OLD.lease_token OR
           NEW.owner_node IS DISTINCT FROM OLD.owner_node OR
           NEW.requested_at IS DISTINCT FROM OLD.requested_at OR
           NEW.inserted_at IS DISTINCT FROM OLD.inserted_at THEN
          RAISE EXCEPTION 'Agent termination incident identity is immutable'
            USING ERRCODE = 'check_violation';
        END IF;

        IF (OLD.status = 'requested' AND NEW.status NOT IN ('requested', 'proven')) OR
           (OLD.status = 'proven' AND NEW.status NOT IN ('proven', 'reconciled')) OR
           (OLD.status = 'reconciled' AND NEW.status <> 'reconciled') THEN
          RAISE EXCEPTION 'invalid Agent termination incident transition'
            USING ERRCODE = 'check_violation';
        END IF;
      END IF;

      RETURN COALESCE(NEW, OLD);
    END;
    $function$;
    """)

    execute(
      "DROP TRIGGER IF EXISTS enforce_agent_termination_incident_trigger ON public.agent_termination_incidents"
    )

    execute("""
    CREATE TRIGGER enforce_agent_termination_incident_trigger
      BEFORE UPDATE OR DELETE ON public.agent_termination_incidents
      FOR EACH ROW EXECUTE FUNCTION public.enforce_agent_termination_incident()
    """)

    execute(
      "DROP TRIGGER IF EXISTS reject_agent_termination_incidents_truncate_trigger ON public.agent_termination_incidents"
    )

    execute("""
    CREATE TRIGGER reject_agent_termination_incidents_truncate_trigger
      BEFORE TRUNCATE ON public.agent_termination_incidents
      FOR EACH STATEMENT EXECUTE FUNCTION public.enforce_agent_termination_incident()
    """)

    execute("""
    CREATE OR REPLACE FUNCTION public.enforce_agent_termination_proof()
    RETURNS trigger
    LANGUAGE plpgsql
    SET search_path = pg_catalog, public
    AS $function$
    DECLARE incident record;
    BEGIN
      IF NOT (
        (NEW.proof_kind = 'local_down' AND current_user = 'maraithon_runtime') OR
        (NEW.proof_kind = 'external_node_destroyed' AND
          current_user = 'maraithon_incident_operator') OR
        (current_user = 'maraithon_migrator' AND EXISTS (
          SELECT 1 FROM public.runtime_coordination_protocols
          WHERE name = 'runtime' AND mode = 'dark'
        ))
      ) THEN
        RAISE EXCEPTION 'Agent termination proof kind is not authorized for current role'
          USING ERRCODE = 'insufficient_privilege';
      END IF;

      IF TG_OP <> 'INSERT' THEN
        RAISE EXCEPTION 'Agent termination proof is append-only'
          USING ERRCODE = 'check_violation';
      END IF;

      SELECT * INTO STRICT incident
      FROM public.agent_termination_incidents
      WHERE id = NEW.incident_id
      FOR UPDATE;

      IF incident.status <> 'requested' OR
         NEW.activation_epoch IS DISTINCT FROM incident.activation_epoch OR
         NEW.node_incarnation_id IS DISTINCT FROM incident.node_incarnation_id OR
         NEW.partition_id IS DISTINCT FROM incident.partition_id OR
         NEW.partition_epoch IS DISTINCT FROM incident.partition_epoch OR
         NEW.agent_id IS DISTINCT FROM incident.agent_id OR
         NEW.lease_token IS DISTINCT FROM incident.lease_token THEN
        RAISE EXCEPTION 'Agent termination proof identity does not match its incident'
          USING ERRCODE = 'check_violation';
      END IF;

      IF NEW.proof_kind = 'local_down' AND
         current_setting('maraithon.agent_local_down_proof', true)
           IS DISTINCT FROM NEW.incident_id::text THEN
        RAISE EXCEPTION 'local Agent termination proof requires the exact monitor barrier'
          USING ERRCODE = 'check_violation';
      ELSIF NEW.proof_kind = 'external_node_destroyed' AND
            current_setting('maraithon.agent_external_termination_attestation', true)
              IS DISTINCT FROM encode(NEW.evidence_digest, 'hex') THEN
        RAISE EXCEPTION 'external Agent termination proof requires signed operator attestation'
          USING ERRCODE = 'check_violation';
      END IF;

      RETURN NEW;
    EXCEPTION WHEN no_data_found THEN
      RAISE EXCEPTION 'Agent termination incident is missing'
        USING ERRCODE = 'check_violation';
    END;
    $function$;
    """)

    execute(
      "DROP TRIGGER IF EXISTS enforce_agent_termination_proof_trigger ON public.agent_termination_proofs"
    )

    execute("""
    CREATE TRIGGER enforce_agent_termination_proof_trigger
      BEFORE INSERT OR UPDATE OR DELETE ON public.agent_termination_proofs
      FOR EACH ROW EXECUTE FUNCTION public.enforce_agent_termination_proof()
    """)

    execute(
      "DROP TRIGGER IF EXISTS reject_agent_termination_proofs_truncate_trigger ON public.agent_termination_proofs"
    )

    execute("""
    CREATE TRIGGER reject_agent_termination_proofs_truncate_trigger
      BEFORE TRUNCATE ON public.agent_termination_proofs
      FOR EACH STATEMENT EXECUTE FUNCTION public.enforce_agent_termination_proof()
    """)

    # The v1 partition trigger only counted live Agent leases.  This additional
    # trigger makes every exact lease row (including an expired ambiguous row)
    # a release barrier until proof-gated reconciliation removes that row.
    execute("""
    CREATE OR REPLACE FUNCTION public.enforce_agent_termination_partition_release()
    RETURNS trigger
    LANGUAGE plpgsql
    SET search_path = pg_catalog, public
    AS $function$
    BEGIN
      IF OLD.state IN ('draining', 'blocked') AND NEW.state = 'unassigned' AND EXISTS (
        SELECT 1 FROM public.agent_runtime_leases AS lease
        WHERE lease.coordination_activation_epoch = OLD.activation_epoch
          AND lease.coordination_partition_id = OLD.partition_id
          AND lease.coordination_partition_epoch = OLD.ownership_epoch
          AND lease.coordination_node_incarnation_id = OLD.owner_node_incarnation_id
      ) THEN
        RAISE EXCEPTION 'partition cannot move before exact Agent termination proof'
          USING ERRCODE = 'check_violation';
      END IF;
      RETURN NEW;
    END;
    $function$;
    """)

    execute(
      "DROP TRIGGER IF EXISTS enforce_agent_termination_partition_release_trigger ON public.runtime_partitions"
    )

    execute("""
    CREATE TRIGGER enforce_agent_termination_partition_release_trigger
      BEFORE UPDATE ON public.runtime_partitions
      FOR EACH ROW EXECUTE FUNCTION public.enforce_agent_termination_partition_release()
    """)

    execute("""
    CREATE OR REPLACE FUNCTION public.runtime_catalog_table_fingerprint(requested regclass)
    RETURNS text
    LANGUAGE sql
    STABLE
    STRICT
    SET search_path = pg_catalog, public
    AS $function$
      SELECT encode(public.digest(convert_to(pg_catalog.jsonb_build_object(
        'schema', namespace.nspname,
        'schema_owner', schema_owner.rolname,
        'schema_acl', namespace.nspacl,
        'relation', relation.relname,
        'kind', relation.relkind,
        'persistence', relation.relpersistence,
        'owner', owner_row.rolname,
        'acl', relation.relacl,
        'row_security', relation.relrowsecurity,
        'force_row_security', relation.relforcerowsecurity,
        'replica_identity', relation.relreplident,
        'options', relation.reloptions,
        'tablespace', tablespace.spcname,
        'columns', COALESCE((
          SELECT pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
            'position', attribute.attnum,
            'name', attribute.attname,
            'type', pg_catalog.format_type(attribute.atttypid, attribute.atttypmod),
            'not_null', attribute.attnotnull,
            'identity', attribute.attidentity,
            'generated', attribute.attgenerated,
            'acl', attribute.attacl,
            'storage', attribute.attstorage,
            'compression', attribute.attcompression,
            'default', pg_catalog.pg_get_expr(default_row.adbin, default_row.adrelid, true),
            'collation_schema', collation_namespace.nspname,
            'collation', collation_row.collname
          ) ORDER BY attribute.attnum)
          FROM pg_catalog.pg_attribute AS attribute
          LEFT JOIN pg_catalog.pg_attrdef AS default_row
            ON default_row.adrelid = attribute.attrelid AND default_row.adnum = attribute.attnum
          LEFT JOIN pg_catalog.pg_collation AS collation_row
            ON collation_row.oid = attribute.attcollation
          LEFT JOIN pg_catalog.pg_namespace AS collation_namespace
            ON collation_namespace.oid = collation_row.collnamespace
          WHERE attribute.attrelid = relation.oid AND attribute.attnum > 0
            AND NOT attribute.attisdropped
        ), '[]'::jsonb),
        'constraints', COALESCE((
          SELECT pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
            'name', constraint_row.conname,
            'type', constraint_row.contype,
            'deferrable', constraint_row.condeferrable,
            'deferred', constraint_row.condeferred,
            'validated', constraint_row.convalidated,
            'local', constraint_row.conislocal,
            'inherit_count', constraint_row.coninhcount,
            'no_inherit', constraint_row.connoinherit,
            'parent', parent_constraint.conname,
            'index', constraint_index.relname,
            'definition', pg_catalog.pg_get_constraintdef(constraint_row.oid, true)
          ) ORDER BY constraint_row.conname)
          FROM pg_catalog.pg_constraint AS constraint_row
          LEFT JOIN pg_catalog.pg_constraint AS parent_constraint
            ON parent_constraint.oid = constraint_row.conparentid
          LEFT JOIN pg_catalog.pg_class AS constraint_index
            ON constraint_index.oid = constraint_row.conindid
          WHERE constraint_row.conrelid = relation.oid
        ), '[]'::jsonb),
        'indexes', COALESCE((
          SELECT pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
            'name', index_relation.relname,
            'definition', pg_catalog.pg_get_indexdef(index_relation.oid),
            'owner', index_owner.rolname,
            'acl', index_relation.relacl,
            'options', index_relation.reloptions,
            'tablespace', index_tablespace.spcname,
            'unique', index_row.indisunique,
            'primary', index_row.indisprimary,
            'exclusion', index_row.indisexclusion,
            'immediate', index_row.indimmediate,
            'clustered', index_row.indisclustered,
            'replica_identity', index_row.indisreplident,
            'nulls_not_distinct', index_row.indnullsnotdistinct,
            'valid', index_row.indisvalid,
            'ready', index_row.indisready,
            'live', index_row.indislive
          ) ORDER BY index_relation.relname)
          FROM pg_catalog.pg_index AS index_row
          JOIN pg_catalog.pg_class AS index_relation
            ON index_relation.oid = index_row.indexrelid
          JOIN pg_catalog.pg_roles AS index_owner
            ON index_owner.oid = index_relation.relowner
          LEFT JOIN pg_catalog.pg_tablespace AS index_tablespace
            ON index_tablespace.oid = index_relation.reltablespace
          WHERE index_row.indrelid = relation.oid
        ), '[]'::jsonb),
        'triggers', COALESCE((
          SELECT pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
            'name', trigger_row.tgname,
            'definition', pg_catalog.pg_get_triggerdef(trigger_row.oid, true),
            'enabled', trigger_row.tgenabled,
            'type', trigger_row.tgtype,
            'function', trigger_function.oid::regprocedure::text
          ) ORDER BY trigger_row.tgname)
          FROM pg_catalog.pg_trigger AS trigger_row
          JOIN pg_catalog.pg_proc AS trigger_function
            ON trigger_function.oid = trigger_row.tgfoid
          WHERE trigger_row.tgrelid = relation.oid AND NOT trigger_row.tgisinternal
        ), '[]'::jsonb),
        'rules', COALESCE((
          SELECT pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
            'name', rewrite_row.rulename,
            'enabled', rewrite_row.ev_enabled,
            'definition', pg_catalog.pg_get_ruledef(rewrite_row.oid, true)
          ) ORDER BY rewrite_row.rulename)
          FROM pg_catalog.pg_rewrite AS rewrite_row
          WHERE rewrite_row.ev_class = relation.oid AND rewrite_row.rulename <> '_RETURN'
        ), '[]'::jsonb),
        'sequence', CASE WHEN relation.relkind = 'S' THEN (
          SELECT pg_catalog.jsonb_build_object(
            'type', pg_catalog.format_type(sequence_row.seqtypid, NULL),
            'start', sequence_row.seqstart,
            'increment', sequence_row.seqincrement,
            'maximum', sequence_row.seqmax,
            'minimum', sequence_row.seqmin,
            'cache', sequence_row.seqcache,
            'cycle', sequence_row.seqcycle
          ) FROM pg_catalog.pg_sequence AS sequence_row
          WHERE sequence_row.seqrelid = relation.oid
        ) ELSE NULL END
      )::text, 'UTF8'), 'sha256'), 'hex')
      FROM pg_catalog.pg_class AS relation
      JOIN pg_catalog.pg_namespace AS namespace ON namespace.oid = relation.relnamespace
      JOIN pg_catalog.pg_roles AS schema_owner ON schema_owner.oid = namespace.nspowner
      JOIN pg_catalog.pg_roles AS owner_row ON owner_row.oid = relation.relowner
      LEFT JOIN pg_catalog.pg_tablespace AS tablespace ON tablespace.oid = relation.reltablespace
      WHERE relation.oid = requested AND namespace.nspname = 'public'
    $function$;
    """)

    execute("""
    CREATE OR REPLACE FUNCTION public.runtime_coordination_catalog_ready_count()
    RETURNS bigint
    LANGUAGE sql
    STABLE
    SET search_path = pg_catalog, public
    AS $function$
      WITH required_functions(function_id) AS (
        VALUES
          ('public.runtime_partition_for(text)'::regprocedure),
          ('public.runtime_coordination_roles_ready()'::regprocedure),
          ('public.runtime_role_topology_fingerprint()'::regprocedure),
          ('public.runtime_coordination_acl_ready()'::regprocedure),
          ('public.runtime_catalog_table_fingerprint(regclass)'::regprocedure),
          ('public.populate_runtime_work_partition()'::regprocedure),
          ('public.enforce_effect_activation_evidence()'::regprocedure),
          ('public.enforce_runtime_coordination_protocol()'::regprocedure),
          ('public.reject_runtime_coordination_evidence_mutation()'::regprocedure),
          ('public.enforce_runtime_partition_transition()'::regprocedure),
          ('public.enforce_runtime_node_incarnation()'::regprocedure),
          ('public.enforce_runtime_leader_authority()'::regprocedure),
          ('public.enforce_runtime_partition_authority()'::regprocedure),
          ('public.enforce_runtime_task_assignment()'::regprocedure),
          ('public.enforce_runtime_task_outcome_evidence()'::regprocedure),
          ('public.enforce_runtime_task_termination_proof()'::regprocedure),
          ('public.runtime_task_authority_valid(uuid,uuid,smallint,bigint,uuid,uuid)'::regprocedure),
          ('public.enforce_runtime_work_role()'::regprocedure),
          ('public.enforce_coordinated_background_job()'::regprocedure),
          ('public.enforce_coordinated_scheduled_job()'::regprocedure),
          ('public.enforce_coordinated_agent_directive()'::regprocedure),
          ('public.enforce_coordinated_agent_lease()'::regprocedure),
          ('public.enforce_coordinated_effect()'::regprocedure),
          ('public.enforce_effect_assignment_final_pair()'::regprocedure),
          ('public.enforce_agent_termination_incident()'::regprocedure),
          ('public.enforce_agent_termination_proof()'::regprocedure),
          ('public.enforce_agent_termination_partition_release()'::regprocedure),
          ('public.runtime_coordination_catalog_ready_count()'::regprocedure)
      ), function_matches AS (
        SELECT count(*) AS count
        FROM required_functions AS required
        JOIN pg_catalog.pg_proc AS function_row ON function_row.oid = required.function_id
        JOIN pg_catalog.pg_language AS language_row ON language_row.oid = function_row.prolang
        JOIN pg_catalog.pg_roles AS owner_row ON owner_row.oid = function_row.proowner
        JOIN public.runtime_coordination_manifests AS manifest ON manifest.name = 'runtime'
        WHERE NOT function_row.prosecdef
          AND function_row.proconfig = ARRAY['search_path=pg_catalog, public']::text[]
          AND language_row.lanname IN ('sql', 'plpgsql')
          AND manifest.function_fingerprints ->> function_row.proname =
            encode(public.digest(convert_to(pg_catalog.jsonb_build_object(
              'definition', pg_catalog.pg_get_functiondef(function_row.oid),
              'owner', owner_row.rolname,
              'acl', function_row.proacl
            )::text, 'UTF8'), 'sha256'), 'hex')
      ), required_constraints(relation_id, constraint_name) AS (
        VALUES
          ('public.runtime_coordination_protocols'::regclass, 'runtime_coordination_protocol_shape'),
          ('public.runtime_coordination_manifests'::regclass, 'runtime_coordination_manifest_singleton'),
          ('public.effect_execution_protocols'::regclass, 'effect_activation_evidence_shape'),
          ('public.runtime_node_incarnations'::regclass, 'runtime_node_incarnations_shape'),
          ('public.runtime_leader_authorities'::regclass, 'runtime_leader_authorities_shape'),
          ('public.runtime_partitions'::regclass, 'runtime_partitions_shape'),
          ('public.runtime_partition_transitions'::regclass, 'runtime_partition_transitions_shape'),
          ('public.runtime_task_assignments'::regclass, 'runtime_task_assignments_shape'),
          ('public.runtime_task_outcome_evidence'::regclass, 'runtime_task_outcome_evidence_shape'),
          ('public.runtime_task_termination_proofs'::regclass, 'runtime_task_termination_proofs_shape'),
          ('public.runtime_tenant_fairness'::regclass, 'runtime_tenant_fairness_bounds'),
          ('public.runtime_partition_rebalance_requests'::regclass, 'runtime_partition_rebalance_requests_shape'),
          ('public.background_jobs'::regclass, 'background_jobs_partition_shape'),
          ('public.scheduled_jobs'::regclass, 'scheduled_jobs_partition_shape'),
          ('public.agent_termination_incidents'::regclass, 'agent_termination_incidents_shape'),
          ('public.agent_termination_proofs'::regclass, 'agent_termination_proofs_shape')
      ), constraint_matches AS (
        SELECT count(*) AS count
        FROM required_constraints AS required
        JOIN pg_catalog.pg_constraint AS constraint_row
          ON constraint_row.conrelid = required.relation_id
         AND constraint_row.conname = required.constraint_name
         AND constraint_row.contype = 'c' AND constraint_row.convalidated
        JOIN public.runtime_coordination_manifests AS manifest ON manifest.name = 'runtime'
        WHERE manifest.constraint_fingerprints ->> required.constraint_name =
              encode(public.digest(convert_to(regexp_replace(pg_catalog.pg_get_constraintdef(constraint_row.oid, true), ' NOT VALID$', ''), 'UTF8'), 'sha256'), 'hex')
      ), required_triggers(relation_id, trigger_name) AS (
        VALUES
          ('public.runtime_coordination_protocols'::regclass, 'enforce_runtime_coordination_protocol_trigger'),
          ('public.runtime_coordination_protocols'::regclass, 'reject_runtime_coordination_protocol_truncate_trigger'),
          ('public.effect_execution_protocols'::regclass, 'enforce_effect_activation_evidence_trigger'),
          ('public.runtime_coordination_manifests'::regclass, 'reject_runtime_coordination_manifests_mutation_trigger'),
          ('public.runtime_coordination_manifests'::regclass, 'reject_runtime_coordination_manifests_truncate_trigger'),
          ('public.runtime_task_termination_proofs'::regclass, 'reject_runtime_task_termination_proofs_mutation_trigger'),
          ('public.runtime_task_termination_proofs'::regclass, 'reject_runtime_task_termination_proofs_truncate_trigger'),
          ('public.runtime_partition_transitions'::regclass, 'enforce_runtime_partition_transition_trigger'),
          ('public.runtime_partition_transitions'::regclass, 'reject_runtime_partition_transitions_truncate_trigger'),
          ('public.runtime_node_incarnations'::regclass, 'enforce_runtime_node_incarnation_trigger'),
          ('public.runtime_leader_authorities'::regclass, 'enforce_runtime_leader_authority_trigger'),
          ('public.runtime_partitions'::regclass, 'enforce_runtime_partition_authority_trigger'),
          ('public.runtime_task_assignments'::regclass, 'enforce_runtime_task_assignment_trigger'),
          ('public.runtime_task_outcome_evidence'::regclass, 'enforce_runtime_task_outcome_evidence_trigger'),
          ('public.runtime_task_outcome_evidence'::regclass, 'reject_runtime_task_outcome_evidence_truncate_trigger'),
          ('public.runtime_task_termination_proofs'::regclass, 'enforce_runtime_task_termination_proof_trigger'),
          ('public.background_jobs'::regclass, 'enforce_coordinated_background_job_trigger'),
          ('public.scheduled_jobs'::regclass, 'enforce_coordinated_scheduled_job_trigger'),
          ('public.agent_runs'::regclass, 'enforce_agent_runs_runtime_role_trigger'),
          ('public.agent_run_steps'::regclass, 'enforce_agent_run_steps_runtime_role_trigger'),
        ('public.agent_directives'::regclass, 'enforce_coordinated_agent_directive_trigger'),
          ('public.agent_runtime_leases'::regclass, 'enforce_coordinated_agent_lease_trigger'),
          ('public.effects'::regclass, 'enforce_coordinated_effect_trigger'),
          ('public.effects'::regclass, 'enforce_effect_assignment_final_pair_effect_trigger'),
          ('public.runtime_task_assignments'::regclass,
           'enforce_effect_assignment_final_pair_assignment_trigger'),
          ('public.agent_termination_incidents'::regclass, 'enforce_agent_termination_incident_trigger'),
          ('public.agent_termination_incidents'::regclass, 'reject_agent_termination_incidents_truncate_trigger'),
          ('public.agent_termination_proofs'::regclass, 'enforce_agent_termination_proof_trigger'),
          ('public.agent_termination_proofs'::regclass, 'reject_agent_termination_proofs_truncate_trigger'),
          ('public.runtime_partitions'::regclass, 'enforce_agent_termination_partition_release_trigger')
      ), trigger_matches AS (
        SELECT count(*) AS count
        FROM required_triggers AS required
        JOIN pg_catalog.pg_trigger AS trigger_row
          ON trigger_row.tgrelid = required.relation_id
         AND trigger_row.tgname = required.trigger_name
         AND NOT trigger_row.tgisinternal AND trigger_row.tgenabled IN ('O', 'A')
        JOIN public.runtime_coordination_manifests AS manifest ON manifest.name = 'runtime'
        WHERE manifest.trigger_fingerprints ->> required.trigger_name =
              encode(public.digest(convert_to(pg_catalog.pg_get_triggerdef(trigger_row.oid, true), 'UTF8'), 'sha256'), 'hex')
      ), required_indexes(index_name) AS (
        VALUES
          ('runtime_task_assignments_claim_token_index'),
          ('runtime_task_assignments_physical_identity_index'),
          ('runtime_task_assignments_active_work_index'),
          ('runtime_task_outcome_evidence_assignment_index'),
          ('runtime_task_termination_proofs_assignment_index'),
          ('runtime_partition_rebalance_requests_pending_partition_index'),
          ('background_jobs_partition_due_index'),
          ('background_jobs_tenant_active_index'),
          ('scheduled_jobs_partition_due_index'),
          ('agent_runtime_leases_coordination_partition_index'),
          ('effects_coordination_partition_pending_index'),
          ('agent_termination_incidents_lease_token_index'),
          ('agent_termination_incidents_open_agent_index'),
          ('agent_termination_incidents_due_index'),
          ('agent_termination_incidents_coordination_index'),
          ('agent_termination_proofs_incident_index'),
          ('agent_termination_proofs_lease_token_index'),
          ('agent_termination_proofs_exact_identity_index')
      ), index_matches AS (
        SELECT count(*) AS count
        FROM required_indexes AS required
        JOIN pg_catalog.pg_class AS index_relation ON index_relation.relname = required.index_name
        JOIN pg_catalog.pg_namespace AS namespace ON namespace.oid = index_relation.relnamespace
          AND namespace.nspname = 'public'
        JOIN pg_catalog.pg_roles AS index_owner ON index_owner.oid = index_relation.relowner
        JOIN pg_catalog.pg_index AS index_row ON index_row.indexrelid = index_relation.oid
          AND index_row.indisvalid AND index_row.indisready AND index_row.indislive
        JOIN public.runtime_coordination_manifests AS manifest ON manifest.name = 'runtime'
        WHERE manifest.index_fingerprints ->> required.index_name =
              encode(public.digest(convert_to(pg_catalog.jsonb_build_object(
              'definition', pg_catalog.pg_get_indexdef(index_relation.oid),
              'owner', index_owner.rolname,
              'acl', index_relation.relacl
            )::text, 'UTF8'), 'sha256'), 'hex')
      ), required_catalogs(relation_id, relation_name) AS (
        VALUES
          ('public.runtime_coordination_protocols'::regclass, 'runtime_coordination_protocols'),
          ('public.runtime_coordination_manifests'::regclass, 'runtime_coordination_manifests'),
          ('public.schema_migrations'::regclass, 'schema_migrations'),
          ('public.effect_execution_protocols'::regclass, 'effect_execution_protocols'),
          ('public.effect_execution_protocol_manifests'::regclass,
           'effect_execution_protocol_manifests'),
          ('public.effect_termination_attestations'::regclass,
           'effect_termination_attestations'),
          ('public.runtime_node_incarnations'::regclass, 'runtime_node_incarnations'),
          ('public.runtime_leader_authorities'::regclass, 'runtime_leader_authorities'),
          ('public.runtime_partitions'::regclass, 'runtime_partitions'),
          ('public.runtime_partition_transitions'::regclass, 'runtime_partition_transitions'),
          ('public.runtime_task_assignments'::regclass, 'runtime_task_assignments'),
          ('public.runtime_task_outcome_evidence'::regclass, 'runtime_task_outcome_evidence'),
          ('public.runtime_task_termination_proofs'::regclass, 'runtime_task_termination_proofs'),
          ('public.runtime_tenant_fairness'::regclass, 'runtime_tenant_fairness'),
          ('public.runtime_partition_rebalance_requests'::regclass, 'runtime_partition_rebalance_requests'),
          ('public.background_jobs'::regclass, 'background_jobs'),
          ('public.scheduled_jobs'::regclass, 'scheduled_jobs'),
          ('public.agent_runtime_leases'::regclass, 'agent_runtime_leases'),
          ('public.agent_directives'::regclass, 'agent_directives'),
          ('public.agent_runs'::regclass, 'agent_runs'),
          ('public.agent_run_steps'::regclass, 'agent_run_steps'),
          ('public.effects'::regclass, 'effects'),
          ('public.agent_termination_incidents'::regclass, 'agent_termination_incidents'),
          ('public.agent_termination_proofs'::regclass, 'agent_termination_proofs')
      ), catalog_matches AS (
        SELECT count(*) AS count
        FROM required_catalogs AS required
        JOIN public.runtime_coordination_manifests AS manifest ON manifest.name = 'runtime'
        WHERE manifest.catalog_fingerprints ->> required.relation_name =
              public.runtime_catalog_table_fingerprint(required.relation_id)
      ), topology_matches AS (
        SELECT count(*) AS count
        FROM public.runtime_coordination_manifests AS manifest
        WHERE manifest.name = 'runtime'
          AND manifest.catalog_fingerprints ->> 'role_topology' =
              public.runtime_role_topology_fingerprint()
      )
      SELECT function_matches.count + constraint_matches.count + trigger_matches.count +
             index_matches.count + catalog_matches.count + topology_matches.count
      FROM function_matches, constraint_matches, trigger_matches, index_matches,
           catalog_matches, topology_matches
    $function$;
    """)

    # Roles are cluster-level security principals and must be provisioned before
    # expansion by infrastructure. The migration never creates or links them;
    # the early topology gate prevents a half-secured expansion from being
    # recorded. Activation continuously re-attests the graph and ACLs below.
    execute("""
    DO $block$
    DECLARE
      relation_name text;
      function_name text;
      column_name text;
      grantee_name text;
    BEGIN
      IF public.runtime_coordination_roles_ready() THEN
        REVOKE ALL ON SCHEMA public FROM PUBLIC;
        GRANT USAGE ON SCHEMA public TO
          maraithon_migrator, maraithon_runtime, maraithon_payload_verifier,
          maraithon_incident_operator, maraithon_activation_operator;
        ALTER SCHEMA public OWNER TO maraithon_object_owner;

        FOREACH relation_name IN ARRAY ARRAY[
          'runtime_coordination_protocols', 'runtime_coordination_manifests',
          'runtime_node_incarnations', 'runtime_leader_authorities', 'runtime_partitions',
          'runtime_partition_transitions', 'runtime_task_assignments',
          'runtime_task_outcome_evidence', 'runtime_task_termination_proofs',
          'runtime_tenant_fairness', 'runtime_partition_rebalance_requests'
        ] LOOP
          EXECUTE format('REVOKE ALL ON TABLE public.%I FROM PUBLIC, maraithon_runtime, maraithon_payload_verifier, maraithon_incident_operator, maraithon_activation_operator', relation_name);
          EXECUTE format('GRANT ALL ON TABLE public.%I TO maraithon_migrator', relation_name);
          EXECUTE format('ALTER TABLE public.%I OWNER TO maraithon_object_owner', relation_name);
        END LOOP;

        -- PostgreSQL requires UPDATE privilege for SELECT ... FOR SHARE.
        -- Triggers still reject every runtime-role protocol mutation.
        GRANT SELECT, UPDATE ON TABLE public.runtime_coordination_protocols
          TO maraithon_runtime;
        GRANT SELECT ON TABLE public.runtime_coordination_manifests
          TO maraithon_runtime;
        GRANT SELECT, INSERT, UPDATE ON TABLE public.runtime_node_incarnations
          TO maraithon_runtime;
        GRANT SELECT, UPDATE ON TABLE public.runtime_leader_authorities,
          public.runtime_partitions TO maraithon_runtime;
        GRANT SELECT, INSERT, UPDATE ON TABLE public.runtime_partition_transitions,
          public.runtime_task_assignments, public.runtime_tenant_fairness,
          public.runtime_partition_rebalance_requests TO maraithon_runtime;
        GRANT SELECT, INSERT ON TABLE public.runtime_task_outcome_evidence,
          public.runtime_task_termination_proofs TO maraithon_runtime;

        GRANT SELECT ON TABLE public.runtime_coordination_protocols,
          public.runtime_coordination_manifests, public.runtime_task_assignments,
          public.runtime_task_outcome_evidence, public.runtime_task_termination_proofs
          TO maraithon_payload_verifier;
        -- Exact external proof uses the same canonical FOR SHARE authority
        -- locks; mutation triggers keep the incident role settlement-only.
        GRANT SELECT, UPDATE ON TABLE public.runtime_coordination_protocols,
          public.runtime_node_incarnations, public.runtime_partitions
          TO maraithon_incident_operator;
        GRANT SELECT, UPDATE ON TABLE public.runtime_task_assignments
          TO maraithon_incident_operator;
        GRANT SELECT, INSERT ON TABLE public.runtime_task_termination_proofs
          TO maraithon_incident_operator;
        GRANT SELECT ON TABLE public.runtime_coordination_protocols,
          public.runtime_coordination_manifests TO maraithon_activation_operator;
        GRANT SELECT, UPDATE ON TABLE public.runtime_node_incarnations,
          public.runtime_task_assignments TO maraithon_activation_operator;
        GRANT UPDATE ON TABLE public.runtime_coordination_protocols
          TO maraithon_activation_operator;

        -- The executor is the ordinary application database role. Grant
        -- standard DML across application tables, excluding every protocol,
        -- immutable evidence root, and migration ledger handled explicitly.
        FOR relation_name IN
          SELECT relation.relname
          FROM pg_catalog.pg_class AS relation
          JOIN pg_catalog.pg_namespace AS namespace ON namespace.oid = relation.relnamespace
          WHERE namespace.nspname = 'public' AND relation.relkind IN ('r', 'p')
            AND relation.relname <> ALL(ARRAY[
              'schema_migrations', 'effect_execution_protocols',
              'effect_execution_protocol_manifests', 'effect_termination_attestations',
              'runtime_coordination_protocols', 'runtime_coordination_manifests',
              'runtime_node_incarnations', 'runtime_leader_authorities', 'runtime_partitions',
              'runtime_partition_transitions', 'runtime_task_assignments',
              'runtime_task_outcome_evidence', 'runtime_task_termination_proofs',
              'runtime_tenant_fairness', 'runtime_partition_rebalance_requests',
              'agent_termination_incidents', 'agent_termination_proofs'
            ])
        LOOP
          EXECUTE format('GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE public.%I TO maraithon_runtime', relation_name);
        END LOOP;
        REVOKE ALL ON ALL SEQUENCES IN SCHEMA public FROM PUBLIC,
          maraithon_runtime, maraithon_payload_verifier,
          maraithon_incident_operator, maraithon_activation_operator;
        GRANT ALL ON ALL SEQUENCES IN SCHEMA public TO maraithon_migrator;
        GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO maraithon_runtime;

        -- Preserve existing application ACLs, but place all attested roots
        -- under the non-login owner and add only the canonical group grants.
        REVOKE ALL ON TABLE public.effect_execution_protocols,
          public.effect_execution_protocol_manifests,
          public.effect_termination_attestations
          FROM PUBLIC, maraithon_runtime, maraithon_payload_verifier,
               maraithon_incident_operator, maraithon_activation_operator;

        FOREACH relation_name IN ARRAY ARRAY[
          'effect_execution_protocols', 'effect_execution_protocol_manifests',
          'effect_termination_attestations', 'effects', 'agent_runtime_leases',
          'agent_directives', 'agent_runs', 'agent_run_steps',
          'background_jobs', 'scheduled_jobs', 'agent_termination_incidents',
          'agent_termination_proofs', 'schema_migrations'
        ] LOOP
          EXECUTE format('REVOKE ALL ON TABLE public.%I FROM PUBLIC, maraithon_runtime, maraithon_payload_verifier, maraithon_incident_operator, maraithon_activation_operator', relation_name);
          EXECUTE format('GRANT ALL ON TABLE public.%I TO maraithon_migrator', relation_name);
          EXECUTE format('ALTER TABLE public.%I OWNER TO maraithon_object_owner', relation_name);
        END LOOP;

        FOR relation_name, column_name, grantee_name IN
          SELECT DISTINCT relation.relname, attribute.attname,
                 CASE WHEN privilege.grantee = 0 THEN 'PUBLIC' ELSE grantee.rolname END
          FROM pg_catalog.pg_attribute AS attribute
          JOIN pg_catalog.pg_class AS relation ON relation.oid = attribute.attrelid
          JOIN pg_catalog.pg_namespace AS namespace ON namespace.oid = relation.relnamespace
          CROSS JOIN LATERAL pg_catalog.aclexplode(attribute.attacl) AS privilege
          LEFT JOIN pg_catalog.pg_roles AS grantee ON grantee.oid = privilege.grantee
          WHERE namespace.nspname = 'public' AND attribute.attnum > 0
            AND NOT attribute.attisdropped AND attribute.attacl IS NOT NULL
            AND relation.relname = ANY(ARRAY[
              'runtime_coordination_protocols', 'runtime_coordination_manifests',
              'runtime_node_incarnations', 'runtime_leader_authorities', 'runtime_partitions',
              'runtime_partition_transitions', 'runtime_task_assignments',
              'runtime_task_outcome_evidence', 'runtime_task_termination_proofs',
              'runtime_tenant_fairness', 'runtime_partition_rebalance_requests',
              'effect_execution_protocols', 'effect_execution_protocol_manifests',
              'effect_termination_attestations', 'effects', 'agent_runtime_leases',
              'agent_directives', 'agent_runs', 'agent_run_steps', 'background_jobs',
              'scheduled_jobs', 'agent_termination_incidents', 'agent_termination_proofs',
              'schema_migrations'
            ])
        LOOP
          IF grantee_name = 'PUBLIC' THEN
            EXECUTE format('REVOKE ALL PRIVILEGES (%I) ON TABLE public.%I FROM PUBLIC',
                           column_name, relation_name);
          ELSE
            EXECUTE format('REVOKE ALL PRIVILEGES (%I) ON TABLE public.%I FROM %I',
                           column_name, relation_name, grantee_name);
          END IF;
        END LOOP;

        GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE public.effects,
          public.agent_runtime_leases, public.agent_directives, public.agent_runs,
          public.agent_run_steps, public.background_jobs, public.scheduled_jobs
          TO maraithon_runtime;
        GRANT SELECT, INSERT, UPDATE ON TABLE public.agent_termination_incidents
          TO maraithon_runtime;
        GRANT SELECT, INSERT ON TABLE public.agent_termination_proofs
          TO maraithon_runtime;
        GRANT SELECT ON TABLE public.agent_runtime_leases
          TO maraithon_incident_operator;
        GRANT SELECT, UPDATE ON TABLE public.agent_termination_incidents
          TO maraithon_incident_operator;
        GRANT SELECT, INSERT ON TABLE public.agent_termination_proofs
          TO maraithon_incident_operator;
        -- Regrant Effect protocol access after the blanket revocation above.
        -- This ordering is required on partial expansion retries as well as on
        -- a fresh catalog.
        GRANT SELECT, UPDATE ON TABLE public.effect_execution_protocols
          TO maraithon_runtime;
        GRANT SELECT ON TABLE public.effect_execution_protocol_manifests
          TO maraithon_runtime;
        GRANT SELECT ON TABLE public.effect_execution_protocols,
          public.effect_execution_protocol_manifests,
          public.effect_termination_attestations TO maraithon_payload_verifier;
        GRANT SELECT ON TABLE public.effect_termination_attestations
          TO maraithon_runtime;
        GRANT SELECT, INSERT ON TABLE public.effect_termination_attestations
          TO maraithon_incident_operator;
        GRANT SELECT, UPDATE ON TABLE public.effect_execution_protocols
          TO maraithon_activation_operator;
        GRANT SELECT ON TABLE public.schema_migrations,
          public.effect_execution_protocol_manifests,
          public.effect_termination_attestations
          TO maraithon_runtime, maraithon_payload_verifier,
             maraithon_activation_operator;
        -- UPDATE is needed by PostgreSQL for SHARE table locks. Row triggers
        -- reject activation-role DML on every locked work root.
        GRANT SELECT, UPDATE ON TABLE public.effects, public.agent_runtime_leases,
          public.agent_directives, public.agent_runs, public.agent_run_steps,
          public.background_jobs, public.scheduled_jobs
          TO maraithon_activation_operator;

        FOREACH function_name IN ARRAY ARRAY[
          'runtime_partition_for(text)', 'runtime_coordination_roles_ready()',
          'runtime_role_topology_fingerprint()', 'runtime_coordination_acl_ready()',
          'runtime_catalog_table_fingerprint(regclass)',
          'populate_runtime_work_partition()', 'enforce_effect_activation_evidence()',
          'enforce_runtime_coordination_protocol()',
          'reject_runtime_coordination_evidence_mutation()',
          'enforce_runtime_partition_transition()', 'enforce_runtime_node_incarnation()',
          'enforce_runtime_leader_authority()', 'enforce_runtime_partition_authority()',
          'enforce_runtime_task_assignment()', 'enforce_runtime_task_outcome_evidence()',
          'enforce_runtime_task_termination_proof()',
          'runtime_task_authority_valid(uuid,uuid,smallint,bigint,uuid,uuid)',
          'enforce_runtime_work_role()', 'enforce_coordinated_background_job()',
          'enforce_coordinated_scheduled_job()', 'enforce_coordinated_agent_directive()',
          'enforce_coordinated_agent_lease()', 'enforce_coordinated_effect()',
          'enforce_effect_assignment_final_pair()',
          'enforce_agent_termination_incident()', 'enforce_agent_termination_proof()',
          'enforce_agent_termination_partition_release()',
          'runtime_coordination_catalog_ready_count()'
        ] LOOP
          EXECUTE format('REVOKE ALL ON FUNCTION public.%s FROM PUBLIC, maraithon_runtime, maraithon_payload_verifier, maraithon_incident_operator, maraithon_activation_operator', function_name);
          EXECUTE format('GRANT ALL ON FUNCTION public.%s TO maraithon_migrator', function_name);
          EXECUTE format('ALTER FUNCTION public.%s OWNER TO maraithon_object_owner', function_name);
        END LOOP;

        GRANT EXECUTE ON FUNCTION public.runtime_partition_for(text),
          public.runtime_task_authority_valid(uuid,uuid,smallint,bigint,uuid,uuid),
          public.runtime_coordination_roles_ready(),
          public.runtime_role_topology_fingerprint(),
          public.runtime_coordination_acl_ready(),
          public.runtime_catalog_table_fingerprint(regclass),
          public.runtime_coordination_catalog_ready_count()
          TO maraithon_runtime;
        GRANT EXECUTE ON FUNCTION public.runtime_coordination_roles_ready(),
          public.runtime_role_topology_fingerprint(),
          public.runtime_coordination_acl_ready(),
          public.runtime_catalog_table_fingerprint(regclass),
          public.runtime_coordination_catalog_ready_count()
          TO maraithon_payload_verifier, maraithon_activation_operator;
      END IF;
    END;
    $block$;
    """)

    execute("""
    INSERT INTO public.runtime_coordination_manifests
      (name, constraint_fingerprints, function_fingerprints, trigger_fingerprints,
       index_fingerprints, catalog_fingerprints, inserted_at, updated_at)
    WITH required_functions(function_id) AS (
      VALUES
        ('public.runtime_partition_for(text)'::regprocedure),
        ('public.runtime_coordination_roles_ready()'::regprocedure),
        ('public.runtime_role_topology_fingerprint()'::regprocedure),
        ('public.runtime_coordination_acl_ready()'::regprocedure),
        ('public.runtime_catalog_table_fingerprint(regclass)'::regprocedure),
        ('public.populate_runtime_work_partition()'::regprocedure),
        ('public.enforce_effect_activation_evidence()'::regprocedure),
        ('public.enforce_runtime_coordination_protocol()'::regprocedure),
        ('public.reject_runtime_coordination_evidence_mutation()'::regprocedure),
        ('public.enforce_runtime_partition_transition()'::regprocedure),
        ('public.enforce_runtime_node_incarnation()'::regprocedure),
        ('public.enforce_runtime_leader_authority()'::regprocedure),
        ('public.enforce_runtime_partition_authority()'::regprocedure),
        ('public.enforce_runtime_task_assignment()'::regprocedure),
        ('public.enforce_runtime_task_outcome_evidence()'::regprocedure),
        ('public.enforce_runtime_task_termination_proof()'::regprocedure),
        ('public.runtime_task_authority_valid(uuid,uuid,smallint,bigint,uuid,uuid)'::regprocedure),
        ('public.enforce_runtime_work_role()'::regprocedure),
        ('public.enforce_coordinated_background_job()'::regprocedure),
        ('public.enforce_coordinated_scheduled_job()'::regprocedure),
        ('public.enforce_coordinated_agent_directive()'::regprocedure),
        ('public.enforce_coordinated_agent_lease()'::regprocedure),
        ('public.enforce_coordinated_effect()'::regprocedure),
        ('public.enforce_effect_assignment_final_pair()'::regprocedure),
        ('public.enforce_agent_termination_incident()'::regprocedure),
        ('public.enforce_agent_termination_proof()'::regprocedure),
        ('public.enforce_agent_termination_partition_release()'::regprocedure),
        ('public.runtime_coordination_catalog_ready_count()'::regprocedure)
    ), functions AS (
      SELECT jsonb_object_agg(function_row.proname,
               encode(public.digest(convert_to(pg_catalog.jsonb_build_object(
                 'definition', pg_catalog.pg_get_functiondef(function_row.oid),
                 'owner', owner_row.rolname,
                 'acl', function_row.proacl
               )::text, 'UTF8'), 'sha256'), 'hex')) AS value
      FROM required_functions AS required
      JOIN pg_catalog.pg_proc AS function_row ON function_row.oid = required.function_id
      JOIN pg_catalog.pg_roles AS owner_row ON owner_row.oid = function_row.proowner
    ), required_constraints(relation_id, constraint_name) AS (
      VALUES
        ('public.runtime_coordination_protocols'::regclass, 'runtime_coordination_protocol_shape'),
        ('public.runtime_coordination_manifests'::regclass, 'runtime_coordination_manifest_singleton'),
        ('public.effect_execution_protocols'::regclass, 'effect_activation_evidence_shape'),
        ('public.runtime_node_incarnations'::regclass, 'runtime_node_incarnations_shape'),
        ('public.runtime_leader_authorities'::regclass, 'runtime_leader_authorities_shape'),
        ('public.runtime_partitions'::regclass, 'runtime_partitions_shape'),
        ('public.runtime_partition_transitions'::regclass, 'runtime_partition_transitions_shape'),
        ('public.runtime_task_assignments'::regclass, 'runtime_task_assignments_shape'),
        ('public.runtime_task_outcome_evidence'::regclass, 'runtime_task_outcome_evidence_shape'),
        ('public.runtime_task_termination_proofs'::regclass, 'runtime_task_termination_proofs_shape'),
        ('public.runtime_tenant_fairness'::regclass, 'runtime_tenant_fairness_bounds'),
        ('public.runtime_partition_rebalance_requests'::regclass, 'runtime_partition_rebalance_requests_shape'),
        ('public.background_jobs'::regclass, 'background_jobs_partition_shape'),
        ('public.scheduled_jobs'::regclass, 'scheduled_jobs_partition_shape'),
        ('public.agent_termination_incidents'::regclass, 'agent_termination_incidents_shape'),
        ('public.agent_termination_proofs'::regclass, 'agent_termination_proofs_shape')
    ), constraints AS (
      SELECT jsonb_object_agg(required.constraint_name,
               encode(public.digest(convert_to(regexp_replace(pg_catalog.pg_get_constraintdef(constraint_row.oid, true), ' NOT VALID$', ''), 'UTF8'), 'sha256'), 'hex')) AS value
      FROM required_constraints AS required
      JOIN pg_catalog.pg_constraint AS constraint_row
        ON constraint_row.conrelid = required.relation_id
       AND constraint_row.conname = required.constraint_name
    ), required_triggers(relation_id, trigger_name) AS (
      VALUES
        ('public.runtime_coordination_protocols'::regclass, 'enforce_runtime_coordination_protocol_trigger'),
        ('public.runtime_coordination_protocols'::regclass, 'reject_runtime_coordination_protocol_truncate_trigger'),
        ('public.effect_execution_protocols'::regclass, 'enforce_effect_activation_evidence_trigger'),
        ('public.runtime_coordination_manifests'::regclass, 'reject_runtime_coordination_manifests_mutation_trigger'),
        ('public.runtime_coordination_manifests'::regclass, 'reject_runtime_coordination_manifests_truncate_trigger'),
        ('public.runtime_task_termination_proofs'::regclass, 'reject_runtime_task_termination_proofs_mutation_trigger'),
        ('public.runtime_task_termination_proofs'::regclass, 'reject_runtime_task_termination_proofs_truncate_trigger'),
        ('public.runtime_partition_transitions'::regclass, 'enforce_runtime_partition_transition_trigger'),
        ('public.runtime_partition_transitions'::regclass, 'reject_runtime_partition_transitions_truncate_trigger'),
        ('public.runtime_node_incarnations'::regclass, 'enforce_runtime_node_incarnation_trigger'),
        ('public.runtime_leader_authorities'::regclass, 'enforce_runtime_leader_authority_trigger'),
        ('public.runtime_partitions'::regclass, 'enforce_runtime_partition_authority_trigger'),
        ('public.runtime_task_assignments'::regclass, 'enforce_runtime_task_assignment_trigger'),
        ('public.runtime_task_outcome_evidence'::regclass, 'enforce_runtime_task_outcome_evidence_trigger'),
        ('public.runtime_task_outcome_evidence'::regclass, 'reject_runtime_task_outcome_evidence_truncate_trigger'),
        ('public.runtime_task_termination_proofs'::regclass, 'enforce_runtime_task_termination_proof_trigger'),
        ('public.background_jobs'::regclass, 'enforce_coordinated_background_job_trigger'),
        ('public.scheduled_jobs'::regclass, 'enforce_coordinated_scheduled_job_trigger'),
        ('public.agent_runs'::regclass, 'enforce_agent_runs_runtime_role_trigger'),
        ('public.agent_run_steps'::regclass, 'enforce_agent_run_steps_runtime_role_trigger'),
        ('public.agent_directives'::regclass, 'enforce_coordinated_agent_directive_trigger'),
        ('public.agent_runtime_leases'::regclass, 'enforce_coordinated_agent_lease_trigger'),
        ('public.effects'::regclass, 'enforce_coordinated_effect_trigger'),
        ('public.effects'::regclass, 'enforce_effect_assignment_final_pair_effect_trigger'),
        ('public.runtime_task_assignments'::regclass,
         'enforce_effect_assignment_final_pair_assignment_trigger'),
        ('public.agent_termination_incidents'::regclass, 'enforce_agent_termination_incident_trigger'),
        ('public.agent_termination_incidents'::regclass, 'reject_agent_termination_incidents_truncate_trigger'),
        ('public.agent_termination_proofs'::regclass, 'enforce_agent_termination_proof_trigger'),
        ('public.agent_termination_proofs'::regclass, 'reject_agent_termination_proofs_truncate_trigger'),
        ('public.runtime_partitions'::regclass, 'enforce_agent_termination_partition_release_trigger')
    ), triggers AS (
      SELECT jsonb_object_agg(required.trigger_name,
               encode(public.digest(convert_to(pg_catalog.pg_get_triggerdef(trigger_row.oid, true), 'UTF8'), 'sha256'), 'hex')) AS value
      FROM required_triggers AS required
      JOIN pg_catalog.pg_trigger AS trigger_row
        ON trigger_row.tgrelid = required.relation_id
       AND trigger_row.tgname = required.trigger_name
       AND NOT trigger_row.tgisinternal
    ), required_indexes(index_name) AS (
      VALUES
        ('runtime_task_assignments_claim_token_index'),
        ('runtime_task_assignments_physical_identity_index'),
        ('runtime_task_assignments_active_work_index'),
        ('runtime_task_outcome_evidence_assignment_index'),
        ('runtime_task_termination_proofs_assignment_index'),
        ('runtime_partition_rebalance_requests_pending_partition_index'),
        ('background_jobs_partition_due_index'),
        ('background_jobs_tenant_active_index'),
        ('scheduled_jobs_partition_due_index'),
        ('agent_runtime_leases_coordination_partition_index'),
        ('effects_coordination_partition_pending_index'),
        ('agent_termination_incidents_lease_token_index'),
        ('agent_termination_incidents_open_agent_index'),
        ('agent_termination_incidents_due_index'),
        ('agent_termination_incidents_coordination_index'),
        ('agent_termination_proofs_incident_index'),
        ('agent_termination_proofs_lease_token_index'),
        ('agent_termination_proofs_exact_identity_index')
    ), indexes AS (
      SELECT jsonb_object_agg(required.index_name,
               encode(public.digest(convert_to(pg_catalog.jsonb_build_object(
              'definition', pg_catalog.pg_get_indexdef(index_relation.oid),
              'owner', index_owner.rolname,
              'acl', index_relation.relacl
            )::text, 'UTF8'), 'sha256'), 'hex')) AS value
      FROM required_indexes AS required
      JOIN pg_catalog.pg_class AS index_relation ON index_relation.relname = required.index_name
      JOIN pg_catalog.pg_namespace AS namespace ON namespace.oid = index_relation.relnamespace
       AND namespace.nspname = 'public'
      JOIN pg_catalog.pg_roles AS index_owner ON index_owner.oid = index_relation.relowner
    ), required_catalogs(relation_id, relation_name) AS (
      VALUES
        ('public.runtime_coordination_protocols'::regclass, 'runtime_coordination_protocols'),
        ('public.runtime_coordination_manifests'::regclass, 'runtime_coordination_manifests'),
        ('public.schema_migrations'::regclass, 'schema_migrations'),
        ('public.effect_execution_protocols'::regclass, 'effect_execution_protocols'),
        ('public.effect_execution_protocol_manifests'::regclass,
         'effect_execution_protocol_manifests'),
        ('public.effect_termination_attestations'::regclass,
         'effect_termination_attestations'),
        ('public.runtime_node_incarnations'::regclass, 'runtime_node_incarnations'),
        ('public.runtime_leader_authorities'::regclass, 'runtime_leader_authorities'),
        ('public.runtime_partitions'::regclass, 'runtime_partitions'),
        ('public.runtime_partition_transitions'::regclass, 'runtime_partition_transitions'),
        ('public.runtime_task_assignments'::regclass, 'runtime_task_assignments'),
        ('public.runtime_task_outcome_evidence'::regclass, 'runtime_task_outcome_evidence'),
        ('public.runtime_task_termination_proofs'::regclass, 'runtime_task_termination_proofs'),
        ('public.runtime_tenant_fairness'::regclass, 'runtime_tenant_fairness'),
        ('public.runtime_partition_rebalance_requests'::regclass, 'runtime_partition_rebalance_requests'),
        ('public.background_jobs'::regclass, 'background_jobs'),
        ('public.scheduled_jobs'::regclass, 'scheduled_jobs'),
        ('public.agent_runtime_leases'::regclass, 'agent_runtime_leases'),
        ('public.agent_directives'::regclass, 'agent_directives'),
        ('public.agent_runs'::regclass, 'agent_runs'),
        ('public.agent_run_steps'::regclass, 'agent_run_steps'),
        ('public.effects'::regclass, 'effects'),
        ('public.agent_termination_incidents'::regclass, 'agent_termination_incidents'),
        ('public.agent_termination_proofs'::regclass, 'agent_termination_proofs')
    ), catalogs AS (
      SELECT jsonb_object_agg(required.relation_name,
               public.runtime_catalog_table_fingerprint(required.relation_id)) ||
             jsonb_build_object('role_topology',
               public.runtime_role_topology_fingerprint()) AS value
      FROM required_catalogs AS required
    )
    SELECT 'runtime', constraints.value, functions.value, triggers.value, indexes.value,
           catalogs.value, timezone('UTC', clock_timestamp()),
           timezone('UTC', clock_timestamp())
    FROM constraints, functions, triggers, indexes, catalogs
    ON CONFLICT (name) DO NOTHING
    """)

    execute("""
    INSERT INTO public.runtime_coordination_protocols
      (name, mode, partition_count, activation_epoch, activated_at,
       activation_evidence_id, activation_evidence_digest, activated_by, exact_revision,
       manifest_digest, inserted_at, updated_at)
    SELECT 'runtime', 'dark', #{@partition_count}, NULL, NULL, NULL, NULL, NULL, NULL,
       public.digest(convert_to(pg_catalog.jsonb_build_object(
         'constraints', manifest.constraint_fingerprints,
         'functions', manifest.function_fingerprints,
         'triggers', manifest.trigger_fingerprints,
         'indexes', manifest.index_fingerprints,
         'catalogs', manifest.catalog_fingerprints
       )::text, 'UTF8'), 'sha256'),
       timezone('UTC', clock_timestamp()), timezone('UTC', clock_timestamp())
    FROM public.runtime_coordination_manifests AS manifest
    WHERE manifest.name = 'runtime'
    ON CONFLICT (name) DO NOTHING
    """)

    execute("""
    INSERT INTO public.runtime_leader_authorities
      (role, leader_epoch, state, inserted_at, updated_at)
    VALUES ('partition_planner', 0, 'unassigned',
            timezone('UTC', clock_timestamp()), timezone('UTC', clock_timestamp()))
    ON CONFLICT (role) DO NOTHING
    """)

    execute("""
    INSERT INTO public.runtime_partitions
      (partition_id, ownership_epoch, state, fair_sequence, inserted_at, updated_at)
    SELECT partition_id, 0, 'unassigned', 0,
           timezone('UTC', clock_timestamp()), timezone('UTC', clock_timestamp())
    FROM generate_series(0, #{@partition_count - 1}) AS partition_id
    ON CONFLICT (partition_id) DO NOTHING
    """)
  end

  defp drop_invalid_index(name) when is_binary(name) do
    name = String.slice(name, 0, 63)

    unless Regex.match?(~r/\A[a-z0-9_]+\z/, name),
      do: raise(Ecto.MigrationError, "unsafe runtime coordination index name")

    execute("""
    DO $index_recovery$
    BEGIN
      IF EXISTS (
        SELECT 1
        FROM pg_catalog.pg_class AS index_relation
        JOIN pg_catalog.pg_namespace AS namespace
          ON namespace.oid = index_relation.relnamespace
        JOIN pg_catalog.pg_index AS index_row
          ON index_row.indexrelid = index_relation.oid
        WHERE namespace.nspname = 'public' AND index_relation.relname = '#{name}'
          AND (NOT index_row.indisvalid OR NOT index_row.indisready OR NOT index_row.indislive)
      ) THEN
        EXECUTE format('DROP INDEX public.%I', '#{name}');
      END IF;
    END;
    $index_recovery$;
    """)
  end

  def down do
    raise Ecto.MigrationError,
          "runtime coordination authority is irreversible after durable expansion"
  end
end
