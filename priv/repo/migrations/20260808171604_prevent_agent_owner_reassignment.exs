defmodule Maraithon.Repo.Migrations.PreventAgentOwnerReassignment do
  use Ecto.Migration

  def up do
    execute("""
    CREATE OR REPLACE FUNCTION prevent_agent_owner_reassignment()
    RETURNS trigger AS $$
    BEGIN
      IF OLD.user_id IS NOT NULL AND NEW.user_id IS DISTINCT FROM OLD.user_id THEN
        RAISE EXCEPTION 'agents.user_id is immutable once assigned'
          USING ERRCODE = '23514';
      END IF;

      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql
    """)

    execute("DROP TRIGGER IF EXISTS agents_owner_immutable_trigger ON agents")

    execute("""
    CREATE TRIGGER agents_owner_immutable_trigger
    BEFORE UPDATE OF user_id ON agents
    FOR EACH ROW
    EXECUTE FUNCTION prevent_agent_owner_reassignment()
    """)
  end

  def down do
    execute("DROP TRIGGER IF EXISTS agents_owner_immutable_trigger ON agents")
    execute("DROP FUNCTION IF EXISTS prevent_agent_owner_reassignment()")
  end
end
