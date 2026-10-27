defmodule Maraithon.Tools.VoiceMemosSearch do
  @moduledoc """
  Search the user's mirrored macOS Voice Memos by title substring.

  TODO: depends on server schema agent. Calls
  `Maraithon.LocalVoiceMemos.search/3`.
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
      memos = LocalVoiceMemos.search(user_id, query, limit: limit)

      {:ok,
       %{
         source: "local_voice_memos",
         query: query,
         count: length(memos),
         voice_memos: Enum.map(memos, &LocalVoiceMemosHelpers.serialize_summary/1)
       }}
    end
  end

  def execute(_args), do: {:error, "invalid_args"}
end
