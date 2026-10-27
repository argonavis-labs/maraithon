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
    with {:ok, full_path} <- resolve_path(path),
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

  defp resolve_path(path) do
    path
    |> candidate_paths()
    |> Enum.find(&File.exists?/1)
    |> case do
      nil -> {:error, {:skill_not_found, path}}
      full_path -> {:ok, full_path}
    end
  end

  defp candidate_paths("priv/" <> relative_path = path) do
    [
      priv_path(configured_priv_dir(), relative_path),
      Path.expand(path),
      priv_path(app_priv_dir(), relative_path),
      priv_path(source_priv_dir(), relative_path)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp candidate_paths(path), do: [Path.expand(path)]

  defp priv_path(nil, _relative_path), do: nil
  defp priv_path(priv_dir, relative_path), do: Path.join(priv_dir, relative_path)

  defp configured_priv_dir do
    case System.get_env("MARAITHON_PRIV_DIR") do
      value when is_binary(value) and value != "" -> value
      _ -> nil
    end
  end

  defp app_priv_dir do
    case :code.priv_dir(:maraithon) do
      path when is_list(path) -> List.to_string(path)
      {:error, _reason} -> nil
    end
  end

  defp source_priv_dir, do: Path.expand("../../../priv", __DIR__)

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
