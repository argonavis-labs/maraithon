defmodule Maraithon.Tools.MessagesSemanticSearch do
  @moduledoc """
  Semantic search of the user's mirrored iMessage history by meaning,
  not exact substring. Pairs with `messages_search` — use this tool
  when the user asks "find the text where we talked about something
  similar" and won't recall exact wording. Stick to `messages_search`
  when the user gives an exact phrase or sender handle.
  """

  import Maraithon.Tools.ActionHelpers

  alias Maraithon.LocalMessages
  alias Maraithon.Tools.LocalMessagesHelpers

  @default_limit 12
  @max_limit 50

  def execute(args) when is_map(args) do
    with {:ok, user_id} <- required_string(args, "user_id"),
         {:ok, query} <- required_string(args, "query") do
      limit = LocalMessagesHelpers.normalize_limit(args, @default_limit, @max_limit)

      opts =
        []
        |> Keyword.put(:limit, limit)
        |> maybe_put(:from_handle, optional_string(args, "from_handle"))

      messages = LocalMessages.semantic_search(user_id, query, opts)

      {:ok,
       %{
         source: "local_messages",
         query: query,
         search_mode: "semantic",
         count: length(messages),
         messages: Enum.map(messages, &LocalMessagesHelpers.serialize_summary/1)
       }}
    end
  end

  def execute(_args), do: {:error, "invalid_args"}
end
