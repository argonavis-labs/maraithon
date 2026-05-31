defmodule Maraithon.Tools.MessagesGet do
  @moduledoc """
  Fetch one mirrored iMessage using a `message_id` returned by message
  search or recent-message tools.

  Calls `Maraithon.LocalMessages.get_by_guid/2`.
  """

  import Maraithon.Tools.ActionHelpers

  alias Maraithon.LocalMessages
  alias Maraithon.Tools.LocalMessagesHelpers

  def execute(args) when is_map(args) do
    with {:ok, user_id} <- required_string(args, "user_id"),
         {:ok, message_id} <- required_string(args, "message_id") do
      case LocalMessages.get_by_guid(user_id, message_id) do
        nil ->
          {:error, "message_not_found"}

        message ->
          {:ok,
           %{
             source: "local_messages",
             message: LocalMessagesHelpers.serialize_full(message)
           }}
      end
    end
  end

  def execute(_args), do: {:error, "invalid_args"}
end
