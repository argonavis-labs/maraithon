defmodule Maraithon.TextSanitize do
  @moduledoc """
  Drops invalid UTF-8 bytes from companion-source text fields before they
  hit Postgres `text` columns. The companion app's local decoders
  (`AttributedBodyDecoder` for iMessage, Notes' binary protobuf reader,
  Voice Memos transcript fallback) occasionally leak stray bytes that
  weren't valid UTF-8 — when the columns were `bytea` (Cloak-encrypted)
  Postgres accepted them blindly, but plaintext `text` columns enforce
  UTF-8 and reject the entire batch with `22021`
  (character_not_in_repertoire) if any row carries a bad byte.

  `scrub/1` walks the binary, keeps every valid codepoint, and silently
  drops invalid bytes. Lossy on bad inputs but cheap and safe — and the
  scrubbed text is exactly what `String.valid?/1` expects everywhere
  else in the system.
  """

  @doc """
  Returns the value unchanged unless it's a binary that contains invalid
  UTF-8 bytes. For invalid binaries returns the same binary with each
  invalid byte removed. Non-binary values pass through unchanged so this
  is safe to apply unconditionally in `prepare_row` maps.
  """
  def scrub(nil), do: nil

  def scrub(value) when is_binary(value) do
    if String.valid?(value), do: value, else: strip_invalid_utf8(value)
  end

  def scrub(other), do: other

  defp strip_invalid_utf8(<<>>), do: <<>>

  defp strip_invalid_utf8(<<ch::utf8, rest::binary>>),
    do: <<ch::utf8>> <> strip_invalid_utf8(rest)

  defp strip_invalid_utf8(<<_::8, rest::binary>>), do: strip_invalid_utf8(rest)
end
