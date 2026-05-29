defmodule Maraithon.LLM.OpenRouterProviderTest do
  use ExUnit.Case, async: false

  alias Maraithon.LLM.OpenRouterProvider

  setup do
    original_runtime = Application.get_env(:maraithon, Maraithon.Runtime)
    original_openrouter = Application.get_env(:maraithon, :openrouter)

    on_exit(fn ->
      if original_runtime do
        Application.put_env(:maraithon, Maraithon.Runtime, original_runtime)
      else
        Application.delete_env(:maraithon, Maraithon.Runtime)
      end

      if original_openrouter do
        Application.put_env(:maraithon, :openrouter, original_openrouter)
      else
        Application.delete_env(:maraithon, :openrouter)
      end
    end)

    :ok
  end

  describe "complete/1" do
    test "returns error when API key is not configured" do
      Application.put_env(:maraithon, Maraithon.Runtime, openrouter_api_key: nil)

      assert {:error, "OPENROUTER_API_KEY not configured"} =
               OpenRouterProvider.complete(%{
                 "messages" => [%{"role" => "user", "content" => "Hello"}]
               })
    end

    test "successfully completes with Bypass" do
      bypass = Bypass.open()

      Application.put_env(:maraithon, Maraithon.Runtime,
        openrouter_api_key: "test_api_key",
        openrouter_model: "qwen/qwen3.7-max",
        openrouter_reasoning_effort: "medium"
      )

      Application.put_env(:maraithon, :openrouter,
        base_url: "http://localhost:#{bypass.port}/api/v1/chat/completions",
        http_referer: "https://maraithon.test",
        app_title: "Maraithon Test"
      )

      Bypass.expect_once(bypass, "POST", "/api/v1/chat/completions", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        params = Jason.decode!(body)

        assert params["model"] == "qwen/qwen3.7-max"
        assert params["max_tokens"] == 2048
        assert params["temperature"] == 0.7
        assert params["reasoning"] == %{"effort" => "medium"}

        assert params["messages"] == [
                 %{"role" => "system", "content" => "You are concise."},
                 %{"role" => "user", "content" => "Hello"}
               ]

        assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer test_api_key"]
        assert Plug.Conn.get_req_header(conn, "http-referer") == ["https://maraithon.test"]
        assert Plug.Conn.get_req_header(conn, "x-openrouter-title") == ["Maraithon Test"]

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          200,
          Jason.encode!(%{
            "id" => "gen-123",
            "model" => "qwen/qwen3.7-max",
            "choices" => [
              %{
                "finish_reason" => "stop",
                "message" => %{
                  "role" => "assistant",
                  "content" => "Hello from Qwen"
                }
              }
            ],
            "usage" => %{
              "prompt_tokens" => 12,
              "completion_tokens" => 18,
              "total_tokens" => 30
            }
          })
        )
      end)

      {:ok, result} =
        OpenRouterProvider.complete(%{
          "messages" => [
            %{"role" => "system", "content" => "You are concise."},
            %{"role" => "user", "content" => "Hello"}
          ]
        })

      assert result.content == "Hello from Qwen"
      assert result.model == "qwen/qwen3.7-max"
      assert result.tokens_in == 12
      assert result.tokens_out == 18
      assert result.finish_reason == "stop"
      assert result.usage.input_rate_per_million == 2.5
      assert result.usage.output_rate_per_million == 7.5
    end

    test "omits reasoning when disabled per request" do
      bypass = Bypass.open()

      Application.put_env(:maraithon, Maraithon.Runtime,
        openrouter_api_key: "test_api_key",
        openrouter_model: "qwen/qwen3.7-max",
        openrouter_reasoning_effort: "medium"
      )

      Application.put_env(:maraithon, :openrouter,
        base_url: "http://localhost:#{bypass.port}/api/v1/chat/completions",
        http_referer: nil,
        app_title: nil
      )

      Bypass.expect_once(bypass, "POST", "/api/v1/chat/completions", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        params = Jason.decode!(body)

        refute Map.has_key?(params, "reasoning")

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          200,
          Jason.encode!(%{
            "model" => "qwen/qwen3.7-max",
            "choices" => [
              %{"finish_reason" => "stop", "message" => %{"content" => "ok"}}
            ],
            "usage" => %{"prompt_tokens" => 1, "completion_tokens" => 1}
          })
        )
      end)

      assert {:ok, _result} =
               OpenRouterProvider.complete(%{
                 "messages" => [%{"role" => "user", "content" => "Hello"}],
                 "reasoning_effort" => "none"
               })
    end

    test "passes minimal reasoning effort through when requested" do
      bypass = Bypass.open()

      Application.put_env(:maraithon, Maraithon.Runtime,
        openrouter_api_key: "test_api_key",
        openrouter_model: "qwen/qwen3.7-max"
      )

      Application.put_env(:maraithon, :openrouter,
        base_url: "http://localhost:#{bypass.port}/api/v1/chat/completions"
      )

      Bypass.expect_once(bypass, "POST", "/api/v1/chat/completions", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        params = Jason.decode!(body)

        assert params["reasoning"] == %{"effort" => "minimal"}

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          200,
          Jason.encode!(%{
            "model" => "qwen/qwen3.7-max",
            "choices" => [
              %{"finish_reason" => "stop", "message" => %{"content" => "ok"}}
            ],
            "usage" => %{"prompt_tokens" => 1, "completion_tokens" => 1}
          })
        )
      end)

      assert {:ok, _result} =
               OpenRouterProvider.complete(%{
                 "messages" => [%{"role" => "user", "content" => "Hello"}],
                 "reasoning_effort" => "minimal"
               })
    end

    test "handles rate limiting" do
      bypass = Bypass.open()

      Application.put_env(:maraithon, Maraithon.Runtime,
        openrouter_api_key: "test_api_key",
        openrouter_model: "qwen/qwen3.7-max"
      )

      Application.put_env(:maraithon, :openrouter,
        base_url: "http://localhost:#{bypass.port}/api/v1/chat/completions"
      )

      Bypass.expect_once(bypass, "POST", "/api/v1/chat/completions", fn conn ->
        conn
        |> Plug.Conn.put_resp_header("retry-after", "7")
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          429,
          Jason.encode!(%{"error" => %{"message" => "Rate limit exceeded"}})
        )
      end)

      assert {:error, {:rate_limited, 7000}} =
               OpenRouterProvider.complete(%{
                 "messages" => [%{"role" => "user", "content" => "Hello"}]
               })
    end

    test "classifies credit exhaustion as terminal quota exhaustion" do
      bypass = Bypass.open()

      Application.put_env(:maraithon, Maraithon.Runtime,
        openrouter_api_key: "test_api_key",
        openrouter_model: "qwen/qwen3.7-max"
      )

      Application.put_env(:maraithon, :openrouter,
        base_url: "http://localhost:#{bypass.port}/api/v1/chat/completions"
      )

      Bypass.expect_once(bypass, "POST", "/api/v1/chat/completions", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          402,
          Jason.encode!(%{
            "error" => %{
              "code" => "insufficient_quota",
              "message" => "Insufficient credits."
            }
          })
        )
      end)

      assert {:error, {:insufficient_quota, "Insufficient credits."}} =
               OpenRouterProvider.complete(%{
                 "messages" => [%{"role" => "user", "content" => "Hello"}]
               })
    end
  end

  describe "stream_complete/2" do
    test "invokes the callback per delta and returns full response" do
      bypass = Bypass.open()

      Application.put_env(:maraithon, Maraithon.Runtime,
        openrouter_api_key: "test_api_key",
        openrouter_model: "qwen/qwen3.7-max"
      )

      Application.put_env(:maraithon, :openrouter,
        base_url: "http://localhost:#{bypass.port}/api/v1/chat/completions"
      )

      events = [
        %{
          "model" => "qwen/qwen3.7-max",
          "choices" => [%{"delta" => %{"content" => "Hello "}, "finish_reason" => nil}]
        },
        %{
          "choices" => [%{"delta" => %{"content" => "world"}, "finish_reason" => nil}]
        },
        %{
          "choices" => [%{"delta" => %{}, "finish_reason" => "stop"}],
          "usage" => %{"prompt_tokens" => 5, "completion_tokens" => 2, "total_tokens" => 7}
        }
      ]

      sse_body =
        Enum.map_join(events, "\n", fn ev -> "data: #{Jason.encode!(ev)}\n" end) <>
          "\ndata: [DONE]\n\n"

      Bypass.expect_once(bypass, "POST", "/api/v1/chat/completions", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        params = Jason.decode!(body)

        assert params["stream"] == true
        assert params["model"] == "qwen/qwen3.7-max"

        conn
        |> Plug.Conn.put_resp_content_type("text/event-stream")
        |> Plug.Conn.resp(200, sse_body)
      end)

      test_pid = self()

      on_chunk = fn delta ->
        send(test_pid, {:delta, delta})
      end

      assert {:ok, result} =
               OpenRouterProvider.stream_complete(
                 %{"messages" => [%{"role" => "user", "content" => "Hi"}]},
                 on_chunk
               )

      assert_receive {:delta, "Hello "}
      assert_receive {:delta, "world"}
      assert result.content == "Hello world"
      assert result.tokens_in == 5
      assert result.tokens_out == 2
      assert result.finish_reason == "stop"
    end
  end
end
