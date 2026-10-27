defmodule Maraithon.Tools.RemindersGet do
  @moduledoc """
  Fetch one mirrored macOS Reminder using a `reminder_id` returned by
  reminder search, due-soon, or open-reminder tools.
  """

  import Maraithon.Tools.ActionHelpers

  alias Maraithon.LocalReminders
  alias Maraithon.Tools.LocalRemindersHelpers

  def execute(args) when is_map(args) do
    with {:ok, user_id} <- required_string(args, "user_id"),
         {:ok, reminder_id} <- required_string(args, "reminder_id") do
      case LocalReminders.get_by_guid(user_id, reminder_id) do
        nil ->
          {:error, "reminder_not_found"}

        reminder ->
          {:ok,
           %{
             source: "local_reminders",
             reminder: LocalRemindersHelpers.serialize_full(reminder)
           }}
      end
    end
  end

  def execute(_args), do: {:error, "invalid_args"}
end
