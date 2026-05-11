defmodule Maraithon.Tools.NotesSearch do
  @moduledoc """
  Search the user's mirrored macOS Notes for a substring in the title or
  snippet.

  TODO: depends on server schema agent. Calls `Maraithon.LocalNotes.search/3`
  to query the durable mirror populated by the companion device pipeline.
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

      notes = LocalNotes.search(user_id, query, opts)

      {:ok,
       %{
         source: "local_notes",
         query: query,
         count: length(notes),
         notes: Enum.map(notes, &LocalNotesHelpers.serialize_summary/1)
       }}
    end
  end

  def execute(_args), do: {:error, "invalid_args"}
end
