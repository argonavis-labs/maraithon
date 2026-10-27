defmodule Maraithon.Repo.Migrations.LowerBriefingLlmBudgetOnExistingAgents do
  @moduledoc """
  Lower the `llm_max_tokens` and `llm_reasoning_effort` on existing
  `ai_chief_of_staff` agents whose config still has the old aggressive
  defaults (64,000 tokens + `"xhigh"` reasoning).

  Those defaults were exhausting the reasoning-tier per-minute token bucket
  on the primary model in a single brief call, so the morning briefing was
  reliably hitting `{:rate_limited, 60000}` and turning into a user-facing
  failure message. The runtime defaults have been lowered to 16,000 tokens
  and `"high"` reasoning; this migration brings agents created with the
  prior defaults onto the same baseline. Idempotent and only touches
  fields that still hold the prior values — explicit non-default choices
  are preserved.
  """

  use Ecto.Migration

  def up do
    execute """
    UPDATE agents
    SET config = jsonb_set(config, '{llm_max_tokens}', to_jsonb(16000))
    WHERE behavior = 'ai_chief_of_staff'
      AND (config -> 'llm_max_tokens')::int = 64000
    """

    execute """
    UPDATE agents
    SET config = jsonb_set(config, '{llm_reasoning_effort}', '"high"'::jsonb)
    WHERE behavior = 'ai_chief_of_staff'
      AND config ->> 'llm_reasoning_effort' = 'xhigh'
    """
  end

  def down do
    execute """
    UPDATE agents
    SET config = jsonb_set(config, '{llm_max_tokens}', to_jsonb(64000))
    WHERE behavior = 'ai_chief_of_staff'
      AND (config -> 'llm_max_tokens')::int = 16000
    """

    execute """
    UPDATE agents
    SET config = jsonb_set(config, '{llm_reasoning_effort}', '"xhigh"'::jsonb)
    WHERE behavior = 'ai_chief_of_staff'
      AND config ->> 'llm_reasoning_effort' = 'high'
    """
  end
end
