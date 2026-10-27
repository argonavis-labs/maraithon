defmodule Maraithon.Tools.NotesListRecent do
  @moduledoc """
  List the user's most recently modified mirrored macOS Notes.

  TODO: depends on server schema agent. Calls
  `Maraithon.LocalNotes.recent_for_user/2`.
  """

  import Maraithon.Tools.ActionHelpers

  alias Maraithon.LocalNotes
  alias Maraithon.Tools.LocalNotesHelpers

  @default_limit 20
  @max_limit 50

  def execute(args) when is_map(args) do
    with {:ok, user_id} <- required_string(args, "user_id") do
      limit = LocalNotesHelpers.normalize_limit(args, @default_limit, @max_limit)
      folder = optional_string(args, "folder")

      notes =
        user_id
        |> LocalNotes.recent_for_user(limit: limit * folder_overfetch_multiplier(folder))
        |> filter_by_folder(folder)
        |> Enum.take(limit)

      {:ok,
       %{
         source: "local_notes",
         count: length(notes),
         folder: folder,
         notes: Enum.map(notes, &LocalNotesHelpers.serialize_summary/1)
       }}
    end
  end

  def execute(_args), do: {:error, "invalid_args"}

  defp folder_overfetch_multiplier(nil), do: 1
  defp folder_overfetch_multiplier(_folder), do: 5

  defp filter_by_folder(notes, nil), do: notes

  defp filter_by_folder(notes, folder) when is_binary(folder) do
    needle = String.downcase(folder)
    Enum.filter(notes, &folder_matches?(&1, needle))
  end

  defp folder_matches?(%{folder: nil}, _needle), do: false

  defp folder_matches?(%{folder: value}, needle) when is_binary(value) do
    String.downcase(value) == needle
  end

  defp folder_matches?(_note, _needle), do: false
end
