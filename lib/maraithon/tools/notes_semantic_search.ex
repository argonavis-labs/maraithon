defmodule Maraithon.Tools.NotesSemanticSearch do
  @moduledoc """
  Semantic search of the user's mirrored macOS Notes by meaning, not
  exact substring. Pairs with `notes_search` — use this tool when the
  user asks "find the note about something similar to X" or "what was
  that idea I jotted down about ..." and won't recall the exact words.
  Stick to `notes_search` when the user gives an exact phrase or
  title.
  """

  import Maraithon.Tools.ActionHelpers

  alias Maraithon.LocalNotes
  alias Maraithon.Tools.LocalNotesHelpers

  @default_limit 12
  @max_limit 50

  def execute(args) when is_map(args) do
    with {:ok, user_id} <- required_string(args, "user_id"),
         {:ok, query} <- required_string(args, "query") do
      limit = LocalNotesHelpers.normalize_limit(args, @default_limit, @max_limit)

      opts =
        []
        |> Keyword.put(:limit, limit)
        |> maybe_put(:folder, optional_string(args, "folder"))

      notes = LocalNotes.semantic_search(user_id, query, opts)

      {:ok,
       %{
         source: "local_notes",
         query: query,
         search_mode: "semantic",
         count: length(notes),
         notes: Enum.map(notes, &LocalNotesHelpers.serialize_summary/1)
       }}
    end
  end

  def execute(_args), do: {:error, "invalid_args"}
end
