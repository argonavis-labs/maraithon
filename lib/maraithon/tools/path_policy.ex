defmodule Maraithon.Tools.PathPolicy do
  @moduledoc """
  Shared path sandbox policy for filesystem tools.
  """

  alias Maraithon.Runtime.Config, as: RuntimeConfig

  @unavailable_path_error "path is not available to the assistant"
  @restricted_exact_names MapSet.new(~w(
    api_key
    apikey
    credential
    credentials
    id_dsa
    id_ecdsa
    id_ed25519
    id_rsa
    private-key
    private_key
    secret
    secrets
    token
    tokens
  ))
  @restricted_extensions MapSet.new(~w(
    .jks
    .key
    .keystore
    .p12
    .p8
    .pem
    .pfx
  ))

  @doc """
  Resolve a path and enforce that it stays within allowed roots.
  """
  def resolve_allowed_path(path) when is_binary(path) do
    resolved = resolve_path(path)

    with {:ok, root} <- matching_root(resolved),
         true <- no_symlink_under_root?(resolved, root) do
      {:ok, resolved}
    else
      _ -> {:error, "path is outside allowed roots"}
    end
  end

  @doc """
  Resolve a path that assistant file tools may expose.

  This applies the root sandbox first, then filters files and directories that
  commonly hold local credentials.
  """
  def resolve_content_path(path) when is_binary(path) do
    with {:ok, resolved} <- resolve_allowed_path(path),
         false <- restricted_path?(resolved) do
      {:ok, resolved}
    else
      true -> {:error, @unavailable_path_error}
      {:error, _reason} = error -> error
    end
  end

  @doc """
  Check whether a path is within configured tool roots.
  """
  def allowed_path?(path) when is_binary(path) do
    resolved = resolve_path(path)

    match?({:ok, _root}, matching_root(resolved))
  end

  @doc """
  Check whether a path can appear in assistant file-tool output.
  """
  def visible_content_path?(path) when is_binary(path) do
    match?({:ok, _resolved}, resolve_content_path(path))
  end

  @doc """
  Check whether a path is hidden or credential-shaped.
  """
  def restricted_path?(path) when is_binary(path) do
    path
    |> resolve_path()
    |> Path.split()
    |> Enum.any?(&restricted_segment?/1)
  end

  defp resolve_path(path) do
    Path.expand(path)
  end

  defp restricted_segment?("/"), do: false
  defp restricted_segment?(""), do: false
  defp restricted_segment?("."), do: false
  defp restricted_segment?(".."), do: false

  defp restricted_segment?(segment) do
    String.starts_with?(segment, ".") or restricted_filename?(segment)
  end

  defp restricted_filename?(filename) do
    name = String.downcase(filename)
    stem = Path.rootname(name)
    extension = Path.extname(name)

    MapSet.member?(@restricted_exact_names, name) or
      MapSet.member?(@restricted_exact_names, stem) or
      MapSet.member?(@restricted_extensions, extension)
  end

  defp no_symlink_under_root?(path, root) do
    path
    |> paths_under_root(root)
    |> Enum.reduce_while(true, fn prefix, _acc ->
      case File.lstat(prefix) do
        {:ok, %{type: :symlink}} -> {:halt, false}
        {:ok, _} -> {:cont, true}
        {:error, :enoent} -> {:cont, true}
        {:error, _} -> {:halt, false}
      end
    end)
  end

  defp paths_under_root(path, root) do
    relative = Path.relative_to(path, root)

    case relative do
      "." ->
        []

      _ ->
        relative
        |> Path.split()
        |> Enum.scan(root, &Path.join(&2, &1))
    end
  end

  defp matching_root(path) do
    RuntimeConfig.tool_allowed_paths()
    |> Enum.map(&resolve_path/1)
    |> Enum.sort_by(&String.length/1, :desc)
    |> Enum.find_value(:error, fn root ->
      if within_root?(path, root), do: {:ok, root}, else: false
    end)
  end

  defp within_root?(path, root) do
    path_parts = Path.split(path)
    root_parts = Path.split(root)

    Enum.take(path_parts, length(root_parts)) == root_parts
  end
end
