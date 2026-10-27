defmodule Maraithon.Repo.Migrations.AllowSourceCycleProofV2 do
  use Ecto.Migration

  @shape_check """
  proof_version IN (1, 2) AND
  role IN ('discovery','closure') AND
  boundary IN ('lower_inclusive_upper_exclusive','lower_exclusive_upper_inclusive','provider_native') AND
  octet_length(user_id) BETWEEN 1 AND 320 AND user_id !~ '[[:space:][:cntrl:]]' AND
  octet_length(provider) BETWEEN 1 AND 80 AND provider !~ '[[:space:][:cntrl:]]' AND
  octet_length(cursor_kind) BETWEEN 1 AND 80 AND cursor_kind !~ '[[:space:][:cntrl:]]' AND
  (lower_cursor IS NULL OR octet_length(lower_cursor) BETWEEN 1 AND 4096) AND
  octet_length(upper_cursor) BETWEEN 1 AND 4096 AND
  reason_job_count >= 0 AND reason_job_count <= 20000 AND
  cardinality(reason_job_ids) = reason_job_count AND
  ((reason_job_count = 0 AND finalizer_job_id IS NULL) OR
   (reason_job_count > 0 AND finalizer_job_id IS NOT NULL)) AND
  source_item_count >= 0 AND source_item_count <= 50000 AND
  todo_snapshot_count >= 0 AND todo_snapshot_count <= 20000 AND
  (role = 'closure' OR todo_snapshot_count = 0) AND
  ((role = 'discovery' AND
    ((source_item_count = 0 AND reason_job_count = 0) OR
     (source_item_count > 0 AND reason_job_count > 0))) OR
   (role = 'closure' AND
    ((todo_snapshot_count = 0 AND reason_job_count = 0) OR
     (todo_snapshot_count > 0 AND reason_job_count > 0)))) AND
  captured_at <= sealed_at
  """

  def up do
    execute("ALTER TABLE source_cycles DROP CONSTRAINT source_cycles_shape_check")

    execute(
      "ALTER TABLE source_cycles ADD CONSTRAINT source_cycles_shape_check CHECK (#{@shape_check})"
    )

    execute("ALTER TABLE source_cycles ALTER COLUMN proof_version SET DEFAULT 2")
  end

  def down do
    execute("ALTER TABLE source_cycles ALTER COLUMN proof_version SET DEFAULT 1")
    execute("ALTER TABLE source_cycles DROP CONSTRAINT source_cycles_shape_check")

    execute(
      "ALTER TABLE source_cycles ADD CONSTRAINT source_cycles_shape_check CHECK (#{String.replace(@shape_check, "proof_version IN (1, 2)", "proof_version = 1")})"
    )
  end
end
