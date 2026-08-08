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
      assert decoded["timestamp"] == "2024-01-15T12:30:45.123"
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
      assert decoded["reason"] =~ "<redacted>"
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
