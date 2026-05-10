defmodule Maraithon.LLM.JsonFieldStreamerTest do
  use ExUnit.Case, async: true

  alias Maraithon.LLM.JsonFieldStreamer

  defp drive(state, chunks) do
    Enum.reduce(chunks, {"", state}, fn chunk, {acc, st} ->
      {emit, next_state} = JsonFieldStreamer.feed(st, chunk)
      {acc <> emit, next_state}
    end)
  end

  test "extracts the full message when fed in one chunk" do
    json = ~s({"status":"final","assistant_message":"Hello there","summary":"x"})
    {emit, state} = JsonFieldStreamer.feed(JsonFieldStreamer.new(), json)
    assert emit == "Hello there"
    assert JsonFieldStreamer.done?(state)
  end

  test "extracts across many chunks split inside the marker" do
    json = ~s({"status":"final","assistant_message":"Hello there"})

    chunks =
      for <<c <- json>>, do: <<c>>

    {emit, state} = drive(JsonFieldStreamer.new(), chunks)
    assert emit == "Hello there"
    assert JsonFieldStreamer.done?(state)
  end

  test "decodes JSON string escapes" do
    json =
      ~s({"assistant_message":"line1\\nline2\\twith \\"quotes\\" and \\\\ slash"})

    {emit, _state} = JsonFieldStreamer.feed(JsonFieldStreamer.new(), json)
    assert emit == ~s(line1\nline2\twith "quotes" and \\ slash)
  end

  test "decodes \\uXXXX unicode escapes split across chunks" do
    chunks = [
      ~s({"assistant_message":"snowman \\u26),
      "03",
      ~s( done"})
    ]

    {emit, _state} = drive(JsonFieldStreamer.new(), chunks)
    assert emit == "snowman ☃ done"
  end

  test "ignores anything before the target field marker" do
    json =
      ~s({"status":"final","summary":"unrelated stuff with quotes \\"inside\\"","assistant_message":"yes"})

    {emit, _state} = JsonFieldStreamer.feed(JsonFieldStreamer.new(), json)
    assert emit == "yes"
  end

  test "extracts a different target field when configured" do
    json = ~s({"status":"final","summary":"hi"})
    {emit, _state} = JsonFieldStreamer.feed(JsonFieldStreamer.new("summary"), json)
    assert emit == "hi"
  end

  test "stops emitting after the closing quote" do
    json = ~s({"assistant_message":"abc","extra":"def"})
    {emit, state} = JsonFieldStreamer.feed(JsonFieldStreamer.new(), json)
    assert emit == "abc"
    assert JsonFieldStreamer.done?(state)
    {trail, _} = JsonFieldStreamer.feed(state, ~s(more bytes ignored))
    assert trail == ""
  end

  test "disable/1 makes the streamer ignore further input" do
    state = JsonFieldStreamer.disable(JsonFieldStreamer.new())
    {emit, _state} = JsonFieldStreamer.feed(state, ~s({"assistant_message":"x"}))
    assert emit == ""
  end

  test "handles split inside an escape sequence" do
    chunks = [~s({"assistant_message":"a\\), ~s(nb)]
    {emit, _state} = drive(JsonFieldStreamer.new(), chunks)
    assert emit == "a\nb"
  end
end
