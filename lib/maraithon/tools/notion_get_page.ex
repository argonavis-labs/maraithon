defmodule Maraithon.Tools.NotionGetPage do
  @moduledoc """
  Gets a Notion page by id.
  """

  alias Maraithon.Tools.ActionHelpers
  alias Maraithon.Tools.NotionApiHelpers

  def execute(args) when is_map(args) do
    with {:ok, page_id} <- ActionHelpers.required_string(args, "page_id") do
      case NotionApiHelpers.request(args, :get, "/pages/#{URI.encode(page_id)}") do
        {:ok, page} -> {:ok, Map.put(page, "source", "notion")}
        {:error, reason} -> NotionApiHelpers.normalize_error(reason)
      end
    end
  end
end
