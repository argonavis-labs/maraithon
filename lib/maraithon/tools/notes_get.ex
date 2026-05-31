defmodule Maraithon.Tools.NotesGet do
  @moduledoc """
  Fetch one mirrored macOS Note using a `note_id` returned by note
  search or recent-note tools.

  TODO: depends on server schema agent. Calls
  `Maraithon.LocalNotes.get_by_guid/2`.
  """

  import Maraithon.Tools.ActionHelpers

  alias Maraithon.LocalNotes
  alias Maraithon.Tools.LocalNotesHelpers

  def execute(args) when is_map(args) do
    with {:ok, user_id} <- required_string(args, "user_id"),
         {:ok, note_id} <- required_string(args, "note_id") do
      case LocalNotes.get_by_guid(user_id, note_id) do
        nil ->
          {:error, "note_not_found"}

        note ->
          {:ok,
           %{
             source: "local_notes",
             note: LocalNotesHelpers.serialize_full(note)
           }}
      end
    end
  end

  def execute(_args), do: {:error, "invalid_args"}
end
