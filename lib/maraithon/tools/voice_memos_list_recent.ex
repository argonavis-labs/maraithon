defmodule Maraithon.Tools.VoiceMemosListRecent do
  @moduledoc """
  List the user's most recently created mirrored macOS Voice Memos.

  TODO: depends on server schema agent. Calls
  `Maraithon.LocalVoiceMemos.recent_for_user/2`.
  """

  import Maraithon.Tools.ActionHelpers

  alias Maraithon.LocalVoiceMemos
  alias Maraithon.Tools.LocalVoiceMemosHelpers

  @default_limit 20
  @max_limit 50

  def execute(args) when is_map(args) do
    with {:ok, user_id} <- required_string(args, "user_id") do
      limit = LocalVoiceMemosHelpers.normalize_limit(args, @default_limit, @max_limit)
      memos = LocalVoiceMemos.recent_for_user(user_id, limit: limit)

      {:ok,
       %{
         source: "local_voice_memos",
         count: length(memos),
         voice_memos: Enum.map(memos, &LocalVoiceMemosHelpers.serialize_summary/1)
       }}
    end
  end

  def execute(_args), do: {:error, "invalid_args"}
end
