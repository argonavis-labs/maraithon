defmodule Maraithon.Tools.MessagesSearch do
  @moduledoc """
  Search the user's mirrored iMessage history for a substring in the
  message text. Optionally narrow by sender handle (phone/email) and by
  date range.

  Calls `Maraithon.LocalMessages.search/3` to query the durable mirror
  populated by the companion device pipeline.
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
        |> maybe_put(:since, optional_string(args, "since"))
        |> maybe_put(:before, optional_string(args, "before"))

      messages = LocalMessages.search(user_id, query, opts)

      {:ok,
       %{
         source: "local_messages",
         query: query,
         count: length(messages),
         messages: Enum.map(messages, &LocalMessagesHelpers.serialize_summary/1)
       }}
    end
  end

  def execute(_args), do: {:error, "invalid_args"}
end
