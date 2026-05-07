defmodule Maraithon.Tools.NotionSearch do
  @moduledoc """
  Searches pages and databases in a connected Notion workspace.
  """

  alias Maraithon.Tools.ActionHelpers
  alias Maraithon.Tools.NotionApiHelpers

  @default_limit 10
  @max_limit 100

  def execute(args) when is_map(args) do
    body =
      %{
        query: ActionHelpers.optional_string(args, "query"),
        filter: NotionApiHelpers.optional_map(args, "filter"),
        sort: NotionApiHelpers.optional_map(args, "sort"),
        start_cursor: ActionHelpers.optional_string(args, "start_cursor"),
        page_size: resolve_limit(args)
      }
      |> NotionApiHelpers.compact()

    case NotionApiHelpers.request(args, :post, "/search", body) do
      {:ok, response} -> {:ok, Map.put(response, "source", "notion")}
      {:error, reason} -> NotionApiHelpers.normalize_error(reason)
    end
  end

  defp resolve_limit(args) do
    case ActionHelpers.optional_integer(args, "page_size") do
      value when is_integer(value) -> value |> max(1) |> min(@max_limit)
      _ -> @default_limit
    end
  end
end
