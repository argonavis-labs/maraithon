defmodule Maraithon.Tools.NotionBlocks do
  @moduledoc """
  Lists, appends, updates, or archives Notion blocks.
  """

  alias Maraithon.Tools.ActionHelpers
  alias Maraithon.Tools.NotionApiHelpers

  @default_limit 50
  @max_limit 100

  def execute(args) when is_map(args) do
    action = args |> ActionHelpers.optional_string("action") |> normalize_action("list_children")

    case action do
      "list_children" -> list_children(args)
      "append_children" -> append_children(args)
      "update" -> update_block(args)
      "archive" -> archive_block(args)
      _ -> {:error, "unsupported_notion_blocks_action"}
    end
  end

  defp list_children(args) do
    with {:ok, block_id} <- ActionHelpers.required_string(args, "block_id") do
      params =
        %{
          page_size: resolve_limit(args),
          start_cursor: ActionHelpers.optional_string(args, "start_cursor")
        }
        |> NotionApiHelpers.compact()
        |> URI.encode_query()

      case NotionApiHelpers.request(
             args,
             :get,
             "/blocks/#{URI.encode(block_id)}/children?#{params}"
           ) do
        {:ok, response} -> {:ok, Map.put(response, "source", "notion")}
        {:error, reason} -> NotionApiHelpers.normalize_error(reason)
      end
    end
  end

  defp append_children(args) do
    with {:ok, block_id} <- ActionHelpers.required_string(args, "block_id"),
         children when is_list(children) and children != [] <-
           NotionApiHelpers.optional_list(args, "children") do
      body = %{children: children}

      case NotionApiHelpers.request(
             args,
             :patch,
             "/blocks/#{URI.encode(block_id)}/children",
             body
           ) do
        {:ok, response} -> {:ok, Map.put(response, "source", "notion")}
        {:error, reason} -> NotionApiHelpers.normalize_error(reason)
      end
    else
      [] -> {:error, "children is required"}
      {:error, reason} -> {:error, reason}
    end
  end

  defp update_block(args) do
    with {:ok, block_id} <- ActionHelpers.required_string(args, "block_id"),
         {:ok, patch} <- required_patch(args) do
      case NotionApiHelpers.request(args, :patch, "/blocks/#{URI.encode(block_id)}", patch) do
        {:ok, response} -> {:ok, Map.put(response, "source", "notion")}
        {:error, reason} -> NotionApiHelpers.normalize_error(reason)
      end
    end
  end

  defp archive_block(args) do
    with {:ok, block_id} <- ActionHelpers.required_string(args, "block_id") do
      case NotionApiHelpers.request(args, :patch, "/blocks/#{URI.encode(block_id)}", %{
             archived: true
           }) do
        {:ok, response} -> {:ok, Map.put(response, "source", "notion")}
        {:error, reason} -> NotionApiHelpers.normalize_error(reason)
      end
    end
  end

  defp required_patch(args) do
    patch =
      args
      |> NotionApiHelpers.optional_map("patch")
      |> case do
        nil -> %{}
        value -> value
      end

    if patch == %{}, do: {:error, "patch is required"}, else: {:ok, patch}
  end

  defp resolve_limit(args) do
    case ActionHelpers.optional_integer(args, "page_size") do
      value when is_integer(value) -> value |> max(1) |> min(@max_limit)
      _ -> @default_limit
    end
  end

  defp normalize_action(nil, default), do: default
  defp normalize_action(action, _default), do: String.downcase(action)
end
