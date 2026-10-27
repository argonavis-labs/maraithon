defmodule Maraithon.Tools.RemindersOpen do
  @moduledoc """
  List the user's open (incomplete) mirrored macOS Reminders, ordered
  by due date then priority.
  """

  import Maraithon.Tools.ActionHelpers

  alias Maraithon.LocalReminders
  alias Maraithon.Tools.LocalRemindersHelpers

  @default_limit 25
  @max_limit 100

  def execute(args) when is_map(args) do
    with {:ok, user_id} <- required_string(args, "user_id") do
      limit = LocalRemindersHelpers.normalize_limit(args, @default_limit, @max_limit)
      list_name = optional_string(args, "list_name")

      opts =
        []
        |> Keyword.put(:limit, limit)
        |> maybe_put(:list_name, list_name)

      reminders = LocalReminders.open_reminders(user_id, opts)

      {:ok,
       %{
         source: "local_reminders",
         count: length(reminders),
         list_name: list_name,
         reminders: Enum.map(reminders, &LocalRemindersHelpers.serialize_summary/1)
       }}
    end
  end

  def execute(_args), do: {:error, "invalid_args"}
end
