defmodule Maraithon.LLM.OpenRouterUsageTest do
  use ExUnit.Case, async: false
  alias Maraithon.LLM.{OpenRouterProvider, OpenRouterUsage}

  setup do
    runtime = Application.get_env(:maraithon, Maraithon.Runtime)
    provider = Application.get_env(:maraithon, :openrouter)
    handler = "usage-test-#{System.unique_integer([:positive])}"
    parent = self()

    :ok =
      :telemetry.attach(
        handler,
        [:maraithon, :llm, :attempt],
        fn _, measurements, metadata, pid -> send(pid, {:measured, measurements, metadata}) end,
        parent
      )

    bypass = Bypass.open()
    Application.put_env(:maraithon, Maraithon.Runtime, openrouter_api_key: "controlled-key")

    Application.put_env(:maraithon, :openrouter,
      base_url: "http://localhost:#{bypass.port}/api/v1/chat/completions"
    )

    on_exit(fn ->
      Application.put_env(:maraithon, Maraithon.Runtime, runtime)
      Application.put_env(:maraithon, :openrouter, provider)
      :telemetry.detach(handler)
    end)

    %{bypass: bypass}
  end

  test "reported cost overrides the price-table estimate, including a free response", %{
    bypass: bypass
  } do
    for reported <- [0, 0.00003172] do
      Bypass.expect_once(bypass, "POST", "/api/v1/chat/completions", fn conn ->
        json(conn, completion("stop", reported))
      end)

      assert {:ok, result} = OpenRouterProvider.complete(params())
      assert result.usage.total_cost == reported
      assert result.usage.cost_source == "provider_reported"
      assert result.usage.estimated_total_cost > 0
      assert_receive {:measured, usage, _}
      assert usage.cost_usd == reported
      assert usage.input_tokens == 120
      assert usage.output_tokens == 20
      assert usage.cache_read_tokens == 80
      assert usage.reasoning_tokens == 4
      assert usage.duration_ms >= 0
      assert usage.status == "completed"
      refute_received {:measured, _, _}
    end
  end

  test "incomplete responses retain their billed usage even when the harness must retry", %{
    bypass: bypass
  } do
    Bypass.expect_once(bypass, "POST", "/api/v1/chat/completions", fn conn ->
      json(conn, completion("length", 0.002))
    end)

    assert {:error, {:incomplete_response, _}} = OpenRouterProvider.complete(params())
    assert_receive {:measured, %{status: "failed", cost_usd: 0.002, output_tokens: 20}, _}
    refute_received {:measured, _, _}
  end

  test "streaming records the final usage once without adding reasoning to output", %{
    bypass: bypass
  } do
    Bypass.expect_once(bypass, "POST", "/api/v1/chat/completions", fn conn ->
      events = [
        %{
          "choices" => [
            %{"index" => 0, "delta" => %{"content" => "Hello"}, "finish_reason" => nil}
          ]
        },
        %{"choices" => [%{"index" => 0, "delta" => %{}, "finish_reason" => "stop"}]},
        %{"choices" => [], "usage" => completion("stop", 0.007)["usage"]}
      ]

      body =
        Enum.map_join(events, "", &("data: " <> Jason.encode!(&1) <> "\n\n")) <>
          "data: [DONE]\n\n"

      conn |> Plug.Conn.put_resp_content_type("text/event-stream") |> Plug.Conn.resp(200, body)
    end)

    assert {:ok, %{usage: %{total_cost: 0.007}}} =
             OpenRouterProvider.stream_complete(params(), fn _ -> :ok end)

    assert_receive {:measured, %{cost_usd: 0.007, status: "completed"} = measured, _}
    refute Map.has_key?(measured, :reasoning)
    refute_received {:measured, _, _}
  end

  test "missing usage and failed requests stay unknown instead of appearing free", %{
    bypass: bypass
  } do
    Bypass.expect_once(bypass, "POST", "/api/v1/chat/completions", fn conn ->
      Plug.Conn.resp(conn, 503, "unavailable")
    end)

    assert {:error, _} = OpenRouterProvider.complete(params())
    assert_receive {:measured, %{cost_usd: nil, input_tokens: nil, cost_source: "unavailable"}, _}

    for raw <- [
          %{},
          %{"prompt_tokens" => -1, "completion_tokens" => "secret", "cost" => "secret"}
        ] do
      assert %{cost_usd: nil, estimated_cost_usd: nil, cost_source: "unavailable"} =
               OpenRouterUsage.summary(%{"usage" => raw}, "qwen/qwen3.7-max")
    end

    assert %{cost_usd: nil, estimated_cost_usd: estimate, cost_source: "estimated"} =
             OpenRouterUsage.summary(
               %{"usage" => %{"prompt_tokens" => 120, "completion_tokens" => 20}},
               "qwen/qwen3.7-max"
             )

    assert estimate > 0
  end

  test "production log fields preserve cost provenance and reject free text" do
    entry =
      Maraithon.LogFormatter.format(:info, "LLM attempt measured", {{2026, 9, 8}, {12, 0, 0, 0}},
        cost_source: "provider_reported",
        estimated_cost_usd: 0.01,
        cost_usd: 0.002,
        target_reference: Ecto.UUID.generate()
      )
      |> IO.iodata_to_binary()
      |> Jason.decode!()

    assert entry["cost_source"] == "provider_reported"
    assert entry["estimated_cost_usd"] == 0.01
    assert entry["cost_usd"] == 0.002

    assert Maraithon.Redaction.log_metadata_value(:cost_source, "private email contents") ==
             "redacted_detail"
  end

  defp params,
    do: %{
      "model" => "qwen/qwen3.7-max",
      "messages" => [%{"role" => "user", "content" => "Hello"}]
    }

  defp json(conn, body),
    do:
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(body))

  defp completion(finish, cost),
    do: %{
      "model" => "qwen/qwen3.7-max",
      "choices" => [
        %{"message" => %{"role" => "assistant", "content" => "Hello"}, "finish_reason" => finish}
      ],
      "usage" => %{
        "prompt_tokens" => 120,
        "completion_tokens" => 20,
        "cost" => cost,
        "prompt_tokens_details" => %{"cached_tokens" => 80},
        "completion_tokens_details" => %{"reasoning_tokens" => 4}
      }
    }
end
