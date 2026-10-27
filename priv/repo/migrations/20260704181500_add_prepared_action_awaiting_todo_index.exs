defmodule Maraithon.Repo.Migrations.AddPreparedActionAwaitingTodoIndex do
  use Ecto.Migration

  # SPEC 02 R11: close the todo-card Send double-tap *create* race atomically.
  # Confirm execution was already atomic (claim_prepared_action_for_confirmation),
  # but creation was read-then-write, so two near-simultaneous Send taps could
  # both insert independent awaiting_confirmation rows for the same todo.
  #
  # `action_type` is part of the key on purpose: "one prepared send per todo
  # *per channel*" — a slack_post and a gmail_draft_send for the same todo are
  # distinct pending actions and must not collide.
  #
  # The predicate cannot reference `expires_at` (now() is not immutable, so
  # Postgres rejects it in a partial-index WHERE); an expired-but-unswept row
  # is handled at the application layer (SPEC 02 R12: force-expire and retry
  # once in TodoActions.create_prepared_send/3).
  #
  # Plain (non-CONCURRENT) index creation inside the default migration
  # transaction: telegram_prepared_actions is a low-volume table, so the
  # CREATE UNIQUE INDEX lock is acceptable.
  def change do
    create unique_index(
             :telegram_prepared_actions,
             [:user_id, :action_type, "(payload->>'todo_id')"],
             name: :telegram_prepared_actions_awaiting_todo_index,
             where: "status = 'awaiting_confirmation' AND payload->>'todo_id' IS NOT NULL"
           )
  end
end
