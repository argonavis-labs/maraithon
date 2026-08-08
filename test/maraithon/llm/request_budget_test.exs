defmodule Maraithon.LLM.RequestBudgetTest do
  use ExUnit.Case, async: true

  alias Maraithon.LLM.RequestBudget
  alias Maraithon.TelegramAssistant.ProactiveCandidate

  test "keeps the proactive queue binary cap unless a caller opts into a larger one" do
    value = %{"content" => String.duplicate("x", 64_001)}

    refute ProactiveCandidate.safe_json_shape?(value, 128_000)
    assert ProactiveCandidate.safe_json_shape?(value, 128_000, 128_000)
  end

  test "accepts one large prompt when the complete request remains within budget" do
    content = String.duplicate("x", 77_469)

    assert {:ok, bounded} =
             RequestBudget.validate(%{
               "messages" => [
                 %{"role" => "system", "content" => "system"},
                 %{"role" => "user", "content" => content}
               ],
               "model" => "qwen/qwen3.7-plus",
               "max_tokens" => 6_000,
               "reasoning_effort" => "none"
             })

    assert get_in(bounded, ["messages", Access.at(1), "content"]) == content
    assert :ok = RequestBudget.validate_body(bounded)
  end

  test "allows one message to use the provider request budget beyond candidate field limits" do
    content = String.duplicate("x", 80_000)

    assert {:ok, %{"messages" => [%{"content" => ^content}]}} =
             RequestBudget.validate(%{
               "messages" => [%{"role" => "user", "content" => content}]
             })

    assert :ok =
             RequestBudget.validate_body(%{
               "messages" => [%{"role" => "user", "content" => content}]
             })
  end

  test "rejects escape-expanded requests at the final encoded-byte boundary" do
    content = String.duplicate("\\\"", 30_000)

    assert {:error, {:invalid_request, %{reason: "request_exceeds_budget"}}} =
             RequestBudget.validate(%{
               "messages" => [
                 %{"role" => "user", "content" => content},
                 %{"role" => "user", "content" => content}
               ]
             })
  end

  test "rejects improper and over-cardinality message/tool lists" do
    improper = [%{"role" => "user", "content" => "ok"} | :improper]
    messages = List.duplicate(%{"role" => "user", "content" => "ok"}, 65)
    tools = List.duplicate(%{"type" => "function", "name" => "safe"}, 65)

    for params <- [
          %{"messages" => improper},
          %{"messages" => messages},
          %{"messages" => [], "tools" => tools}
        ] do
      assert {:error, {:invalid_request, _reason}} = RequestBudget.validate(params)
    end
  end

  test "caps request limits, drops invalid labels, and preserves callback out of band" do
    callback = fn _delta -> :ok end

    assert {:ok, bounded} =
             RequestBudget.validate(%{
               "messages" => [%{"role" => "user", "content" => "hello"}],
               "model" => String.duplicate("m", 1_000_000),
               "max_tokens" => 1_000_000,
               "timeout_ms" => 1_200_000,
               "reasoning_effort" => String.duplicate("high", 1_000_000),
               "_on_reasoning" => callback
             })

    refute Map.has_key?(bounded, "model")
    refute Map.has_key?(bounded, "reasoning_effort")

    assert {:ok, invalid_utf8} =
             RequestBudget.validate(%{
               "messages" => [],
               "model" => <<255, 254>>
             })

    refute Map.has_key?(invalid_utf8, "model")
    assert bounded["max_tokens"] == 32_000
    assert bounded["timeout_ms"] == 300_000
    assert bounded["_on_reasoning"] == callback
  end

  test "projects nested reasoning to known bounded provider fields" do
    assert {:ok, bounded} =
             RequestBudget.validate(%{
               "messages" => [],
               "reasoning" => %{
                 "effort" => "high",
                 "max_tokens" => 999_999_999,
                 "exclude" => true,
                 "unknown" => String.duplicate("x", 200_000)
               }
             })

    assert bounded["reasoning"] == %{
             "effort" => "high",
             "max_tokens" => 32_000,
             "exclude" => true
           }
  end

  test "keeps valid base requests when optional context would overflow" do
    base = %{
      "messages" => [%{"role" => "user", "content" => String.duplicate("x", 120_000)}]
    }

    assert {:ok, _bounded} = RequestBudget.validate(base)

    assert RequestBudget.put_optional_context(base, fn params ->
             Map.update!(params, "messages", fn messages ->
               [%{"role" => "system", "content" => String.duplicate("y", 20_000)} | messages]
             end)
           end) == base
  end

  test "admits fitting optional context and fails safely when an injector raises" do
    base = %{"messages" => [%{"role" => "user", "content" => "hello"}]}
    context = %{"role" => "system", "content" => "bounded context"}

    assert %{"messages" => [^context, %{"content" => "hello"}]} =
             RequestBudget.put_optional_context(base, fn params ->
               Map.update!(params, "messages", &[context | &1])
             end)

    assert RequestBudget.put_optional_context(base, fn _params -> raise "unavailable" end) == base
  end

  test "canonicalizes valid bases before optional injection" do
    params = %{
      messages: [%{role: "user", content: "hello"}],
      max_tokens: 100_000,
      unknown: "drop me"
    }

    assert %{
             "messages" => [
               %{"role" => "system", "content" => "context"},
               %{role: "user", content: "hello"}
             ],
             "max_tokens" => 32_000
           } =
             RequestBudget.put_optional_context(params, fn base ->
               refute Map.has_key?(base, :messages)
               refute Map.has_key?(base, :unknown)

               Map.update!(base, "messages", fn messages ->
                 [%{"role" => "system", "content" => "context"} | messages]
               end)
             end)
  end

  test "does not invoke optional context for an invalid base" do
    invalid = %{
      "messages" => List.duplicate(%{"role" => "user", "content" => "too many"}, 65)
    }

    assert RequestBudget.put_optional_context(invalid, fn _base ->
             send(self(), :injector_invoked)
             %{}
           end) == invalid

    refute_received :injector_invoked
  end

  test "retains earlier accepted context when later optional context overflows" do
    base = %{"messages" => [%{"role" => "user", "content" => "request"}]}

    with_memory =
      RequestBudget.put_optional_context(base, fn params ->
        Map.update!(params, "messages", fn messages ->
          [%{"role" => "system", "content" => String.duplicate("m", 60_000)} | messages]
        end)
      end)

    assert with_memory != base

    assert RequestBudget.put_optional_context(with_memory, fn params ->
             Map.update!(params, "messages", fn messages ->
               [%{"role" => "system", "content" => String.duplicate("o", 80_000)} | messages]
             end)
           end) == with_memory
  end
end
