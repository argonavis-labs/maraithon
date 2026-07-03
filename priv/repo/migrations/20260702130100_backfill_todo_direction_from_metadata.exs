defmodule Maraithon.Repo.Migrations.BackfillTodoDirectionFromMetadata do
  use Ecto.Migration

  @moduledoc """
  Derives the new `todos.direction` column from the legacy, mismatched
  metadata vocabulary the commitment tracker used to write
  (`metadata.commitment_direction`, `metadata.thread_state`, and
  `metadata.conversation_context.momentum_state`).

  Mapping (SPEC 05 R2):
    i_owe | asked_of_me                                -> owed_by_me
    pending_reply | user_owes | waiting_on_*            -> owed_to_me

  Rows with no legacy signal keep the column default (`owed_by_me`), which
  matches "this is on the operator to do" for ordinary self-owned todos.
  """

  def up do
    execute("""
    UPDATE todos
    SET direction = 'owed_by_me'
    WHERE coalesce(
            metadata ->> 'commitment_direction',
            metadata ->> 'thread_state',
            metadata #>> '{conversation_context,momentum_state}'
          ) IN ('i_owe', 'asked_of_me')
    """)

    execute("""
    UPDATE todos
    SET direction = 'owed_to_me'
    WHERE coalesce(
            metadata ->> 'commitment_direction',
            metadata ->> 'thread_state',
            metadata #>> '{conversation_context,momentum_state}'
          ) IN ('pending_reply', 'user_owes')
       OR coalesce(
            metadata ->> 'commitment_direction',
            metadata ->> 'thread_state',
            metadata #>> '{conversation_context,momentum_state}'
          ) LIKE 'waiting_on_%'
    """)
  end

  def down do
    # Backfills are one-directional; nothing to revert. The column default
    # stays in place via the sibling schema migration's down/0.
    :ok
  end
end
