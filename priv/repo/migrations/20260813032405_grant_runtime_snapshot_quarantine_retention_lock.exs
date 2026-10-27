defmodule Maraithon.Repo.Migrations.GrantRuntimeSnapshotQuarantineRetentionLock do
  use Ecto.Migration

  def up do
    execute("""
    GRANT UPDATE (id) ON TABLE public.snapshot_quarantines TO maraithon_runtime
    """)
  end

  def down do
    execute("""
    REVOKE UPDATE (id) ON TABLE public.snapshot_quarantines FROM maraithon_runtime
    """)
  end
end
