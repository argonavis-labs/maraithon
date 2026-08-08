defmodule Maraithon.LogFormatterTest do
  use ExUnit.Case, async: true

  alias Maraithon.LogFormatter

  test "production logger passes metadata through the formatter allowlist" do
    formatter =
      "config/prod.exs"
      |> Config.Reader.read!(env: :prod)
      |> Keyword.fetch!(:logger)
      |> Keyword.fetch!(:default_formatter)

    assert Keyword.fetch!(formatter, :metadata) == :all
    assert Keyword.fetch!(formatter, :format) == {LogFormatter, :format}
    assert Keyword.fetch!(formatter, :utc_log)
  end

  describe "format/4" do
    test "formats log entry as JSON" do
      timestamp = {{2024, 1, 15}, {12, 30, 45, 123}}
      metadata = []

      result = LogFormatter.format(:info, "Test message", timestamp, metadata)

      json = result |> IO.iodata_to_binary() |> String.trim()
      decoded = Jason.decode!(json)

      assert decoded["severity"] == "INFO"
      assert decoded["message"] == "Test message"
      assert decoded["timestamp"] == "2024-01-15T12:30:45.123Z"
    end

    test "maps log levels to Cloud Logging severity" do
      timestamp = {{2024, 1, 15}, {12, 30, 45, 0}}

      assert get_severity(:debug, timestamp) == "DEBUG"
      assert get_severity(:info, timestamp) == "INFO"
      assert get_severity(:warn, timestamp) == "WARNING"
      assert get_severity(:warning, timestamp) == "WARNING"
      assert get_severity(:error, timestamp) == "ERROR"
    end

    test "includes allowlisted operational metadata fields" do
      timestamp = {{2024, 1, 15}, {12, 30, 45, 0}}

      metadata = [
        request_id: "req-123",
        agent_id: "agent-456",
        model: "qwen/qwen3.6-flash",
        detail_failure_count: 0,
        truncated: true,
        backfill_needed: true,
        sent: 0,
        held: 1,
        suppressed: 2,
        failed: 1,
        disabled: 3,
        user_count: 4,
        planned: 5,
        interrupt_now: 6,
        digest: 7,
        delivered: 8,
        expired: 9,
        user_id_hash: "abc123",
        failure_code: "api_500",
        failure_codes: %{"api_500" => 1},
        cost_usd: 0.123,
        reasoning_tokens: 321,
        response_status: 500,
        response_shape: "list",
        error_class: "server_error",
        choice_count: 1,
        prompt_kind: :delivery_plan,
        prompt_bytes: 12_345,
        prompt_byte_cap: 64_000,
        available_candidates: 25,
        included_candidates: 8,
        undeliverable: 2,
        arbitrary_payload: "not-for-console"
      ]

      result = LogFormatter.format(:info, "Test", timestamp, metadata)

      json = result |> IO.iodata_to_binary() |> String.trim()
      decoded = Jason.decode!(json)

      assert decoded["request_id"] == "req-123"
      assert decoded["agent_id"] == "agent-456"
      assert decoded["model"] == "qwen/qwen3.6-flash"
      assert decoded["detail_failure_count"] == 0
      assert decoded["truncated"] == true
      assert decoded["backfill_needed"] == true
      assert decoded["sent"] == 0
      assert decoded["held"] == 1
      assert decoded["suppressed"] == 2
      assert decoded["failed"] == 1
      assert decoded["disabled"] == 3
      assert decoded["user_count"] == 4
      assert decoded["planned"] == 5
      assert decoded["interrupt_now"] == 6
      assert decoded["digest"] == 7
      assert decoded["delivered"] == 8
      assert decoded["expired"] == 9
      assert decoded["user_id_hash"] == "abc123"
      assert decoded["failure_code"] == "api_500"
      assert decoded["failure_codes"] =~ "api_500"
      assert decoded["cost_usd"] == 0.123
      assert decoded["reasoning_tokens"] == 321
      assert decoded["response_status"] == 500
      assert decoded["response_shape"] == "list"
      assert decoded["error_class"] == "server_error"
      assert decoded["choice_count"] == 1
      assert decoded["prompt_kind"] == "delivery_plan"
      assert decoded["prompt_bytes"] == 12_345
      assert decoded["prompt_byte_cap"] == 64_000
      assert decoded["available_candidates"] == 25
      assert decoded["included_candidates"] == 8
      assert decoded["failed"] == 1
      assert decoded["undeliverable"] == 2
      refute Map.has_key?(decoded, "arbitrary_payload")
    end

    test "redacts credentials and normalizes structured metadata" do
      timestamp = {{2024, 1, 15}, {12, 30, 45, 0}}

      metadata = [
        reason:
          {:request_failed,
           %{
             "authorization" => "Bearer secret-token-value",
             "access_token" => "secret-access-token"
           }}
      ]

      result =
        LogFormatter.format(
          :warning,
          "request used Authorization: Bearer secret-token-value",
          timestamp,
          metadata
        )

      decoded = result |> IO.iodata_to_binary() |> String.trim() |> Jason.decode!()

      assert decoded["message"] == "request used Authorization: <redacted-auth>"
      assert decoded["reason"] == "request_failed"
      refute decoded["reason"] =~ "secret-token-value"
      refute decoded["reason"] =~ "secret-access-token"
    end

    test "derives module/function/line labels from Logger source metadata" do
      timestamp = {{2024, 1, 15}, {12, 30, 45, 0}}
      metadata = [mfa: {MyModule, :test, 2}, line: 42]

      result = LogFormatter.format(:info, "Test", timestamp, metadata)

      json = result |> IO.iodata_to_binary() |> String.trim()
      decoded = Jason.decode!(json)

      labels = decoded["logging.googleapis.com/labels"]
      assert labels["module"] == "Elixir.MyModule"
      assert labels["function"] == "test/2"
      assert labels["line"] == "42"
    end

    test "sanitizes invalid UTF-8 while preserving structured JSON" do
      timestamp = {{2024, 1, 15}, {12, 30, 45, 0}}
      result = LogFormatter.format(:warning, <<"invalid ", 255>>, timestamp, [])
      json = result |> IO.iodata_to_binary() |> String.trim()

      assert String.valid?(json)
      assert Jason.decode!(json)["message"] == "invalid �"
    end

    test "handles iodata messages" do
      timestamp = {{2024, 1, 15}, {12, 30, 45, 0}}

      result = LogFormatter.format(:info, ["Hello", " ", "World"], timestamp, [])

      json = result |> IO.iodata_to_binary() |> String.trim()
      decoded = Jason.decode!(json)

      assert decoded["message"] == "Hello World"
    end
  end

  defp get_severity(level, timestamp) do
    result = LogFormatter.format(level, "Test", timestamp, [])
    json = result |> IO.iodata_to_binary() |> String.trim()
    decoded = Jason.decode!(json)
    decoded["severity"]
  end
end
