#!/usr/bin/env bash
set -euo pipefail

# Destructive, isolated verification of the nontransactional 140004 expansion.
# Canonical roles must already be provisioned in the local PostgreSQL cluster.
export MIX_ENV=test
export MIX_TEST_PARTITION=_coord_retry
DB="maraithon_test${MIX_TEST_PARTITION}"

cleanup() {
  mix ecto.drop --quiet >/dev/null 2>&1 || true
}
trap cleanup EXIT

mix ecto.drop --quiet >/dev/null 2>&1 || true
mix ecto.create --quiet
mix ecto.migrate --quiet

# Model a process death after catalog DDL but before immutable seeds and after
# arbitrary concurrent-index/trigger/constraint steps. This is deliberately
# catalog based; no sleeps or timing guesses are involved.
psql -v ON_ERROR_STOP=1 "$DB" <<'SQL'
DROP TRIGGER IF EXISTS reject_runtime_coordination_manifests_mutation_trigger
  ON public.runtime_coordination_manifests;
DROP TRIGGER IF EXISTS reject_runtime_coordination_manifests_truncate_trigger
  ON public.runtime_coordination_manifests;
DROP TRIGGER IF EXISTS enforce_runtime_coordination_protocol_trigger
  ON public.runtime_coordination_protocols;
DROP TRIGGER IF EXISTS reject_runtime_coordination_protocol_truncate_trigger
  ON public.runtime_coordination_protocols;
TRUNCATE public.runtime_coordination_protocols,
         public.runtime_coordination_manifests,
         public.runtime_partitions,
         public.runtime_leader_authorities;
DROP TRIGGER IF EXISTS enforce_runtime_task_assignment_trigger
  ON public.runtime_task_assignments;
DROP INDEX CONCURRENTLY IF EXISTS public.background_jobs_partition_due_index;
ALTER TABLE public.background_jobs
  DROP CONSTRAINT IF EXISTS background_jobs_partition_shape;
DELETE FROM public.schema_migrations WHERE version = 20260810140004;
SQL

mix ecto.migrate --quiet

result="$(psql -At -v ON_ERROR_STOP=1 "$DB" <<'SQL'
SELECT
  (SELECT count(*) FROM public.schema_migrations WHERE version = 20260810140004),
  (SELECT count(*) FROM public.runtime_coordination_protocols WHERE name = 'runtime' AND mode = 'dark'),
  (SELECT count(*) FROM public.runtime_coordination_manifests WHERE name = 'runtime'),
  (SELECT count(*) FROM public.runtime_partitions),
  (SELECT count(*) FROM public.runtime_leader_authorities WHERE role = 'partition_planner'),
  public.runtime_coordination_roles_ready(),
  public.runtime_coordination_acl_ready(),
  public.runtime_coordination_catalog_ready_count();
SQL
)"

if [[ "$result" != "1|1|1|64|1|t|t|95" ]]; then
  echo "partial expansion retry verification failed: $result" >&2
  exit 1
fi

echo "partial expansion retry verified: $result"
