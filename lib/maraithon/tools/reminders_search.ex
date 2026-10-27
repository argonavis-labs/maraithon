defmodule Maraithon.Tools.RemindersSearch do
  @moduledoc """
  Substring search across the user's mirrored macOS Reminders. Matches
  on `title`, `notes`, and `list_name` (all decrypted in memory).
  """

  import Maraithon.Tools.ActionHelpers

  alias Maraithon.LocalReminders
  alias Maraithon.Tools.LocalRemindersHelpers

  @default_limit 25
  @max_limit 100

  def execute(args) when is_map(args) do
    with {:ok, user_id} <- required_string(args, "user_id"),
         {:ok, query} <- required_string(args, "query") do
      limit = LocalRemindersHelpers.normalize_limit(args, @default_limit, @max_limit)
      list_name = optional_string(args, "list_name")

      opts =
        []
        |> Keyword.put(:limit, limit)
        |> maybe_put(:list_name, list_name)

      reminders = LocalReminders.search(user_id, query, opts)

      {:ok,
       %{
         source: "local_reminders",
         query: query,
         count: length(reminders),
         list_name: list_name,
         reminders: Enum.map(reminders, &LocalRemindersHelpers.serialize_summary/1)
       }}
    end
  end

  def execute(_args), do: {:error, "invalid_args"}
end
