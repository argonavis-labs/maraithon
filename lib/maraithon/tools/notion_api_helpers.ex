defmodule Maraithon.Tools.NotionApiHelpers do
  @moduledoc false

  alias Maraithon.OAuth
  alias Maraithon.OAuth.Notion
  alias Maraithon.Tools.ActionHelpers
  alias Maraithon.Tools.ToolErrorCopy

  def request(args, method, path, body \\ nil)
      when is_map(args) and method in [:get, :post, :patch, :delete] and is_binary(path) do
    with {:ok, user_id} <- ActionHelpers.required_string(args, "user_id"),
         {:ok, access_token} <- OAuth.get_valid_access_token(user_id, "notion") do
      Notion.api_request(method, path, access_token, body)
    end
  end

  def normalize_error(:no_token), do: {:error, "notion_not_connected"}
  def normalize_error(:reauth_required), do: {:error, "notion_reauth_required"}
  def normalize_error(:no_refresh_token), do: {:error, "notion_reconnect_required"}

  def normalize_error({:http_status, status, body}) when status in [401, 403],
    do:
      {:error, ToolErrorCopy.connected_source({:http_status, status, body}, notion_error_opts())}

  def normalize_error(reason),
    do: {:error, ToolErrorCopy.connected_source(reason, notion_error_opts())}

  def optional_map(args, key) when is_map(args) and is_binary(key) do
    case Map.get(args, key) do
      value when is_map(value) -> value
      _ -> nil
    end
  end

  def optional_list(args, key) when is_map(args) and is_binary(key) do
    case Map.get(args, key) do
      value when is_list(value) -> value
      _ -> []
    end
  end

  def optional_bool(args, key) do
    case ActionHelpers.optional_string(args, key) do
      value when value in ["true", "TRUE", "1"] -> true
      value when value in ["false", "FALSE", "0"] -> false
      _ -> nil
    end
  end

  def compact(map) when is_map(map) do
    map
    |> Enum.reject(fn {_key, value} -> blank?(value) end)
    |> Map.new()
  end

  defp notion_error_opts do
    [
      label: "Notion",
      not_connected: "notion_not_connected",
      reauth_required: "notion_reauth_required",
      reconnect_required: "notion_reconnect_required"
    ]
  end

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?([]), do: true
  defp blank?(%{}), do: true
  defp blank?(_value), do: false
end
