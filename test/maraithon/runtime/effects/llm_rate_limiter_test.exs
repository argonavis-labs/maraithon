defmodule Maraithon.Runtime.Effects.LLMRateLimiterTest do
  use ExUnit.Case, async: false

  alias Maraithon.Runtime.Effects.LLMRateLimiter

  setup do
    LLMRateLimiter.reset()

    on_exit(fn -> LLMRateLimiter.reset() end)

    :ok
  end

  test "bounds concurrent LLM work" do
    assert :ok = LLMRateLimiter.checkout()
    assert {:error, {:llm_busy, retry_after_ms}} = LLMRateLimiter.checkout()
    assert retry_after_ms > 0

    LLMRateLimiter.checkin()
    assert :ok = LLMRateLimiter.checkout()
    LLMRateLimiter.checkin()
  end

  test "shares provider rate-limit cooldowns" do
    LLMRateLimiter.record_rate_limit(60_000)

    assert {:error, {:rate_limited, retry_after_ms}} = LLMRateLimiter.checkout()
    assert retry_after_ms > 0
    assert retry_after_ms <= 60_000
  end
end
