defmodule Maraithon.TelegramChunking do
  @moduledoc """
  Shared paragraph-aware chunking for long Telegram messages.

  Extracted (SPEC 09 R16) from the `MorningBriefing` smoke-brief delivery
  path so scheduled brief delivery via `PushBroker.send_candidate/1` can send
  multiple ordered messages instead of truncating. Same algorithm as the
  original private helpers: split on paragraph (`\\n\\n`) boundaries first,
  fall back to single-newline splits for oversized blocks, hard-split only
  when a single line still exceeds the limit, then greedily pack units back
  into chunks up to the limit.
  """

  @doc """
  Splits `text` into an ordered list of chunks of at most `limit` characters,
  preferring paragraph boundaries. Never splits inside a paragraph unless a
  single paragraph exceeds the limit on its own.
  """
  def chunks(text, limit) when is_binary(text) and is_integer(limit) and limit > 0 do
    text
    |> chunk_units(limit)
    |> Enum.reduce([], fn unit, chunks ->
      append_chunk(chunks, unit, limit)
    end)
    |> Enum.reverse()
  end

  @doc """
  Prefixes multi-chunk output with a user-visible `"Part N/M"` label.
  A single chunk is returned unchanged. Ordering must still be guaranteed by
  sequentially awaiting each send — the label is a user-visible backstop only.
  """
  def label_parts([_single] = chunks), do: chunks

  def label_parts(chunks) when is_list(chunks) do
    total = length(chunks)

    chunks
    |> Enum.with_index(1)
    |> Enum.map(fn {chunk, index} -> "Part #{index}/#{total}\n\n#{chunk}" end)
  end

  defp chunk_units(text, limit) do
    text
    |> String.split(~r/\n{2,}/, trim: true)
    |> Enum.flat_map(fn block ->
      cond do
        String.length(block) <= limit ->
          [block]

        String.contains?(block, "\n") ->
          block
          |> String.split("\n", trim: true)
          |> Enum.flat_map(&hard_split_unit(&1, limit))

        true ->
          hard_split_unit(block, limit)
      end
    end)
  end

  defp hard_split_unit(text, limit) do
    if String.length(text) <= limit do
      [text]
    else
      {chunk, rest} = String.split_at(text, limit)
      [chunk | hard_split_unit(rest, limit)]
    end
  end

  defp append_chunk([], unit, _limit), do: [unit]

  defp append_chunk([current | rest], unit, limit) do
    candidate = current <> "\n\n" <> unit

    if String.length(candidate) <= limit do
      [candidate | rest]
    else
      [unit, current | rest]
    end
  end
end
