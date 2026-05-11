defmodule Maraithon.Tools.FilesSearch do
  @moduledoc """
  Search the user's mirrored macOS files under `~/Documents`,
  `~/Desktop`, and `~/Downloads` by substring across filename, path,
  and extracted text content.

  Calls `Maraithon.LocalFiles.search/3`.
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
        LocalFiles.search(user_id, query,
          limit: limit,
          extension: extension,
          path_substring: path_substring
        )

      {:ok,
       %{
         source: "local_files",
         query: query,
         count: length(files),
         files: Enum.map(files, &LocalFilesHelpers.serialize_summary/1)
       }}
    end
  end

  def execute(_args), do: {:error, "invalid_args"}
end
