defmodule Maraithon.Tools.NotionUpdatePage do
  @moduledoc """
  Updates a Notion page's properties, icon, cover, or archived state.
  """

  alias Maraithon.Tools.ActionHelpers
  alias Maraithon.Tools.NotionApiHelpers

  def execute(args) when is_map(args) do
    with {:ok, page_id} <- ActionHelpers.required_string(args, "page_id") do
      body =
        %{
          properties: NotionApiHelpers.optional_map(args, "properties"),
          icon: NotionApiHelpers.optional_map(args, "icon"),
          cover: NotionApiHelpers.optional_map(args, "cover"),
          archived: NotionApiHelpers.optional_bool(args, "archived")
        }
        |> NotionApiHelpers.compact()

      case NotionApiHelpers.request(args, :patch, "/pages/#{URI.encode(page_id)}", body) do
        {:ok, page} -> {:ok, Map.put(page, "source", "notion")}
        {:error, reason} -> NotionApiHelpers.normalize_error(reason)
      end
    end
  end
end
