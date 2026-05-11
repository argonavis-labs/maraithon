defmodule Maraithon.Tools.RemindersDueSoon do
  @moduledoc """
  List the user's open mirrored macOS Reminders that are due within
  the next N days. Includes overdue items so the assistant can
  surface "needs attention now" correctly.
  """

  import Maraithon.Tools.ActionHelpers

  alias Maraithon.LocalReminders
  alias Maraithon.Tools.LocalRemindersHelpers

  @default_limit 25
  @max_limit 100
  @default_days_ahead 7
  @max_days_ahead 365

  def execute(args) when is_map(args) do
    with {:ok, user_id} <- required_string(args, "user_id") do
      limit = LocalRemindersHelpers.normalize_limit(args, @default_limit, @max_limit)

      days_ahead =
        LocalRemindersHelpers.normalize_days_ahead(args, @default_days_ahead, @max_days_ahead)

      list_name = optional_string(args, "list_name")

      opts =
        []
        |> Keyword.put(:limit, limit)
        |> Keyword.put(:days_ahead, days_ahead)
        |> maybe_put(:list_name, list_name)

      reminders = LocalReminders.due_soon(user_id, opts)

      {:ok,
       %{
         source: "local_reminders",
         count: length(reminders),
         days_ahead: days_ahead,
         list_name: list_name,
         reminders: Enum.map(reminders, &LocalRemindersHelpers.serialize_summary/1)
       }}
    end
  end

  def execute(_args), do: {:error, "invalid_args"}
end
