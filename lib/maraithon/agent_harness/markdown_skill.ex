defmodule Maraithon.AgentHarness.MarkdownSkill do
  @moduledoc """
  Loads file-backed agent skills from markdown.
  """

  @enforce_keys [:id, :name, :instructions, :path]
  defstruct [
    :id,
    :name,
    :description,
    :instructions,
    :path,
    connectors: [],
    tools: [],
    metadata: %{}
  ]

  def load_many(paths) when is_list(paths) do
    paths
    |> Enum.reduce_while({:ok, []}, fn path, {:ok, skills} ->
      case load_file(path) do
        {:ok, skill} -> {:cont, {:ok, [skill | skills]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, skills} -> {:ok, Enum.reverse(skills)}
      error -> error
    end
  end

  def load_file(path) when is_binary(path) do
    full_path = Path.expand(path)

    with true <- File.exists?(full_path) || {:error, {:skill_not_found, path}},
         {:ok, content} <- File.read(full_path),
         {:ok, metadata, instructions} <- split_frontmatter(content, path),
         {:ok, id} <- required_metadata(metadata, "id", path),
         {:ok, name} <- required_metadata(metadata, "name", path) do
      {:ok,
       %__MODULE__{
         id: id,
         name: name,
         description: metadata["description"],
         connectors: List.wrap(metadata["connectors"]),
         tools: List.wrap(metadata["tools"]),
         instructions: String.trim(instructions),
         path: path,
         metadata: metadata
       }}
    end
  end

  def load_file(path), do: {:error, {:invalid_skill_path, path}}

  defp split_frontmatter("---\n" <> rest, path) do
    case String.split(rest, "\n---\n", parts: 2) do
      [raw_metadata, instructions] ->
        with {:ok, metadata} <- parse_metadata(raw_metadata, path) do
          {:ok, metadata, instructions}
        end

      _ ->
        {:error, {:invalid_skill_frontmatter, path}}
    end
  end

  defp split_frontmatter(_content, path), do: {:error, {:missing_skill_frontmatter, path}}

  defp parse_metadata(raw_metadata, path) do
    raw_metadata
    |> String.trim()
    |> Jason.decode()
    |> case do
      {:ok, metadata} when is_map(metadata) -> {:ok, metadata}
      {:ok, _} -> {:error, {:invalid_skill_metadata, path}}
      {:error, _reason} -> {:error, {:invalid_skill_metadata, path}}
    end
  end

  defp required_metadata(metadata, key, path) do
    case Map.get(metadata, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, {:missing_skill_metadata, path, key}}
    end
  end
end
