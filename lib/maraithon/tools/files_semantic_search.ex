defmodule Maraithon.Tools.FilesSemanticSearch do
  @moduledoc """
  Semantic search of the user's mirrored macOS files (Documents,
  Desktop, Downloads) by meaning across filename, path, and extracted
  text content. Pairs with `files_search` — use this tool when the
  user asks "find the doc where I wrote about something similar" and
  won't recall exact filename or words. Stick to `files_search` when
  the user gives an exact phrase or filename.
  """

  import Maraithon.Tools.ActionHelpers

  alias Maraithon.LocalFiles
  alias Maraithon.Tools.LocalFilesHelpers

  @default_limit 12
  @max_limit 50

  def execute(args) when is_map(args) do
    with {:ok, user_id} <- required_string(args, "user_id"),
         {:ok, query} <- required_string(args, "query") do
      limit = LocalFilesHelpers.normalize_limit(args, @default_limit, @max_limit)
      extension = LocalFilesHelpers.optional_string(args, "extension")
      path_substring = LocalFilesHelpers.optional_string(args, "path_substring")

      files =
        LocalFiles.semantic_search(user_id, query,
          limit: limit,
          extension: extension,
          path_substring: path_substring
        )

      {:ok,
       %{
         source: "local_files",
         query: query,
         search_mode: "semantic",
         count: length(files),
         files: Enum.map(files, &LocalFilesHelpers.serialize_summary/1)
       }}
    end
  end

  def execute(_args), do: {:error, "invalid_args"}
end
