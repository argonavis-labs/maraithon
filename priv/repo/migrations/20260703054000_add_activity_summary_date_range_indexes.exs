defmodule Maraithon.Repo.Migrations.AddActivitySummaryDateRangeIndexes do
  use Ecto.Migration

  @moduledoc """
  SPEC 09 R1 review fix: `Maraithon.ActionLedger.activity_summary/2` scans
  `memory_items`, `crm_people`, and `telegram_push_receipts` by
  `user_id` + a date-range-filtered timestamp column for every
  `:today`/`:yesterday`/date/range request. These composite indexes let
  those scans use an index instead of a per-user sequential scan.
  """

  def change do
    create index(:memory_items, [:user_id, :inserted_at])

    create index(:crm_people, [:user_id, :inserted_at])
    create index(:crm_people, [:user_id, :updated_at])

    create index(:telegram_push_receipts, [:user_id, :decision, :inserted_at])
  end
end
