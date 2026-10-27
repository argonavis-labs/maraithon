defmodule Maraithon.Tools.VoiceMemosGet do
  @moduledoc """
  Fetch one mirrored macOS Voice Memo using a `memo_id` returned by
  Voice Memos search or recent-memo tools.

  TODO: depends on server schema agent. Calls
  `Maraithon.LocalVoiceMemos.get_by_guid/2`.
  """

  import Maraithon.Tools.ActionHelpers

  alias Maraithon.LocalVoiceMemos
  alias Maraithon.Tools.LocalVoiceMemosHelpers

  def execute(args) when is_map(args) do
    with {:ok, user_id} <- required_string(args, "user_id"),
         {:ok, memo_id} <- required_string(args, "memo_id") do
      case LocalVoiceMemos.get_by_guid(user_id, memo_id) do
        nil ->
          {:error, "voice_memo_not_found"}

        memo ->
          {:ok,
           %{
             source: "local_voice_memos",
             voice_memo: LocalVoiceMemosHelpers.serialize_full(memo)
           }}
      end
    end
  end

  def execute(_args), do: {:error, "invalid_args"}
end
