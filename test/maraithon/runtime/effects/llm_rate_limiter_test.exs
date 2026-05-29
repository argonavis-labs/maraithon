defmodule Maraithon.Runtime.Effects.LLMRateLimiterTest do
  use ExUnit.Case, async: false

  alias Maraithon.Runtime.Effects.LLMRateLimiter

  setup do
    limiter_name = :"#{__MODULE__}.#{System.unique_integer([:positive])}"

    limiter =
      start_supervised!(%{
        id: limiter_name,
        start: {LLMRateLimiter, :start_link, [[name: limiter_name]]}
      })

    %{limiter: limiter}
  end

  test "bounds concurrent LLM work", %{limiter: limiter} do
    assert :ok = LLMRateLimiter.checkout(limiter, :default)

    test_pid = self()

    start_supervised!(
      {Task,
       fn -> send(test_pid, {:checkout_result, LLMRateLimiter.checkout(limiter, :default)}) end}
    )

    assert_receive {:checkout_result, {:error, {:llm_busy, retry_after_ms}}}
    assert retry_after_ms > 0

    LLMRateLimiter.checkin(limiter, :default)
    assert :ok = LLMRateLimiter.checkout(limiter, :default)
    LLMRateLimiter.checkin(limiter, :default)
  end

  test "keeps chat and reasoning lanes independent", %{limiter: limiter} do
    assert :ok = LLMRateLimiter.checkout(limiter, :reasoning)

    test_pid = self()

    start_supervised!(
      {Task,
       fn ->
         result = LLMRateLimiter.checkout(limiter, :chat)
         send(test_pid, {:chat_checkout_result, result})

         if result == :ok do
           LLMRateLimiter.checkin(limiter, :chat)
         end
       end}
    )

    assert_receive {:chat_checkout_result, :ok}

    start_supervised!(
      {Task,
       fn ->
         send(
           test_pid,
           {:reasoning_checkout_result, LLMRateLimiter.checkout(limiter, :reasoning)}
         )
       end}
    )

    assert_receive {:reasoning_checkout_result, {:error, {:llm_busy, retry_after_ms}}}
    assert retry_after_ms > 0

    LLMRateLimiter.checkin(limiter, :reasoning)
  end

  test "shares provider rate-limit cooldowns", %{limiter: limiter} do
    LLMRateLimiter.record_rate_limit(limiter, 60_000)

    assert {:error, {:rate_limited, retry_after_ms}} =
             LLMRateLimiter.checkout(limiter, :default)

    assert retry_after_ms > 0
    assert retry_after_ms <= 60_000
  end
end
