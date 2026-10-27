defmodule Maraithon.LogBufferTest do
  use ExUnit.Case, async: false

  require Logger

  setup do
    Maraithon.LogBuffer.clear()

    on_exit(fn ->
      Maraithon.LogBuffer.clear()
    end)

    :ok
  end

  test "captures recent logger entries with metadata" do
    Logger.warning("first buffer entry")
    Logger.error("second buffer entry", request_id: "req-123", agent_id: "agent-1")
    Logger.flush()
    _ = :sys.get_state(Maraithon.LogBuffer)

    [latest, older] = Maraithon.LogBuffer.recent(2)

    assert latest.level == :error
    assert latest.message =~ "second buffer entry"
    assert latest.metadata["request_id"] == "req-123"
    assert latest.metadata["agent_id"] == "agent-1"
    assert older.message =~ "first buffer entry"
  end

  test "logger-path metadata never retains opaque provider or prompt detail" do
    Logger.error("fixed failure",
      reason: "prompt-echo-secret",
      body: %{"message" => "provider-body-secret"},
      arbitrary_payload: "private-user-payload"
    )

    Logger.flush()
    _ = :sys.get_state(Maraithon.LogBuffer)
    [entry] = Maraithon.LogBuffer.recent(1)
    serialized = inspect(entry, printable_limit: :infinity)

    refute serialized =~ "prompt-echo-secret"
    refute serialized =~ "provider-body-secret"
    refute serialized =~ "private-user-payload"
    assert entry.metadata["reason"] == "redacted_detail"
    refute Map.has_key?(entry.metadata, "body")
    refute Map.has_key?(entry.metadata, "arbitrary_payload")
  end

  test "drops deep unknown metadata before recursive redaction" do
    deep = Enum.reduce(1..2_000, "private-leaf", fn index, acc -> %{index => acc} end)

    Logger.warning("bounded metadata probe",
      arbitrary_payload: deep,
      failure_code: "bounded_probe"
    )

    Logger.flush()
    _ = :sys.get_state(Maraithon.LogBuffer)
    [entry] = Maraithon.LogBuffer.recent(1)

    assert entry.metadata["failure_code"] == "bounded_probe"
    refute Map.has_key?(entry.metadata, "arbitrary_payload")
    refute inspect(entry, printable_limit: :infinity) =~ "private-leaf"
  end

  test "keeps only the configured maximum number of entries" do
    prefix = "log-buffer-trim-test"

    for index <- 1..520 do
      Maraithon.LogBuffer.record(%{level: :info, message: "#{prefix}-#{index}"})
    end

    _ = :sys.get_state(Maraithon.LogBuffer)

    recent = Maraithon.LogBuffer.recent(600)

    assert length(recent) == 500
    assert Enum.any?(recent, &(&1.message == "#{prefix}-520"))
    refute Enum.any?(recent, &(&1.message == "#{prefix}-1"))
  end

  test "normalizes direct-record timestamp, level, keys, and opaque metadata" do
    Maraithon.LogBuffer.record(%{
      timestamp: <<255>>,
      level: <<255>>,
      message: "ok",
      metadata: %{
        {:unsupported, "key"} => "private tuple value",
        "description" => "private user text",
        "user_id" => "person@example.com"
      }
    })

    _ = :sys.get_state(Maraithon.LogBuffer)
    [entry] = Maraithon.LogBuffer.recent(1)

    assert entry.level == :info
    assert {:ok, _timestamp, _offset} = DateTime.from_iso8601(entry.timestamp)
    refute Map.has_key?(entry.metadata, "unsupported")
    refute Map.has_key?(entry.metadata, "description")
    assert byte_size(entry.metadata["user_id"]) == 16
    refute inspect(entry) =~ "person@example.com"
    assert String.valid?(Jason.encode!(entry))
  end

  test "sanitizes invalid UTF-8 in direct records" do
    Maraithon.LogBuffer.record(%{level: :warning, message: <<"invalid ", 255>>})
    _ = :sys.get_state(Maraithon.LogBuffer)

    [entry] = Maraithon.LogBuffer.recent(1)
    assert entry.message == "invalid �"
    assert String.valid?(entry.message)
  end
end
