defmodule Maraithon.Tools.NotionCreatePage do
  @moduledoc """
  Creates a Notion page under a parent page or database.
  """

  alias Maraithon.Tools.NotionApiHelpers

  def execute(args) when is_map(args) do
    with {:ok, parent} <- required_map(args, "parent"),
         {:ok, properties} <- required_map(args, "properties") do
      body =
        %{
          parent: parent,
          properties: properties,
          children: NotionApiHelpers.optional_list(args, "children"),
          icon: NotionApiHelpers.optional_map(args, "icon"),
          cover: NotionApiHelpers.optional_map(args, "cover")
        }
        |> NotionApiHelpers.compact()

      case NotionApiHelpers.request(args, :post, "/pages", body) do
        {:ok, page} -> {:ok, Map.put(page, "source", "notion")}
        {:error, reason} -> NotionApiHelpers.normalize_error(reason)
      end
    end
  end

  defp required_map(args, key) do
    case Map.get(args, key) do
      value when is_map(value) and map_size(value) > 0 -> {:ok, value}
      _ -> {:error, "#{key} is required"}
    end
  end
end
