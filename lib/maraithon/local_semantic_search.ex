defmodule Maraithon.LocalSemanticSearch do
  @moduledoc """
  Shared semantic-search engine for the `Maraithon.Local*` contexts.

  This module is the per-source pgvector landing pad introduced in v5. It
  exposes `rank_by_similarity/4`, which takes a candidate row stream and a
  text-extractor function, embeds the query, embeds each candidate, and
  returns the rows ordered by cosine similarity to the query above a
  configurable threshold.

  ## Why in-memory cosine?

  Local mirror rows (`local_notes`, `local_voice_memos`, `local_messages`,
  `local_reminders`, `local_calendar_events`, `local_files`) store their
  text fields with Cloak ciphertext at rest, so we cannot push the
  similarity calculation down to pgvector without first materializing
  rows in memory and decrypting them. The volume per device is small
  enough (a few hundred candidates after an overfetch ceiling) that an
  in-memory rank is well under the recall-anywhere 3s per-source budget.

  Each Local* context's `semantic_search/3` overfetches a recency window
  of rows, hands them here with a text extractor, and gets back a list
  ranked by semantic relevance — preserving the same return shape as
  the substring `search/3` so callers can A/B them transparently.
  """

  alias Maraithon.LLM.Embeddings

  @default_limit 12
  @default_threshold 0.15
  @default_dim 1536

  @doc """
  Rank `rows` by cosine similarity of `extractor.(row)` against `query`.

  Returns the top `limit` rows above the similarity `threshold`, ordered
  by descending similarity. Rows whose extracted text is empty are
  dropped.

  Options:
    * `:limit` — max rows to return (default #{@default_limit})
    * `:threshold` — minimum cosine similarity in `[0, 1]` (default 0.15)
    * `:embedder` — `({:ok, [float]} | {:error, term})` 1-arity fn used
      for text → vector (test seam; defaults to a deterministic mock so
      no network is required for ranking)

  Returns `[]` when `query` is empty or every candidate fails to embed.
  """
  def rank_by_similarity(rows, query, extractor, opts \\ [])

  def rank_by_similarity(rows, query, extractor, opts)
      when is_list(rows) and is_binary(query) and is_function(extractor, 1) do
    limit = Keyword.get(opts, :limit, @default_limit)
    threshold = Keyword.get(opts, :threshold, @default_threshold)
    embedder = Keyword.get(opts, :embedder, &default_embedder/1)

    trimmed = String.trim(query)

    cond do
      trimmed == "" ->
        []

      rows == [] ->
        []

      true ->
        case embedder.(trimmed) do
          {:ok, query_vec} when is_list(query_vec) ->
            rows
            |> Enum.map(fn row ->
              text = extractor.(row) |> normalize_text()

              if text == "" do
                nil
              else
                case embedder.(text) do
                  {:ok, row_vec} when is_list(row_vec) ->
                    {row, cosine_similarity(query_vec, row_vec)}

                  _ ->
                    nil
                end
              end
            end)
            |> Enum.reject(&is_nil/1)
            |> Enum.filter(fn {_row, score} -> score >= threshold end)
            |> Enum.sort_by(fn {_row, score} -> -score end)
            |> Enum.take(limit)
            |> Enum.map(fn {row, _score} -> row end)

          _ ->
            []
        end
    end
  end

  def rank_by_similarity(_rows, _query, _extractor, _opts), do: []

  @doc """
  Cosine similarity in `[0, 1]` for two equal-length numeric lists.
  Returns 0.0 when either vector is zero or shapes mismatch.
  """
  def cosine_similarity(a, b) when is_list(a) and is_list(b) and length(a) == length(b) do
    {dot, na, nb} =
      Enum.zip(a, b)
      |> Enum.reduce({0.0, 0.0, 0.0}, fn {x, y}, {dot, na, nb} ->
        {dot + x * y, na + x * x, nb + y * y}
      end)

    cond do
      na == 0.0 -> 0.0
      nb == 0.0 -> 0.0
      true -> max(0.0, dot / (:math.sqrt(na) * :math.sqrt(nb)))
    end
  end

  def cosine_similarity(_a, _b), do: 0.0

  defp default_embedder(text) when is_binary(text) do
    {:ok, Embeddings.deterministic_mock(text, @default_dim)}
  end

  defp normalize_text(nil), do: ""

  defp normalize_text(value) when is_binary(value), do: String.trim(value)

  defp normalize_text(_value), do: ""
end
