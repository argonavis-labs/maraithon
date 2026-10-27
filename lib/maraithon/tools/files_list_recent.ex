defmodule Maraithon.Tools.FilesListRecent do
  @moduledoc """
  List the user's most recently modified mirrored macOS files under
  `~/Documents`, `~/Desktop`, and `~/Downloads`, newest modified first.

  Calls `Maraithon.LocalFiles.recent_for_user/2`.
  """

  import Maraithon.Tools.ActionHelpers

  alias Maraithon.LocalFiles
  alias Maraithon.Tools.LocalFilesHelpers

  @default_limit 20
  @max_limit 50

  def execute(args) when is_map(args) do
    with {:ok, user_id} <- required_string(args, "user_id") do
      limit = LocalFilesHelpers.normalize_limit(args, @default_limit, @max_limit)
      extension = LocalFilesHelpers.optional_string(args, "extension")

      files = LocalFiles.recent_for_user(user_id, limit: limit, extension: extension)

      {:ok,
       %{
         source: "local_files",
         count: length(files),
         files: Enum.map(files, &LocalFilesHelpers.serialize_summary/1)
       }}
    end
  end

  def execute(_args), do: {:error, "invalid_args"}
end
