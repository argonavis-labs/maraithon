defmodule Maraithon.Repo.Migrations.RaiseChiefBriefItemLimit do
  @moduledoc """
  Raises legacy Chief of Staff recurring brief item defaults.

  Earlier builder defaults stored `brief_max_items` as 3, which can hide real
  open loops from scheduled executive briefs. Runtime and builder defaults now
  use 12, so this moves agents that still hold the old default onto the same
  baseline while preserving non-default choices.
  """

  use Ecto.Migration

  def up do
    execute("""
    UPDATE agents
    SET config = jsonb_set(config, '{brief_max_items}', to_jsonb(12), true)
    WHERE behavior IN ('ai_chief_of_staff', 'founder_followthrough_agent', 'inbox_calendar_advisor')
      AND config #>> '{brief_max_items}' = '3'
    """)

    execute("""
    UPDATE agents
    SET config =
      jsonb_set(config, '{skill_configs,briefing,brief_max_items}', to_jsonb(12), true)
    WHERE behavior IN ('ai_chief_of_staff', 'founder_followthrough_agent', 'inbox_calendar_advisor', 'manifest_agent')
      AND jsonb_typeof(config #> '{skill_configs,briefing}') = 'object'
      AND config #>> '{skill_configs,briefing,brief_max_items}' = '3'
    """)
  end

  def down do
    execute("""
    UPDATE agents
    SET config = jsonb_set(config, '{brief_max_items}', to_jsonb(3), true)
    WHERE behavior IN ('ai_chief_of_staff', 'founder_followthrough_agent', 'inbox_calendar_advisor')
      AND config #>> '{brief_max_items}' = '12'
    """)

    execute("""
    UPDATE agents
    SET config =
      jsonb_set(config, '{skill_configs,briefing,brief_max_items}', to_jsonb(3), true)
    WHERE behavior IN ('ai_chief_of_staff', 'founder_followthrough_agent', 'inbox_calendar_advisor', 'manifest_agent')
      AND jsonb_typeof(config #> '{skill_configs,briefing}') = 'object'
      AND config #>> '{skill_configs,briefing,brief_max_items}' = '12'
    """)
  end
end
