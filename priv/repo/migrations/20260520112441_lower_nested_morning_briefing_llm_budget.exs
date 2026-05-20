defmodule Maraithon.Repo.Migrations.LowerNestedMorningBriefingLlmBudget do
  use Ecto.Migration

  @moduledoc """
  Normalizes legacy nested `morning_briefing` LLM settings.

  The earlier migration corrected top-level Chief of Staff config keys, but
  production agents can also carry skill-specific overrides under
  `skill_configs.morning_briefing`. Those nested overrides win at runtime, so
  a stale `xhigh`/64k override can keep the scheduled brief on a rate-limit
  path even after the top-level config was fixed.
  """

  def up do
    execute("""
    UPDATE agents
    SET config =
      jsonb_set(
        config,
        '{skill_configs,morning_briefing,llm_max_tokens}',
        to_jsonb(16000),
        true
      )
    WHERE behavior IN ('ai_chief_of_staff', 'manifest_agent')
      AND jsonb_typeof(config #> '{skill_configs,morning_briefing}') = 'object'
      AND (config #>> '{skill_configs,morning_briefing,llm_max_tokens}') ~ '^[0-9]+$'
      AND (config #>> '{skill_configs,morning_briefing,llm_max_tokens}')::int > 16000
    """)

    execute("""
    UPDATE agents
    SET config =
      jsonb_set(
        config,
        '{skill_configs,morning_briefing,llm_reasoning_effort}',
        '"high"'::jsonb,
        true
      )
    WHERE behavior IN ('ai_chief_of_staff', 'manifest_agent')
      AND jsonb_typeof(config #> '{skill_configs,morning_briefing}') = 'object'
      AND lower(config #>> '{skill_configs,morning_briefing,llm_reasoning_effort}') = 'xhigh'
    """)
  end

  def down do
    execute("""
    UPDATE agents
    SET config =
      jsonb_set(
        config,
        '{skill_configs,morning_briefing,llm_max_tokens}',
        to_jsonb(64000),
        true
      )
    WHERE behavior IN ('ai_chief_of_staff', 'manifest_agent')
      AND jsonb_typeof(config #> '{skill_configs,morning_briefing}') = 'object'
      AND (config #>> '{skill_configs,morning_briefing,llm_max_tokens}') ~ '^[0-9]+$'
      AND (config #>> '{skill_configs,morning_briefing,llm_max_tokens}')::int = 16000
    """)

    execute("""
    UPDATE agents
    SET config =
      jsonb_set(
        config,
        '{skill_configs,morning_briefing,llm_reasoning_effort}',
        '"xhigh"'::jsonb,
        true
      )
    WHERE behavior IN ('ai_chief_of_staff', 'manifest_agent')
      AND jsonb_typeof(config #> '{skill_configs,morning_briefing}') = 'object'
      AND config #>> '{skill_configs,morning_briefing,llm_reasoning_effort}' = 'high'
    """)
  end
end
