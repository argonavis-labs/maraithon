defmodule Maraithon.Todos.IntakeSnapshot do
  @moduledoc """
  Optimistic concurrency for model-backed intake. Models reason without a
  database lock. A short, per-user write transaction rejects a stale decision
  if the work inventory changed in the meantime. Brief/embedding refreshes do
  not invalidate the snapshot because they do not change the work's identity.
  """
  alias Maraithon.Repo

  def current(user_id) do
    %{rows: [[fingerprint]]} =
      Repo.query!(
        """
        SELECT md5(coalesce(string_agg(
          jsonb_build_array(id, status, dedupe_key, title, summary, next_action,
            owner_user_id, source, source_account_id, source_account_label,
            source_item_id, source_occurred_at, due_at, closed_at, direction,
            counterparty_person_id, counterparty_label,
            metadata->>'duplicate_of_todo_id')::text,
          '' ORDER BY id), ''))
        FROM todos WHERE user_id = $1
        """,
        [user_id]
      )

    fingerprint
  end

  def transaction(user_id, expected, fun) do
    Repo.transaction(fn ->
      Repo.query!("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [
        "maraithon:todo-intake:" <> user_id
      ])

      if is_binary(expected) and current(user_id) != expected,
        do: Repo.rollback(:todo_intake_changed)

      fun.()
    end)
  end
end
