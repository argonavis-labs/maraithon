defmodule Maraithon.Repo.Migrations.RepairRuntimeNodeMetadataEncoding do
  use Ecto.Migration

  def up do
    execute("LOCK TABLE public.runtime_node_incarnations IN ACCESS EXCLUSIVE MODE")

    execute(
      "ALTER TABLE public.runtime_node_incarnations " <>
        "DISABLE TRIGGER enforce_runtime_node_incarnation_trigger"
    )

    execute("""
    UPDATE public.runtime_node_incarnations
    SET metadata = (metadata #>> '{}')::jsonb
    WHERE jsonb_typeof(metadata) = 'string'
      AND jsonb_typeof((metadata #>> '{}')::jsonb) = 'object'
    """)

    execute(
      "ALTER TABLE public.runtime_node_incarnations " <>
        "ENABLE TRIGGER enforce_runtime_node_incarnation_trigger"
    )

    execute("""
    DO $repair$
    BEGIN
      IF EXISTS (
        SELECT 1
        FROM public.runtime_node_incarnations
        WHERE jsonb_typeof(metadata) IS DISTINCT FROM 'object'
      ) THEN
        RAISE EXCEPTION 'runtime node metadata repair left a non-object value';
      END IF;
    END
    $repair$
    """)
  end

  def down, do: :ok
end
