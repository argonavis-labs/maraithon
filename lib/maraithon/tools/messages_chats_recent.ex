defmodule Maraithon.Tools.MessagesChatsRecent do
  @moduledoc """
  List the user's most recently active iMessage chats with the latest
  message in each and a 7-day message count. This is the "what threads
  should I look at" entry point for the assistant.

  Calls `Maraithon.LocalMessages.chats_recent/2`.
  """

  import Maraithon.Tools.ActionHelpers

  alias Maraithon.LocalMessages
  alias Maraithon.Tools.LocalMessagesHelpers

  @default_limit 12
  @max_limit 50

  def execute(args) when is_map(args) do
    with {:ok, user_id} <- required_string(args, "user_id") do
      limit = LocalMessagesHelpers.normalize_limit(args, @default_limit, @max_limit)

      chats = LocalMessages.chats_recent(user_id, limit: limit)

      {:ok,
       %{
         source: "local_messages",
         count: length(chats),
         chats: Enum.map(chats, &LocalMessagesHelpers.serialize_chat_summary/1)
       }}
    end
  end

  def execute(_args), do: {:error, "invalid_args"}
end
