defmodule Maraithon.LLM.JsonFieldStreamer do
  @moduledoc """
  Incremental extractor for a single string field's value out of a streaming
  JSON response. Built for the assistant harness contract where the model
  returns `{"status":"...","assistant_message":"...",...}` and the user-visible
  text lives inside the `assistant_message` field.

  Feed raw output_text deltas in via `feed/2`. Decoded characters of the
  target field are returned. Once the field's closing quote is reached the
  streamer enters `:done` and ignores further input.

  A streamer can also abort early (e.g. the runtime detected a tool-call
  response) by calling `disable/1`.
  """

  @type phase :: :scanning | :inside_value | :done | :disabled

  @type t :: %__MODULE__{
          field: String.t(),
          phase: phase(),
          buffer: String.t(),
          marker: String.t(),
          escape: boolean(),
          unicode: nil | {pos_integer(), iodata()}
        }

  defstruct field: "assistant_message",
            phase: :scanning,
            buffer: "",
            marker: ~s("assistant_message":"),
            escape: false,
            unicode: nil

  @spec new(String.t()) :: t()
  def new(field \\ "assistant_message") when is_binary(field) do
    %__MODULE__{field: field, marker: ~s("#{field}":")}
  end

  @spec done?(t()) :: boolean()
  def done?(%__MODULE__{phase: phase}), do: phase in [:done, :disabled]

  @spec disable(t()) :: t()
  def disable(%__MODULE__{} = state), do: %{state | phase: :disabled, buffer: ""}

  @doc """
  Feed a chunk of raw JSON bytes. Returns `{decoded_emit, next_state}`.
  `decoded_emit` is the user-facing text that should be appended to the
  visible buffer (already JSON-unescaped). May be `""` if no progress was
  made or the streamer is disabled/done.
  """
  @spec feed(t(), String.t()) :: {String.t(), t()}
  def feed(%__MODULE__{phase: :done} = state, _chunk), do: {"", state}
  def feed(%__MODULE__{phase: :disabled} = state, _chunk), do: {"", state}

  def feed(%__MODULE__{phase: :scanning} = state, chunk) when is_binary(chunk) do
    combined = state.buffer <> chunk

    case :binary.match(combined, state.marker) do
      :nomatch ->
        {"", %{state | buffer: keep_tail(combined, byte_size(state.marker))}}

      {start, len} ->
        rest = binary_part(combined, start + len, byte_size(combined) - start - len)
        consume_value(%{state | phase: :inside_value, buffer: ""}, rest)
    end
  end

  def feed(%__MODULE__{phase: :inside_value} = state, chunk) when is_binary(chunk) do
    consume_value(state, chunk)
  end

  defp consume_value(state, chunk) do
    {reversed_emit, next_state} = do_consume_value(state, chunk, [])
    {reversed_emit |> Enum.reverse() |> IO.iodata_to_binary(), next_state}
  end

  defp do_consume_value(state, "", emitted), do: {emitted, state}

  defp do_consume_value(
         %__MODULE__{unicode: {needed, acc}} = state,
         <<char::utf8, rest::binary>>,
         emitted
       )
       when needed > 0 do
    next_acc = [acc, <<char::utf8>>]

    if needed == 1 do
      decoded =
        next_acc
        |> IO.iodata_to_binary()
        |> decode_unicode_escape()

      do_consume_value(
        %{state | unicode: nil, escape: false},
        rest,
        [decoded | emitted]
      )
    else
      do_consume_value(%{state | unicode: {needed - 1, next_acc}}, rest, emitted)
    end
  end

  defp do_consume_value(
         %__MODULE__{escape: true} = state,
         <<char::utf8, rest::binary>>,
         emitted
       ) do
    case char do
      ?u ->
        do_consume_value(%{state | escape: false, unicode: {4, []}}, rest, emitted)

      _other ->
        decoded =
          case char do
            ?\\ -> "\\"
            ?" -> "\""
            ?/ -> "/"
            ?n -> "\n"
            ?t -> "\t"
            ?r -> "\r"
            ?b -> "\b"
            ?f -> "\f"
            _unknown -> <<char::utf8>>
          end

        do_consume_value(
          %{state | escape: false, unicode: nil},
          rest,
          [decoded | emitted]
        )
    end
  end

  defp do_consume_value(state, <<?\\, rest::binary>>, emitted) do
    do_consume_value(%{state | escape: true}, rest, emitted)
  end

  defp do_consume_value(state, <<?", rest::binary>>, emitted) do
    {emitted, %{state | phase: :done, buffer: rest}}
  end

  defp do_consume_value(state, <<char::utf8, rest::binary>>, emitted) do
    do_consume_value(state, rest, [<<char::utf8>> | emitted])
  end

  defp decode_unicode_escape(hex) do
    case Integer.parse(hex, 16) do
      {codepoint, ""} when codepoint < 0xD800 or codepoint > 0xDFFF -> <<codepoint::utf8>>
      _invalid -> "?"
    end
  end

  defp keep_tail(buffer, tail_size) when byte_size(buffer) <= tail_size, do: buffer

  defp keep_tail(buffer, tail_size) do
    binary_part(buffer, byte_size(buffer) - tail_size, tail_size)
  end
end
