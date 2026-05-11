defmodule Maraithon.Tools.FilesGet do
  @moduledoc """
  Fetch one mirrored macOS file by its source GUID. Returns the full
  record including extracted text content, capped server-side at
  30 KB to protect the assistant's context window.

  Calls `Maraithon.LocalFiles.get_by_guid/2`.
  """

  import Maraithon.Tools.ActionHelpers

  alias Maraithon.LocalFiles
  alias Maraithon.Tools.LocalFilesHelpers

  def execute(args) when is_map(args) do
    with {:ok, user_id} <- required_string(args, "user_id"),
         {:ok, file_id} <- required_string(args, "file_id") do
      case LocalFiles.get_by_guid(user_id, file_id) do
        nil ->
          {:error, "file_not_found"}

        file ->
          {:ok,
           %{
             source: "local_files",
             file: LocalFilesHelpers.serialize_full(file)
           }}
      end
    end
  end

  def execute(_args), do: {:error, "invalid_args"}
end
