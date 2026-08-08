defmodule Maraithon.LLM.OpenRouterProviderTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

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

    test "returns a diagnostic error when a completion has no assistant content" do
      bypass = Bypass.open()

      Application.put_env(:maraithon, Maraithon.Runtime,
        openrouter_api_key: "test_api_key",
        openrouter_model: "qwen/qwen3.7-plus"
      )

      Application.put_env(:maraithon, :openrouter,
        base_url: "http://localhost:#{bypass.port}/api/v1/chat/completions"
      )

      Bypass.expect_once(bypass, "POST", "/api/v1/chat/completions", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          200,
          Jason.encode!(%{
            "model" => "qwen/qwen3.7-plus",
            "choices" => [
              %{"finish_reason" => "length", "message" => %{"content" => ""}}
            ],
            "usage" => %{
              "prompt_tokens" => 65_000,
              "completion_tokens" => 1_200,
              "total_tokens" => 66_200
            }
          })
        )
      end)

      log =
        capture_log([level: :warning], fn ->
          assert {:error, {:invalid_response, summary}} =
                   OpenRouterProvider.complete(%{
                     "messages" => [%{"role" => "user", "content" => "Hello"}]
                   })

          assert summary.model == "qwen/qwen3.7-plus"
          assert summary.finish_reason == "length"
          assert summary.usage.input_tokens == 65_000
          assert summary.usage.output_tokens == 1_200
        end)

      assert log =~ "LLM call returned empty content"
    end

    test "explicitly disables reasoning when requested" do
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

      Bypass.expect(bypass, "POST", "/api/v1/chat/completions", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        params = Jason.decode!(body)

        assert params["reasoning"] == %{"enabled" => false}

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

      assert {:ok, _result} =
               OpenRouterProvider.complete(%{
                 "messages" => [%{"role" => "user", "content" => "Hello"}],
                 "reasoning" => %{"effort" => "off"}
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

    test "logs empty model responses with safe numeric telemetry" do
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
          200,
          Jason.encode!(%{
            "model" => "qwen/qwen3.7-max",
            "choices" => [
              %{
                "finish_reason" => "length",
                "message" => %{
                  "content" => " \n\t",
                  "reasoning" => "provider-internal-reasoning"
                }
              }
            ],
            "usage" => %{
              "prompt_tokens" => String.duplicate("9", 100_000),
              "completion_tokens" => -45,
              "completion_tokens_details" => %{"reasoning_tokens" => 321}
            }
          })
        )
      end)

      log =
        ExUnit.CaptureLog.capture_log([level: :warning], fn ->
          assert {:error, {:invalid_response, summary}} =
                   OpenRouterProvider.complete(%{
                     "messages" => [%{"role" => "user", "content" => "Hello"}]
                   })

          assert summary.usage.input_tokens == 0
          assert summary.usage.output_tokens == 0
          assert summary.usage.reasoning_tokens == 321
        end)

      assert log =~ "LLM call returned empty content"
      refute log =~ "provider-internal-reasoning"
    end

    test "rejects map and unknown-block content without inspecting it" do
      Application.put_env(:maraithon, Maraithon.Runtime,
        openrouter_api_key: "test_api_key",
        openrouter_model: "qwen/qwen3.7-max"
      )

      Enum.each(
        [
          {%{"reasoning" => "map-content-prompt-echo-secret"}, "map-content-prompt-echo-secret"},
          {[%{"reasoning" => "block-content-prompt-echo-secret"}],
           "block-content-prompt-echo-secret"}
        ],
        fn {content, echoed_secret} ->
          bypass = Bypass.open()

          Application.put_env(:maraithon, :openrouter,
            base_url: "http://localhost:#{bypass.port}/api/v1/chat/completions"
          )

          Bypass.expect_once(bypass, "POST", "/api/v1/chat/completions", fn conn ->
            conn
            |> Plug.Conn.put_resp_content_type("application/json")
            |> Plug.Conn.resp(
              200,
              Jason.encode!(%{
                "model" => "qwen/qwen3.7-max",
                "choices" => [
                  %{"finish_reason" => "stop", "message" => %{"content" => content}}
                ],
                "usage" => %{}
              })
            )
          end)

          log =
            ExUnit.CaptureLog.capture_log([level: :warning], fn ->
              assert {:error, {:invalid_response, _summary}} =
                       OpenRouterProvider.complete(%{
                         "messages" => [%{"role" => "user", "content" => "Hello"}]
                       })
            end)

          refute log =~ echoed_secret
        end
      )
    end

    test "returns a structured error for a non-object success body" do
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
        |> Plug.Conn.resp(200, Jason.encode!(["prompt-echo-secret"]))
      end)

      log =
        ExUnit.CaptureLog.capture_log([level: :warning], fn ->
          assert {:error, {:invalid_response, summary}} =
                   OpenRouterProvider.complete(%{
                     "messages" => [%{"role" => "user", "content" => "Hello"}]
                   })

          assert summary.reason == "invalid_response_shape"
          assert summary.response_shape == "list"

          assert summary.usage == %{
                   input_tokens: 0,
                   output_tokens: 0,
                   reasoning_tokens: 0,
                   total_tokens: 0
                 }
        end)

      assert log =~ "invalid response shape"
      refute log =~ "prompt-echo-secret"
    end

    test "normalizes a malformed nested usage object" do
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
          200,
          Jason.encode!(%{
            "model" => "provider echoed prompt-echo-secret",
            "choices" => [
              %{
                "finish_reason" => "provider prompt-echo-secret",
                "message" => %{"content" => "safe response"}
              }
            ],
            "usage" => "provider-internal-reasoning"
          })
        )
      end)

      assert {:error, {:invalid_response, %{reason: "invalid_finish_reason"}}} =
               OpenRouterProvider.complete(%{
                 "messages" => [%{"role" => "user", "content" => "Hello"}]
               })
    end

    test "halts oversized success responses before decoding provider JSON" do
      bypass = Bypass.open()

      Application.put_env(:maraithon, Maraithon.Runtime,
        openrouter_api_key: "test_api_key",
        openrouter_model: "qwen/qwen3.7-max"
      )

      Application.put_env(:maraithon, :openrouter,
        base_url: "http://localhost:#{bypass.port}/api/v1/chat/completions"
      )

      Bypass.expect_once(bypass, "POST", "/api/v1/chat/completions", fn conn ->
        body =
          Jason.encode!(%{
            "choices" => [
              %{"message" => %{"content" => String.duplicate("x", 600_000)}}
            ]
          })

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, body)
      end)

      assert {:error, {:invalid_response, summary}} =
               OpenRouterProvider.complete(%{
                 "messages" => [%{"role" => "user", "content" => "Hello"}]
               })

      assert summary.reason == "response_body_too_large"
    end

    test "HTTP failures never log provider response bodies" do
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
          500,
          Jason.encode!(%{"error" => %{"message" => "prompt-echo-secret"}})
        )
      end)

      log =
        ExUnit.CaptureLog.capture_log([level: :error], fn ->
          assert {:error, {:api_error, 500, body}} =
                   OpenRouterProvider.complete(%{
                     "messages" => [%{"role" => "user", "content" => "Hello"}]
                   })

          assert body == :redacted
        end)

      assert log =~ "OpenRouter API error"
      refute log =~ "prompt-echo-secret"
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

    test "parses retry-after headers according to their declared units" do
      Enum.each(
        [{"retry-after-ms", "500", 500}, {"retry-after", "1000", 1_000_000}],
        fn {header, value, expected_ms} ->
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
            |> Plug.Conn.put_resp_header(header, value)
            |> Plug.Conn.put_resp_content_type("application/json")
            |> Plug.Conn.resp(429, Jason.encode!(%{"error" => %{"message" => "busy"}}))
          end)

          assert {:error, {:rate_limited, ^expected_ms}} =
                   OpenRouterProvider.complete(%{
                     "messages" => [%{"role" => "user", "content" => "Hello"}]
                   })
        end
      )
    end

    test "bounds pathological retry-after header and body strings" do
      Enum.each([:header, :body], fn source ->
        bypass = Bypass.open()

        Application.put_env(:maraithon, Maraithon.Runtime,
          openrouter_api_key: "test_api_key",
          openrouter_model: "qwen/qwen3.7-max"
        )

        Application.put_env(:maraithon, :openrouter,
          base_url: "http://localhost:#{bypass.port}/api/v1/chat/completions"
        )

        Bypass.expect_once(bypass, "POST", "/api/v1/chat/completions", fn conn ->
          conn =
            if source == :header,
              do: Plug.Conn.put_resp_header(conn, "retry-after", String.duplicate("9", 100_000)),
              else: conn

          message =
            if source == :body,
              do: "retry after " <> String.duplicate("9", 100_000),
              else: "busy"

          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.resp(429, Jason.encode!(%{"error" => %{"message" => message}}))
        end)

        assert {:error, {:rate_limited, 60_000}} =
                 OpenRouterProvider.complete(%{
                   "messages" => [%{"role" => "user", "content" => "Hello"}]
                 })
      end)
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

      assert {:error, {:insufficient_quota, "OpenRouter quota exceeded"}} =
               OpenRouterProvider.complete(%{
                 "messages" => [%{"role" => "user", "content" => "Hello"}]
               })
    end
  end

  test "kills a blocked request worker when its owner dies" do
    bypass = Bypass.open()
    test_pid = self()

    Application.put_env(:maraithon, Maraithon.Runtime,
      openrouter_api_key: "test_api_key",
      openrouter_model: "qwen/qwen3.7-max"
    )

    Application.put_env(:maraithon, :openrouter,
      base_url: "http://localhost:#{bypass.port}/api/v1/chat/completions",
      request_worker_observer: test_pid
    )

    Bypass.expect_once(bypass, "POST", "/api/v1/chat/completions", fn conn ->
      send(test_pid, {:blocked_request_started, self()})

      receive do
        :release_blocked_request -> Plug.Conn.resp(conn, 200, ~s({"choices":[]}))
      after
        5_000 -> Plug.Conn.resp(conn, 504, "")
      end
    end)

    owner =
      spawn(fn ->
        OpenRouterProvider.complete(%{
          "messages" => [%{"role" => "user", "content" => "Hi"}],
          "timeout_ms" => 10_000
        })
      end)

    assert_receive {:openrouter_request_worker, worker}, 1_000
    assert_receive {:blocked_request_started, handler}, 1_000
    worker_ref = Process.monitor(worker)

    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^worker_ref, :process, ^worker, :killed}, 1_000
    send(handler, :release_blocked_request)
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

      assert_receive {:delta, "Hello world"}
      refute_receive {:delta, _additional}
      assert result.content == "Hello world"
      assert result.tokens_in == 5
      assert result.tokens_out == 2
      assert result.finish_reason == "stop"
    end

    test "parses CRLF split exactly across transport chunks" do
      caller = self()

      event =
        "data: " <>
          Jason.encode!(%{
            "choices" => [
              %{"delta" => %{"content" => "Hello"}, "finish_reason" => "stop"}
            ]
          })

      stream = event <> "\r\n\r\ndata: [DONE]\r\n\r\n"
      split_at = :binary.match(stream, "\r\n") |> elem(0)
      first = binary_part(stream, 0, split_at + 1)
      second = binary_part(stream, split_at + 1, byte_size(stream) - split_at - 1)

      assert {:ok, response} =
               OpenRouterProvider.parse_stream_chunks([first, second], fn delta ->
                 send(caller, {:chunk_process, self(), delta})
               end)

      assert response.content == "Hello"
      assert_received {:chunk_process, ^caller, "Hello"}
    end

    test "accepts terminal SSE framed with bare carriage returns" do
      stream =
        "data: " <>
          Jason.encode!(%{
            "choices" => [
              %{"delta" => %{"content" => "Bare CR"}, "finish_reason" => "stop"}
            ]
          }) <>
          "\r\rdata: [DONE]\r\r"

      assert {:ok, response} =
               OpenRouterProvider.parse_stream_chunks([stream], fn _delta -> :ok end)

      assert response.content == "Bare CR"
    end

    test "rejects data after DONE in the same transport chunk" do
      finish =
        "data: " <>
          Jason.encode!(%{"choices" => [%{"delta" => %{}, "finish_reason" => "stop"}]})

      post_done =
        "data: " <>
          Jason.encode!(%{"choices" => [%{"delta" => %{"content" => "late"}}]})

      stream = finish <> "\n\ndata: [DONE]\n\n" <> post_done <> "\n\n"

      assert {:error, {:invalid_response, summary}} =
               OpenRouterProvider.parse_stream_chunks([stream], fn _delta -> :ok end)

      assert summary.reason == "stream_data_after_done"
    end

    test "rejects cumulative streamed text without exposing unvalidated deltas" do
      caller = self()
      first = String.duplicate("a", 70_000)
      crossing = String.duplicate("b", 70_000)

      stream =
        [first, crossing]
        |> Enum.map_join("", fn delta ->
          "data: " <>
            Jason.encode!(%{
              "choices" => [
                %{"delta" => %{"content" => delta}, "finish_reason" => nil}
              ]
            }) <>
            "\n\n"
        end)

      assert {:error, {:invalid_response, summary}} =
               OpenRouterProvider.parse_stream_chunks([stream], fn delta ->
                 send(caller, {:bounded_delta, delta})
               end)

      assert summary.reason == "stream_text_too_large"
      refute_received {:bounded_delta, ^first}
      refute_received {:bounded_delta, ^crossing}
    end

    test "executes streamed callbacks in the provider caller process" do
      bypass = Bypass.open()
      caller = self()

      Application.put_env(:maraithon, Maraithon.Runtime,
        openrouter_api_key: "test_api_key",
        openrouter_model: "qwen/qwen3.7-max"
      )

      Application.put_env(:maraithon, :openrouter,
        base_url: "http://localhost:#{bypass.port}/api/v1/chat/completions"
      )

      body =
        "data: " <>
          Jason.encode!(%{
            "choices" => [
              %{"delta" => %{"content" => "Hi"}, "finish_reason" => "stop"}
            ]
          }) <>
          "\n\ndata: [DONE]\n\n"

      Bypass.expect_once(bypass, "POST", "/api/v1/chat/completions", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("text/event-stream")
        |> Plug.Conn.resp(200, body)
      end)

      assert {:ok, %{content: "Hi"}} =
               OpenRouterProvider.stream_complete(
                 %{"messages" => [%{"role" => "user", "content" => "Hi"}]},
                 fn delta -> send(caller, {:callback_identity, self(), delta}) end
               )

      assert_received {:callback_identity, ^caller, "Hi"}
    end

    test "classifies bounded streaming 429 bodies without leaking detail" do
      Enum.each(
        [
          {%{"error" => %{"code" => "insufficient_quota", "message" => "private credits"}},
           {:insufficient_quota, "OpenRouter quota exceeded"}},
          {%{"error" => %{"message" => "retry after 2 seconds private detail"}},
           {:rate_limited, 2_000}}
        ],
        fn {response_body, expected_reason} ->
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
            |> Plug.Conn.resp(429, Jason.encode!(response_body))
          end)

          assert {:error, ^expected_reason} =
                   OpenRouterProvider.stream_complete(
                     %{"messages" => [%{"role" => "user", "content" => "Hi"}]},
                     fn _delta -> :ok end
                   )
        end
      )
    end

    test "returns retryable invalid_response for an empty 200 stream" do
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
        |> Plug.Conn.put_resp_content_type("text/event-stream")
        |> Plug.Conn.resp(200, "")
      end)

      assert {:error, {:invalid_response, summary}} =
               OpenRouterProvider.stream_complete(
                 %{"messages" => [%{"role" => "user", "content" => "Hi"}]},
                 fn _delta -> :ok end
               )

      assert summary.reason == "stream_missing_events"
    end

    test "accepts CRLF SSE only after a terminal finish and DONE event" do
      bypass = Bypass.open()

      Application.put_env(:maraithon, Maraithon.Runtime,
        openrouter_api_key: "test_api_key",
        openrouter_model: "qwen/qwen3.7-max"
      )

      Application.put_env(:maraithon, :openrouter,
        base_url: "http://localhost:#{bypass.port}/api/v1/chat/completions"
      )

      event = %{
        "model" => "qwen/qwen3.7-max",
        "choices" => [%{"delta" => %{"content" => "complete"}, "finish_reason" => "stop"}],
        "usage" => %{"prompt_tokens" => 2, "completion_tokens" => 1}
      }

      body = "data: #{Jason.encode!(event)}\r\n\r\ndata: [DONE]\r\n\r\n"

      Bypass.expect_once(bypass, "POST", "/api/v1/chat/completions", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("text/event-stream")
        |> Plug.Conn.resp(200, body)
      end)

      assert {:ok, result} =
               OpenRouterProvider.stream_complete(
                 %{"messages" => [%{"role" => "user", "content" => "Hi"}]},
                 fn _delta -> :ok end
               )

      assert result.content == "complete"
      assert result.finish_reason == "stop"
    end

    test "rejects a partial answer when the stream has no DONE event" do
      bypass = Bypass.open()

      Application.put_env(:maraithon, Maraithon.Runtime,
        openrouter_api_key: "test_api_key",
        openrouter_model: "qwen/qwen3.7-max"
      )

      Application.put_env(:maraithon, :openrouter,
        base_url: "http://localhost:#{bypass.port}/api/v1/chat/completions"
      )

      event = %{
        "model" => "qwen/qwen3.7-max",
        "choices" => [%{"delta" => %{"content" => "partial"}, "finish_reason" => "stop"}]
      }

      Bypass.expect_once(bypass, "POST", "/api/v1/chat/completions", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("text/event-stream")
        |> Plug.Conn.resp(200, "data: #{Jason.encode!(event)}\n\n")
      end)

      assert {:error, {:invalid_response, summary}} =
               OpenRouterProvider.stream_complete(
                 %{"messages" => [%{"role" => "user", "content" => "Hi"}]},
                 fn _delta -> :ok end
               )

      assert summary.reason == "stream_missing_done"
    end

    test "rejects malformed stream events instead of returning prior partial text" do
      bypass = Bypass.open()

      Application.put_env(:maraithon, Maraithon.Runtime,
        openrouter_api_key: "test_api_key",
        openrouter_model: "qwen/qwen3.7-max"
      )

      Application.put_env(:maraithon, :openrouter,
        base_url: "http://localhost:#{bypass.port}/api/v1/chat/completions"
      )

      valid = %{
        "choices" => [%{"delta" => %{"content" => "partial"}, "finish_reason" => nil}]
      }

      body =
        "data: #{Jason.encode!(valid)}\n\n" <>
          "data: {malformed-json}\n\n" <>
          "data: [DONE]\n\n"

      Bypass.expect_once(bypass, "POST", "/api/v1/chat/completions", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("text/event-stream")
        |> Plug.Conn.resp(200, body)
      end)

      assert {:error, {:invalid_response, summary}} =
               OpenRouterProvider.stream_complete(
                 %{"messages" => [%{"role" => "user", "content" => "Hi"}]},
                 fn _delta -> :ok end
               )

      assert summary.reason == "malformed_stream_event"
    end
  end
end
