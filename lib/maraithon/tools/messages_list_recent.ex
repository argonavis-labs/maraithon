defmodule Maraithon.Tools.MessagesListRecent do
  @moduledoc """
  List the user's most recent mirrored iMessages, newest first. Optionally
  restrict to one chat by `chat_key`.

  Calls `Maraithon.LocalMessages.recent_for_user/2`.
  """

  import Maraithon.Tools.ActionHelpers

  alias Maraithon.LocalMessages
  alias Maraithon.Tools.LocalMessagesHelpers

  @default_limit 20
  @max_limit 100

  def execute(args) when is_map(args) do
    with {:ok, user_id} <- required_string(args, "user_id") do
      limit = LocalMessagesHelpers.normalize_limit(args, @default_limit, @max_limit)
      chat_key = optional_string(args, "chat_key")

      opts =
        []
        |> Keyword.put(:limit, limit)
        |> maybe_put(:chat_key, chat_key)

      messages = LocalMessages.recent_for_user(user_id, opts)

      {:ok,
       %{
         source: "local_messages",
         count: length(messages),
         chat_key: chat_key,
         messages: Enum.map(messages, &LocalMessagesHelpers.serialize_summary(&1, user_id))
       }}
    end
  end

  def execute(_args), do: {:error, "invalid_args"}
end
