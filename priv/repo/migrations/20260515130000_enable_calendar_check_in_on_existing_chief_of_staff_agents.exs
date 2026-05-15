defmodule Maraithon.Repo.Migrations.EnableCalendarCheckInOnExistingChiefOfStaffAgents do
  @moduledoc """
  Adds `calendar_check_in` to `enabled_skills` on every existing
  `ai_chief_of_staff` agent that has an explicit list missing it.

  The skill is in the new default-enabled set, but agents created before it
  was shipped have their enabled_skills frozen in their config — so without
  this backfill the proactive calendar check-ins would never fire on the
  running agent until its config was edited by hand.

  Idempotent: a re-run on an agent that already has the skill is a no-op.
  """

  use Ecto.Migration

  def up do
    execute """
    UPDATE agents
    SET config = jsonb_set(
      config,
      '{enabled_skills}',
      (config -> 'enabled_skills') || '["calendar_check_in"]'::jsonb
    )
    WHERE behavior = 'ai_chief_of_staff'
      AND config ? 'enabled_skills'
      AND jsonb_typeof(config -> 'enabled_skills') = 'array'
      AND NOT (config -> 'enabled_skills' @> '["calendar_check_in"]'::jsonb)
    """
  end

  def down do
    execute """
    UPDATE agents
    SET config = jsonb_set(
      config,
      '{enabled_skills}',
      COALESCE(
        (
          SELECT jsonb_agg(elem)
          FROM jsonb_array_elements(config -> 'enabled_skills') elem
          WHERE elem <> '"calendar_check_in"'::jsonb
        ),
        '[]'::jsonb
      )
    )
    WHERE behavior = 'ai_chief_of_staff'
      AND config ? 'enabled_skills'
      AND config -> 'enabled_skills' @> '["calendar_check_in"]'::jsonb
    """
  end
end
