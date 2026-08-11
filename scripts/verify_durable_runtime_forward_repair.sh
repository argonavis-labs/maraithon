#!/usr/bin/env bash
set -euo pipefail

# Destructive only to one disposable test database. It never deletes a migration
# ledger row: 140007 stays recorded while the real forward 000420 repair runs.
# Run from a Maraithon checkout, or set MARAITHON_REPO.
ROOT="${MARAITHON_REPO:-$(git rev-parse --show-toplevel)}"
cd "$ROOT"
SOURCE_DIR="${REPAIR_SOURCE_DIR:-priv/repo/migrations}"

export MIX_ENV=test
export MIX_TEST_PARTITION="${MIX_TEST_PARTITION:-_durable_repair_${$}}"
DB="maraithon_test${MIX_TEST_PARTITION}"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/maraithon-durable-repair.XXXXXX")"
KEEP_ARTIFACTS="${KEEP_REPAIR_ARTIFACTS:-0}"

cleanup() {
  MIX_ENV=test MIX_TEST_PARTITION="$MIX_TEST_PARTITION" mix ecto.drop --quiet \
    >"$WORK/drop.log" 2>&1 || true
  if [[ "$KEEP_ARTIFACTS" == "1" ]]; then
    echo "kept repair verification artifacts: $WORK" >&2
  else
    rm -rf "$WORK"
  fi
}
trap cleanup EXIT

fail() {
  echo "durable runtime repair verification failed: $*" >&2
  exit 1
}

assert_eq() {
  local expected="$1" actual="$2" label="$3"
  [[ "$actual" == "$expected" ]] ||
    fail "$label (expected '$expected', got '$actual')"
}

psql_db() {
  psql -X -v ON_ERROR_STOP=1 -d "$DB" "$@"
}

# A migration failure must not strand a session-scoped repair capability on any
# pooled backend. The runner holds every pool connection simultaneously before
# accepting success/failure, so one clean connection cannot mask a dirty one.
cat >"$WORK/migration_runner.exs" <<'ELIXIR'
repo_config =
  :maraithon
  |> Application.fetch_env!(Maraithon.Repo)
  |> Keyword.delete(:pool)
  |> Keyword.put(:pool_size, 4)
  |> Keyword.put(:database, System.fetch_env!("REPAIR_DB"))

Application.put_env(:maraithon, Maraithon.Repo, repo_config)
{:ok, _} = Application.ensure_all_started(:ecto_sql)
{:ok, _repo} = Maraithon.Repo.start_link()

collect_all_markers = fn ->
  parent = self()

  tasks =
    for _ <- 1..4 do
      Task.async(fn ->
        Maraithon.Repo.checkout(
          fn ->
            %{rows: [[backend_pid, marker]]} =
              Maraithon.Repo.query!(
                "SELECT pg_backend_pid(), " <>
                  "current_setting('maraithon.agent_work_result_purge_repair', true)"
              )

            send(parent, {:marker_held, self(), backend_pid, marker})

            receive do
              :release_marker_connection -> {backend_pid, marker}
            after
              15_000 -> raise "timed out holding marker probe connection"
            end
          end,
          timeout: :infinity
        )
      end)
    end

  held =
    for _ <- tasks do
      receive do
        {:marker_held, pid, backend_pid, marker} -> {pid, backend_pid, marker}
      after
        15_000 -> raise "could not acquire every marker probe connection"
      end
    end

  Enum.each(held, fn {pid, _backend_pid, _marker} ->
    send(pid, :release_marker_connection)
  end)

  Enum.each(tasks, &Task.await(&1, 15_000))
  Enum.map(held, fn {_pid, backend_pid, marker} -> {backend_pid, marker} end)
end

migration_path = System.fetch_env!("REPAIR_MIGRATION_PATH")
expected = System.fetch_env!("REPAIR_EXPECT")
expected_error = System.get_env("REPAIR_EXPECT_ERROR", "")

outcome =
  try do
    versions =
      Ecto.Migrator.run(Maraithon.Repo, migration_path, :up,
        all: true,
        log: false,
        log_migrations_sql: false
      )

    {:ok, versions}
  rescue
    error -> {:error, Exception.format(:error, error, __STACKTRACE__)}
  catch
    kind, reason -> {:error, Exception.format(kind, reason, __STACKTRACE__)}
  end

markers = collect_all_markers.()

unless Enum.all?(markers, fn {_pid, marker} -> marker in [nil, ""] end) do
  raise "repair capability leaked on pooled backend(s): #{inspect(markers)}"
end

case {expected, outcome} do
  {"success", {:ok, versions}} ->
    IO.puts("migration outcome=success versions=#{inspect(versions)} markers=#{inspect(markers)}")

  {"failure", {:error, formatted}} ->
    if expected_error != "" and not String.contains?(formatted, expected_error) do
      raise "wrong migration failure; wanted #{inspect(expected_error)}, got:\n#{formatted}"
    end

    # Keep a single-line result plus the full diagnostic in the command log.
    first_line = formatted |> String.split("\n") |> hd()
    IO.puts("migration outcome=expected_failure error=#{inspect(first_line)} markers=#{inspect(markers)}")
    IO.puts(formatted)

  {"success", {:error, formatted}} ->
    raise "migration unexpectedly failed:\n#{formatted}"

  {"failure", {:ok, versions}} ->
    raise "migration unexpectedly succeeded: #{inspect(versions)}"
end
ELIXIR

# This is the hard-interruption counterpart to try/after RESET: DBConnection
# must discard the checked-out PostgreSQL session when its owner is killed.
cat >"$WORK/owner_death_probe.exs" <<'ELIXIR'
repo_config =
  :maraithon
  |> Application.fetch_env!(Maraithon.Repo)
  |> Keyword.delete(:pool)
  |> Keyword.put(:pool_size, 1)
  |> Keyword.put(:database, System.fetch_env!("REPAIR_DB"))

Application.put_env(:maraithon, Maraithon.Repo, repo_config)
{:ok, _} = Application.ensure_all_started(:ecto_sql)
{:ok, _repo} = Maraithon.Repo.start_link()
parent = self()

{:ok, owner} =
  Task.start(fn ->
    Maraithon.Repo.checkout(
      fn ->
        %{rows: [[backend_pid, _]]} =
          Maraithon.Repo.query!(
            "SELECT pg_backend_pid(), " <>
              "set_config('maraithon.agent_work_result_purge_repair', " <>
              "'CLEAR_PURGED_AUTHORITY_V1', false)"
          )

        send(parent, {:marker_set, self(), backend_pid})

        receive do
          :never -> :ok
        end
      end,
      timeout: :infinity
    )
  end)

ref = Process.monitor(owner)

old_backend =
  receive do
    {:marker_set, ^owner, backend_pid} -> backend_pid
  after
    10_000 -> raise "marker owner never acquired its connection"
  end

Process.exit(owner, :kill)

receive do
  {:DOWN, ^ref, :process, ^owner, :killed} -> :ok
after
  10_000 -> raise "marker owner did not die"
end

%{rows: [[new_backend, marker]]} =
  Maraithon.Repo.query!(
    "SELECT pg_backend_pid(), " <>
      "current_setting('maraithon.agent_work_result_purge_repair', true)"
  )

unless marker in [nil, ""] and new_backend != old_backend do
  raise "owner death reused dirty backend: old=#{old_backend} new=#{new_backend} marker=#{inspect(marker)}"
end

IO.puts("owner-death marker isolation verified old_backend=#{old_backend} new_backend=#{new_backend}")
ELIXIR

# Expected PostgreSQL errors inside a database-role/session test must be caught
# in a real savepoint, not by poisoning the surrounding transaction.
cat >"$WORK/savepoint_probe.exs" <<'ELIXIR'
repo_config =
  :maraithon
  |> Application.fetch_env!(Maraithon.Repo)
  |> Keyword.put(:pool, Ecto.Adapters.SQL.Sandbox)
  |> Keyword.put(:pool_size, 2)
  |> Keyword.put(:database, System.fetch_env!("REPAIR_DB"))

Application.put_env(:maraithon, Maraithon.Repo, repo_config)
{:ok, _} = Application.ensure_all_started(:ecto_sql)
{:ok, _repo} = Maraithon.Repo.start_link()
Ecto.Adapters.SQL.Sandbox.mode(Maraithon.Repo, :manual)
:ok = Ecto.Adapters.SQL.Sandbox.checkout(Maraithon.Repo)

id = Ecto.UUID.dump!("90000000-0000-0000-0000-000000000002")

hash = fn ->
  %{rows: [[value]]} =
    Maraithon.Repo.query!(
      "SELECT encode(digest(convert_to(to_jsonb(result_row)::text, 'UTF8'), 'sha256'), 'hex') " <>
        "FROM agent_work_results AS result_row WHERE id = $1",
      [id]
    )

  value
end

before_hash = hash.()

caught =
  try do
    Maraithon.Repo.transaction(
      fn ->
        Maraithon.Repo.query!(
          "UPDATE agent_work_results " <>
            "SET terminal_event = 'forbidden_mutation' WHERE id = $1",
          [id]
        )
      end,
      mode: :savepoint
    )

    false
  rescue
    error in Postgrex.Error ->
      error.postgres.code == :check_violation or error.postgres.pg_code == "23514"
  end

unless caught, do: raise("expected guarded row error was not caught in savepoint")
%{rows: [[42]]} = Maraithon.Repo.query!("SELECT 42")
unless hash.() == before_hash, do: raise("failed savepoint changed the valid row")
IO.puts("database error savepoint verified; sandbox transaction remained usable")
ELIXIR

run_migration() {
  local path="$1" expected="$2" expected_error="${3:-}" log="$4"
  if ! REPAIR_DB="$DB" \
    REPAIR_MIGRATION_PATH="$path" \
    REPAIR_EXPECT="$expected" \
    REPAIR_EXPECT_ERROR="$expected_error" \
      mix run --no-start "$WORK/migration_runner.exs" >"$log" 2>&1; then
    cat "$log" >&2
    fail "migration runner failed unexpectedly (log: $log)"
  fi
}

# The forward repair is intentionally source-pinned. A stale production digest is
# a defect, not the intentional tamper case below.
python3 - "$SOURCE_DIR" <<'PY'
from pathlib import Path
import hashlib
import re
import sys

source_dir = Path(sys.argv[1])
repair = (source_dir / "20260811000420_repair_durable_runtime_authority.exs").read_text()
entries = re.findall(
    r'\{\s*"([^"]+)",\s*[A-Za-z0-9_.]+,\s*"([0-9a-f]{64})"\s*\}',
    repair,
    flags=re.S,
)
if len(entries) != 3:
    raise SystemExit(f"could not parse exactly three source pins from {source_dir}")

mismatches = []
for filename, expected in entries:
    actual = hashlib.sha256((source_dir / filename).read_bytes()).hexdigest()
    if actual != expected:
        mismatches.append(f"{filename}: expected {expected}, actual {actual}")

if mismatches:
    raise SystemExit("stale 000420 source digest(s):\n  " + "\n  ".join(mismatches))

# Updating the source pin must not silently drop the proof-first reserved Effect
# cancellation boundary that the forward repair is responsible for installing.
coordination_source = (
    source_dir / "20260810140004_create_runtime_coordination_authority.exs"
).read_text()
required_reserved_cancellation_fragments = (
    "transition_assignment.work_kind = 'effect'",
    "transition_assignment.work_id = OLD.id",
    "OLD.status = 'claimed' AND NEW.status = 'cancelling'",
    "NEW.cancellation_state = 'requested'",
    "transition_assignment.state = 'reserved'",
    "transition_assignment.provider_boundary = 'not_entered'",
    "transition_assignment.ready_at IS NULL",
    "transition_partition.state IN ('ready', 'draining', 'blocked')",
    "transition_node.state IN ('ready', 'draining')",
    "transition_lease.ready_at IS NOT NULL OR",
)
missing_fragments = [
    fragment
    for fragment in required_reserved_cancellation_fragments
    if fragment not in coordination_source
]
if missing_fragments:
    raise SystemExit(
        "140004 reserved Effect cancellation authority guard is incomplete:\n  "
        + "\n  ".join(missing_fragments)
    )
PY

# Ensure another worker did not leave the cluster-global login topology broken.
role_before="$(psql -X -At -d postgres -c \
  "SELECT rolcanlogin::text || '|' || rolsuper::text || '|' || rolinherit::text FROM pg_roles WHERE rolname = 'maraithon_payload_verifier'")"
[[ "$role_before" == true\|* ]] ||
  fail "canonical payload verifier LOGIN before probe (got '$role_before')"

mix ecto.drop --quiet >"$WORK/pre_drop.log" 2>&1 || true
mix ecto.create --quiet >"$WORK/create.log" 2>&1
mix ecto.migrate --quiet --to 20260810140007 >"$WORK/bootstrap.log" 2>&1

ledger_before="$(psql_db -Atc \
  "SELECT count(*) FILTER (WHERE version=20260810140007) || '|' || count(*) FILTER (WHERE version=20260811000420) FROM schema_migrations")"
assert_eq "1|0" "$ledger_before" "prior/forward ledger before repair"

# Model the catalog/data shape left by the previously-recorded 140007 source:
# no content-digest columns, result_digest still NOT NULL, and purged rows retain
# the opaque keyed token. Synthetic setup bypasses only unrelated foreign keys;
# the real deferred full-lineage proof executes on every repair update.
psql_db >"$WORK/setup.log" <<'SQL'
ALTER TABLE public.agent_work_results
  DROP CONSTRAINT agent_work_results_digest_check;
ALTER TABLE public.agent_work_results
  DROP COLUMN result_content_digest,
  DROP COLUMN result_content_digest_version;
ALTER TABLE public.agent_work_results
  ALTER COLUMN result_digest SET NOT NULL;
ALTER TABLE public.agent_work_results
  ADD CONSTRAINT agent_work_results_digest_check CHECK (
    octet_length(result_key) = 32 AND octet_length(result_digest) = 32
  );

ALTER TABLE public.agent_directives
  DISABLE TRIGGER guard_durable_payload_retired_key_write_trigger;
ALTER TABLE public.agent_runs
  DISABLE TRIGGER guard_durable_payload_retired_key_write_trigger;
ALTER TABLE public.agent_work_results
  DISABLE TRIGGER guard_durable_payload_retired_key_write_trigger;
SET session_replication_role = replica;

INSERT INTO public.agent_directives (
  id, agent_id, user_id, kind, payload, dedupe_key, request_fingerprint,
  status, available_at, attempts, max_attempts, terminal_at,
  terminal_claim_token, terminal_by_generation, inserted_at, updated_at,
  active_run_id, effect_count, terminal_acknowledged_at
)
SELECT
  ('10000000-0000-0000-0000-' || lpad(ordinal::text, 12, '0'))::uuid,
  '20000000-0000-0000-0000-000000000001'::uuid,
  'durable-repair@example.test', 'runtime_control', '{}'::jsonb,
  'repair-directive-' || ordinal,
  digest('repair-directive-fingerprint-' || ordinal, 'sha256'),
  'completed', clock_timestamp() - interval '2 days', 0, 3,
  clock_timestamp() - interval '1 day',
  ('50000000-0000-0000-0000-' || lpad(ordinal::text, 12, '0'))::uuid,
  ('40000000-0000-0000-0000-' || lpad(ordinal::text, 12, '0'))::uuid,
  clock_timestamp() - interval '2 days',
  clock_timestamp() - interval '1 day',
  NULL, 0, clock_timestamp() - interval '1 day'
FROM generate_series(1, 1201) AS ordinal;

INSERT INTO public.agent_runs (
  id, agent_id, user_id, behavior, status, trigger, active_skills,
  tool_allowlist, budget_snapshot, metadata, started_at, completed_at,
  inserted_at, updated_at
)
SELECT
  ('30000000-0000-0000-0000-' || lpad(ordinal::text, 12, '0'))::uuid,
  '20000000-0000-0000-0000-000000000001'::uuid,
  'durable-repair@example.test', 'prompt_agent', 'completed', '{}'::jsonb,
  ARRAY[]::varchar[], ARRAY[]::varchar[], '{}'::jsonb, '{}'::jsonb,
  clock_timestamp() - interval '2 days',
  clock_timestamp() - interval '1 day',
  clock_timestamp() - interval '2 days',
  clock_timestamp() - interval '1 day'
FROM generate_series(1, 1201) AS ordinal;

INSERT INTO public.chief_acquisition_runs (
  id, acquisition_key, user_id, agent_id, agent_directive_id,
  runtime_ingress_receipt_id, connected_account_id, source_cursor_id,
  cursor_kind, provider, provider_account_key, source, scope_key,
  request_key, request_fingerprint, contract_version, status,
  start_cursor, proposed_cursor, continuation, pagination_exhausted,
  page_count, item_count, manifest_digest, failure_code,
  started_at, sealed_at, inserted_at, updated_at
)
SELECT
  ('60000000-0000-0000-0000-' || lpad(ordinal::text, 12, '0'))::uuid,
  digest('repair-acquisition-key-' || ordinal, 'sha256'),
  'durable-repair@example.test',
  '20000000-0000-0000-0000-000000000001'::uuid,
  ('10000000-0000-0000-0000-' || lpad(ordinal::text, 12, '0'))::uuid,
  ('70000000-0000-0000-0000-' || lpad(ordinal::text, 12, '0'))::uuid,
  ordinal, NULL, NULL, 'repair', 'account-' || ordinal, 'repair',
  'scope-' || ordinal, 'request-' || ordinal,
  digest('repair-acquisition-request-' || ordinal, 'sha256'),
  1, 'complete', NULL, NULL, NULL, true, 0, 0,
  digest('repair-acquisition-manifest-' || ordinal, 'sha256'), NULL,
  clock_timestamp() - interval '2 days',
  clock_timestamp() - interval '1 day',
  clock_timestamp() - interval '2 days',
  clock_timestamp() - interval '1 day'
FROM generate_series(1, 1201) AS ordinal;

INSERT INTO public.agent_work_results (
  id, result_key, agent_directive_id, agent_id, user_id, agent_run_id,
  claim_generation, claim_token, status, outcome, terminal_event, result,
  result_digest, provisional_at, committed_at, inserted_at, updated_at,
  result_ciphertext, payload_encryption_version, result_purged_at,
  result_digest_version, result_digest_key_tag,
  payload_binding_version, payload_binding_key_tag, payload_binding_mac
)
SELECT
  ('00000000-0000-0000-0000-' || lpad(ordinal::text, 12, '0'))::uuid,
  digest('repair-key-' || ordinal, 'sha256'),
  ('10000000-0000-0000-0000-' || lpad(ordinal::text, 12, '0'))::uuid,
  '20000000-0000-0000-0000-000000000001'::uuid,
  'durable-repair@example.test',
  ('30000000-0000-0000-0000-' || lpad(ordinal::text, 12, '0'))::uuid,
  ('40000000-0000-0000-0000-' || lpad(ordinal::text, 12, '0'))::uuid,
  ('50000000-0000-0000-0000-' || lpad(ordinal::text, 12, '0'))::uuid,
  'committed', 'completed', 'repair_' || ordinal, '{}'::jsonb,
  digest('legacy-result-digest-' || ordinal, 'sha256'),
  clock_timestamp() - interval '2 days',
  clock_timestamp() - interval '1 day',
  clock_timestamp() - interval '2 days',
  clock_timestamp() - interval '1 day',
  NULL, 1, clock_timestamp() - interval '1 day', 1, 'repair-key',
  NULL, NULL, NULL
FROM generate_series(1, 1201) AS ordinal;

-- All rows except ordinal 750 have complete persisted lineage. The missing
-- link is the deterministic database-row error in the second repair batch.
INSERT INTO public.agent_work_result_acquisitions (
  agent_work_result_id, acquisition_run_id, user_id, agent_id,
  agent_directive_id, inserted_at
)
SELECT
  ('00000000-0000-0000-0000-' || lpad(ordinal::text, 12, '0'))::uuid,
  ('60000000-0000-0000-0000-' || lpad(ordinal::text, 12, '0'))::uuid,
  'durable-repair@example.test',
  '20000000-0000-0000-0000-000000000001'::uuid,
  ('10000000-0000-0000-0000-' || lpad(ordinal::text, 12, '0'))::uuid,
  clock_timestamp() - interval '1 day'
FROM generate_series(1, 1201) AS ordinal
WHERE ordinal <> 750;

RESET session_replication_role;
ALTER TABLE public.agent_directives
  ENABLE ALWAYS TRIGGER guard_durable_payload_retired_key_write_trigger;
ALTER TABLE public.agent_runs
  ENABLE ALWAYS TRIGGER guard_durable_payload_retired_key_write_trigger;
ALTER TABLE public.agent_work_results
  ENABLE ALWAYS TRIGGER guard_durable_payload_retired_key_write_trigger;
SQL

legacy_shape="$(psql_db -Atc \
  "SELECT count(*) || '|' || count(result_digest) || '|' || count(*) FILTER (WHERE result_purged_at IS NOT NULL) FROM agent_work_results")"
assert_eq "1201|1201|1201" "$legacy_shape" "synthetic legacy purged rows"

# Hash tamper must fail while validating all three sources, before 140004/5/7
# execute. In particular, the missing columns and all 1201 rows remain untouched.
mkdir "$WORK/tampered_migrations"
for migration in \
  20260810140004_create_runtime_coordination_authority.exs \
  20260810140005_create_durable_payload_verifications.exs \
  20260810140007_add_operational_privacy_controls.exs \
  20260811000420_repair_durable_runtime_authority.exs; do
  cp "$SOURCE_DIR/$migration" "$WORK/tampered_migrations/$migration"
done
printf '\n# deterministic source-tamper probe\n' >> \
  "$WORK/tampered_migrations/20260810140007_add_operational_privacy_controls.exs"

run_migration "$WORK/tampered_migrations" failure \
  "durable runtime repair source digest mismatch for 20260810140007_add_operational_privacy_controls.exs" \
  "$WORK/tamper.log"

after_tamper="$(psql_db -Atc \
  "SELECT (SELECT count(*) FROM information_schema.columns WHERE table_schema='public' AND table_name='agent_work_results' AND column_name IN ('result_content_digest','result_content_digest_version')) || '|' || (SELECT count(*) FROM agent_work_results WHERE result_digest IS NOT NULL) || '|' || (SELECT count(*) FROM schema_migrations WHERE version=20260811000420)")"
assert_eq "0|1201|0" "$after_tamper" "tamper failed before repaired-source execution"

# The injected row lies in the second 500-row selection. Its savepoint must
# roll back only that row while the other 499 and the prior 500 commit.
run_migration "$SOURCE_DIR" failure "" "$WORK/interrupted.log"

after_interrupt="$(psql_db -Atc \
  "SELECT count(*) FILTER (WHERE terminal_event ~ '^repair_' AND result_digest IS NULL AND octet_length(result_content_digest)=32 AND result_content_digest_version=0) || '|' || count(*) FILTER (WHERE terminal_event ~ '^repair_' AND result_digest IS NOT NULL AND result_content_digest IS NULL) || '|' || (SELECT count(*) FROM schema_migrations WHERE version=20260811000420) FROM agent_work_results")"
assert_eq "999|202|0" "$after_interrupt" \
  "row savepoint committed 499 peers while preserving the bad identity"

wrong_first_batches="$(psql_db -Atc \
  "SELECT count(*) FROM agent_work_results WHERE terminal_event ~ '^repair_' AND (((substring(terminal_event from 8)::integer <= 1000 AND substring(terminal_event from 8)::integer <> 750) AND result_digest IS NOT NULL) OR ((substring(terminal_event from 8)::integer = 750 OR substring(terminal_event from 8)::integer > 1000) AND result_digest IS NULL))")"
assert_eq "0" "$wrong_first_batches" "deterministic two-batch row-local boundary"

interrupt_commits="$(grep -cE 'commit \[\]$' "$WORK/interrupted.log" || true)"
assert_eq "2" "$interrupt_commits" "two bounded repair batch commits before interruption"

# Add rows already in each valid final shape after the interrupted expansion has
# created the columns. Their complete row hashes must survive the retry.
psql_db >"$WORK/valid_rows.log" <<'SQL'
ALTER TABLE public.agent_work_results
  DISABLE TRIGGER guard_durable_payload_retired_key_write_trigger;
SET session_replication_role = replica;

-- Repair the one deliberately incomplete lineage proof before resuming.
INSERT INTO public.agent_work_result_acquisitions (
  agent_work_result_id, acquisition_run_id, user_id, agent_id,
  agent_directive_id, inserted_at
) VALUES (
  '00000000-0000-0000-0000-000000000750',
  '60000000-0000-0000-0000-000000000750',
  'durable-repair@example.test',
  '20000000-0000-0000-0000-000000000001',
  '10000000-0000-0000-0000-000000000750',
  clock_timestamp() - interval '1 day'
);

INSERT INTO public.agent_work_results (
  id, result_key, agent_directive_id, agent_id, user_id, agent_run_id,
  claim_generation, claim_token, status, outcome, terminal_event, result,
  result_digest, provisional_at, committed_at, inserted_at, updated_at,
  result_ciphertext, payload_encryption_version, result_purged_at,
  result_digest_version, result_digest_key_tag,
  payload_binding_version, payload_binding_key_tag, payload_binding_mac,
  result_content_digest, result_content_digest_version
) VALUES
(
  '90000000-0000-0000-0000-000000000001', digest('valid-purged-key', 'sha256'),
  '91000000-0000-0000-0000-000000000001',
  '92000000-0000-0000-0000-000000000001', 'valid-purged@example.test',
  '93000000-0000-0000-0000-000000000001',
  '94000000-0000-0000-0000-000000000001',
  '95000000-0000-0000-0000-000000000001',
  'committed', 'completed', 'valid_purged', '{}'::jsonb, NULL,
  clock_timestamp() - interval '2 days', clock_timestamp() - interval '1 day',
  clock_timestamp() - interval '2 days', clock_timestamp() - interval '1 day',
  NULL, 1, clock_timestamp() - interval '1 day', NULL, NULL,
  NULL, NULL, NULL, digest('valid-purged-content', 'sha256'), 0
),
(
  '90000000-0000-0000-0000-000000000002', digest('valid-live-key', 'sha256'),
  '91000000-0000-0000-0000-000000000002',
  '92000000-0000-0000-0000-000000000002', 'valid-live@example.test',
  '93000000-0000-0000-0000-000000000002',
  '94000000-0000-0000-0000-000000000002',
  '95000000-0000-0000-0000-000000000002',
  'committed', 'completed', 'valid_live', '{"kept": true}'::jsonb,
  digest('valid-live-content', 'sha256'),
  clock_timestamp() - interval '2 days', clock_timestamp() - interval '1 day',
  clock_timestamp() - interval '2 days', clock_timestamp() - interval '1 day',
  NULL, 1, NULL, 1, 'valid-key', NULL, NULL, NULL, NULL, NULL
);

RESET session_replication_role;
ALTER TABLE public.agent_work_results
  ENABLE ALWAYS TRIGGER guard_durable_payload_retired_key_write_trigger;

CREATE TABLE public.repair_probe_valid_snapshot AS
SELECT id,
       digest(convert_to(to_jsonb(result_row)::text, 'UTF8'), 'sha256') AS row_hash
FROM public.agent_work_results AS result_row
WHERE id IN (
  '90000000-0000-0000-0000-000000000001',
  '90000000-0000-0000-0000-000000000002'
);

SQL

# No schema_migrations deletion: rerunning 000420 naturally resumes because its
# failed attempt was never recorded, while the recorded 140007 remains intact.
run_migration "$SOURCE_DIR" success "" "$WORK/resume.log"

final_counts="$(psql_db -Atc \
  "SELECT count(*) FILTER (WHERE terminal_event ~ '^repair_' AND result_digest IS NULL AND result_digest_version IS NULL AND result_digest_key_tag IS NULL AND octet_length(result_content_digest)=32 AND result_content_digest_version=0) || '|' || count(*) FILTER (WHERE terminal_event ~ '^repair_' AND (result_digest IS NOT NULL OR result_content_digest IS NULL OR result_content_digest_version IS DISTINCT FROM 0)) FROM agent_work_results")"
assert_eq "1201|0" "$final_counts" \
  "interrupted repair resumed from the one rejected row and final 201"

resume_commits="$(grep -cE 'commit \[\]$' "$WORK/resume.log" || true)"
assert_eq "2" "$resume_commits" \
  "remaining 202 rows committed in one bounded retry batch plus empty convergence check"

valid_changes="$(psql_db -Atc \
  "SELECT count(*) FROM repair_probe_valid_snapshot AS before JOIN agent_work_results AS result_row USING (id) WHERE before.row_hash IS DISTINCT FROM digest(convert_to(to_jsonb(result_row)::text, 'UTF8'), 'sha256')")"
assert_eq "0" "$valid_changes" "already-valid purged and unpurged rows unchanged"

ledger_after="$(psql_db -Atc \
  "SELECT count(*) FILTER (WHERE version=20260810140007) || '|' || count(*) FILTER (WHERE version=20260811000420) FROM schema_migrations")"
assert_eq "1|1" "$ledger_after" "real forward repair ledger"

constraint_state="$(psql_db -Atc \
  "SELECT convalidated::text || '|' || (pg_get_constraintdef(oid) LIKE '%result_content_digest%')::text FROM pg_constraint WHERE conrelid='agent_work_results'::regclass AND conname='agent_work_results_digest_check'")"
assert_eq "true|true" "$constraint_state" "final repaired digest constraint validated"

# Exercise the exact savepoint pattern an apply-ready database_role: :session
# ExUnit test uses for expected trigger errors.
REPAIR_DB="$DB" mix run --no-start "$WORK/savepoint_probe.exs" \
  >"$WORK/savepoint.log" 2>&1

# Simulate an uncatchable owner death while the same session-level marker used by
# 140007 is set; the only safe pool behavior is backend disconnect/replacement.
REPAIR_DB="$DB" mix run --no-start "$WORK/owner_death_probe.exs" \
  >"$WORK/owner_death.log" 2>&1

role_after="$(psql -X -At -d postgres -c \
  "SELECT rolcanlogin::text || '|' || rolsuper::text || '|' || rolinherit::text FROM pg_roles WHERE rolname = 'maraithon_payload_verifier'")"
assert_eq "$role_before" "$role_after" "cluster-global payload verifier role unchanged"

# The committed batch must still fail the migration with every rejected identity
# and SQLSTATE; neither skipping the row nor masking it as a connection error is safe.
if ! grep -Eq '^migration outcome=expected_failure .*00000000-0000-0000-0000-000000000750:23514' \
  "$WORK/interrupted.log"; then
  fail "row-local database error identity was skipped or masked (see $WORK/interrupted.log)"
fi

printf '%s\n' \
  "durable runtime forward repair verified" \
  "  ledger: 140007 retained, 000420 recorded" \
  "  hash tamper: rejected before source execution" \
  "  interruption: 500 + 499 valid rows committed; bad row savepoint rolled back" \
  "  resume batch: repaired bad row + final 201" \
  "  marker: correct during rows, clean after failure/success/owner death" \
  "  valid rows: unchanged" \
  "  savepoint: expected database error contained"
