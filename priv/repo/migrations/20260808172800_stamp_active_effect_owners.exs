defmodule Maraithon.Repo.Migrations.StampActiveEffectOwners do
  use Ecto.Migration

  def up do
    execute("""
    CREATE OR REPLACE FUNCTION effects_stamp_owner_user_id()
    RETURNS trigger AS $$
    BEGIN
      SELECT user_id INTO NEW.owner_user_id
      FROM agents
      WHERE id = NEW.agent_id;

      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql
    SET search_path = pg_catalog, public
    """)

    execute("DROP TRIGGER IF EXISTS effects_stamp_owner_user_id_trigger ON effects")

    execute("""
    CREATE TRIGGER effects_stamp_owner_user_id_trigger
    BEFORE INSERT OR UPDATE OF agent_id, owner_user_id ON effects
    FOR EACH ROW
    EXECUTE FUNCTION effects_stamp_owner_user_id()
    """)
  end

  def down do
    execute("DROP TRIGGER IF EXISTS effects_stamp_owner_user_id_trigger ON effects")
    execute("DROP FUNCTION IF EXISTS effects_stamp_owner_user_id()")
  end
end
