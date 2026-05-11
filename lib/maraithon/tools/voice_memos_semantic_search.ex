defmodule Maraithon.Tools.VoiceMemosSemanticSearch do
  @moduledoc """
  Semantic search of the user's mirrored macOS Voice Memos by
  meaning, not exact substring. Pairs with `voice_memos_search` — use
  this tool when the user asks "find the memo where I talked about
  something similar" and won't recall the exact words. Stick to
  `voice_memos_search` when the user gives an exact phrase or title.
  """

  import Maraithon.Tools.ActionHelpers

  alias Maraithon.LocalVoiceMemos
  alias Maraithon.Tools.LocalVoiceMemosHelpers

  @default_limit 12
  @max_limit 50

  def execute(args) when is_map(args) do
    with {:ok, user_id} <- required_string(args, "user_id"),
         {:ok, query} <- required_string(args, "query") do
      limit = LocalVoiceMemosHelpers.normalize_limit(args, @default_limit, @max_limit)
      memos = LocalVoiceMemos.semantic_search(user_id, query, limit: limit)

      {:ok,
       %{
         source: "local_voice_memos",
         query: query,
         search_mode: "semantic",
         count: length(memos),
         voice_memos: Enum.map(memos, &LocalVoiceMemosHelpers.serialize_summary/1)
       }}
    end
  end

  def execute(_args), do: {:error, "invalid_args"}
end
