defmodule Maraithon.Memory.Embedding do
  @moduledoc """
  Embedding source text and write helpers for `memory_items` (SPEC 07 R2).

  `Memory.Item.content`/`summary` are stored encrypted at rest
  (`Maraithon.Encrypted.Binary`); the Ecto custom type transparently decrypts
  them onto the struct when the row is loaded/returned through `Repo`, so
  `source_text/1` only ever sees plaintext as long as it is fed a `%Item{}`
  struct (never a raw SQL row). Vector storage itself reuses
  `Maraithon.LocalEmbeddings`, which writes/reads the (unencrypted)
  `embedding` column with raw SQL and no-ops when the column isn't present
  (e.g. pgvector not yet installed) — see
  `crm/person_embeddings.ex`/`local_embeddings.ex` for the same convention.
  """

  alias Maraithon.LocalEmbeddings
  alias Maraithon.Memory.Item

  require Logger

  @table "memory_items"

  @doc "Table name the embedding is written to."
  def table, do: @table

  @doc """
  Canonical embedding source text for a memory item: title, kind, tags,
  summary, and content. Compact but includes enough signal for semantic
  recall to distinguish similar memories.
  """
  def source_text(%Item{} = item) do
    [
      item.title,
      item.kind,
      item.summary,
      item.content,
      tags_text(item.tags)
    ]
    |> Enum.reject(&blank?/1)
    |> Enum.uniq()
    |> Enum.join("\n")
    |> String.trim()
  end

  def source_text(_other), do: ""

  @doc """
  Recompute and store the embedding for a memory item if the source text
  changed since the last refresh (or force: true). Returns whatever
  `LocalEmbeddings.refresh/4` returns.
  """
  def refresh(item, opts \\ [])

  def refresh(%Item{} = item, opts) do
    LocalEmbeddings.refresh(@table, item.id, source_text(item), opts)
  end

  def refresh(_other, _opts), do: {:error, :invalid_memory_item}

  @doc """
  Spawn a background refresh; the write path never blocks on it. Mirrors
  `Maraithon.Crm.PersonEmbeddings.refresh_async/2`.
  """
  def refresh_async(item, opts \\ [])

  def refresh_async(%Item{} = item, opts) do
    if async_enabled?() do
      Task.start(fn ->
        try do
          refresh(item, opts)
        rescue
          error ->
            Logger.warning("memory item embedding refresh crashed",
              memory_id: item.id,
              reason: Exception.message(error)
            )
        end
      end)
    end

    :ok
  end

  def refresh_async(_other, _opts), do: :ok

  defp async_enabled? do
    Application.get_env(:maraithon, __MODULE__, [])
    |> Keyword.get(:async_enabled, true)
  end

  defp tags_text(tags) when is_list(tags) and tags != [], do: Enum.join(tags, " ")
  defp tags_text(_tags), do: nil

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(_other), do: false
end
