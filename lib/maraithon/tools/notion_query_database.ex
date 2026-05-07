defmodule Maraithon.Tools.NotionQueryDatabase do
  @moduledoc """
  Queries a Notion database.
  """

  alias Maraithon.Tools.ActionHelpers
  alias Maraithon.Tools.NotionApiHelpers

  @default_limit 20
  @max_limit 100

  def execute(args) when is_map(args) do
    with {:ok, database_id} <- ActionHelpers.required_string(args, "database_id") do
      body =
        %{
          filter: NotionApiHelpers.optional_map(args, "filter"),
          sorts: NotionApiHelpers.optional_list(args, "sorts"),
          start_cursor: ActionHelpers.optional_string(args, "start_cursor"),
          page_size: resolve_limit(args)
        }
        |> NotionApiHelpers.compact()

      case NotionApiHelpers.request(
             args,
             :post,
             "/databases/#{URI.encode(database_id)}/query",
             body
           ) do
        {:ok, response} -> {:ok, Map.put(response, "source", "notion")}
        {:error, reason} -> NotionApiHelpers.normalize_error(reason)
      end
    end
  end

  defp resolve_limit(args) do
    case ActionHelpers.optional_integer(args, "page_size") do
      value when is_integer(value) -> value |> max(1) |> min(@max_limit)
      _ -> @default_limit
    end
  end
end
