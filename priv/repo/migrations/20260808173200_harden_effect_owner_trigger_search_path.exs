defmodule Maraithon.Repo.Migrations.HardenEffectOwnerTriggerSearchPath do
  use Ecto.Migration

  def up do
    execute("""
    ALTER FUNCTION effects_stamp_owner_user_id()
    SET search_path = pg_catalog, public
    """)
  end

  def down do
    execute("""
    ALTER FUNCTION effects_stamp_owner_user_id()
    RESET search_path
    """)
  end
end
