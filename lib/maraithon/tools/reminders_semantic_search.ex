defmodule Maraithon.Tools.RemindersSemanticSearch do
  @moduledoc """
  Semantic search of the user's mirrored macOS Reminders by meaning,
  not exact substring. Pairs with `reminders_search` — use this tool
  when the user asks "do I have a reminder about something similar"
  and won't recall exact wording. Stick to `reminders_search` when
  the user gives an exact phrase or title.
  """

  import Maraithon.Tools.ActionHelpers

  alias Maraithon.LocalReminders
  alias Maraithon.Tools.LocalRemindersHelpers

  @default_limit 12
  @max_limit 50

  def execute(args) when is_map(args) do
    with {:ok, user_id} <- required_string(args, "user_id"),
         {:ok, query} <- required_string(args, "query") do
      limit = LocalRemindersHelpers.normalize_limit(args, @default_limit, @max_limit)
      list_name = optional_string(args, "list_name")

      opts =
        []
        |> Keyword.put(:limit, limit)
        |> maybe_put(:list_name, list_name)

      reminders = LocalReminders.semantic_search(user_id, query, opts)

      {:ok,
       %{
         source: "local_reminders",
         query: query,
         search_mode: "semantic",
         count: length(reminders),
         list_name: list_name,
         reminders: Enum.map(reminders, &LocalRemindersHelpers.serialize_summary/1)
       }}
    end
  end

  def execute(_args), do: {:error, "invalid_args"}
end
