defmodule Maraithon.Repo.Migrations.GrantRuntimeSnapshotQuarantineRetention do
  use Ecto.Migration

  def up do
    execute("""
    GRANT DELETE ON TABLE public.snapshot_quarantines TO maraithon_runtime
    """)
  end

  def down do
    execute("""
    REVOKE DELETE ON TABLE public.snapshot_quarantines FROM maraithon_runtime
    """)
  end
end
