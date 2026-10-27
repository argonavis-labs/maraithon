defmodule Maraithon.Tools.GmailFilters do
  @moduledoc """
  Lists, gets, creates, and deletes Gmail filters.
  """

  alias Maraithon.Tools.ActionHelpers
  alias Maraithon.Tools.GmailApiHelpers

  def execute(args) when is_map(args) do
    action = args |> ActionHelpers.optional_string("action") |> normalize_action("list")

    case action do
      "list" -> list_filters(args)
      "get" -> get_filter(args)
      "create" -> create_filter(args)
      "delete" -> delete_filter(args)
      _ -> {:error, "unsupported_gmail_filters_action"}
    end
  end

  defp list_filters(args) do
    case GmailApiHelpers.request(args, :get, "/users/me/settings/filters") do
      {:ok, %{"filter" => filters}} when is_list(filters) ->
        {:ok, %{source: "gmail", count: length(filters), filters: filters}}

      {:ok, response} ->
        {:ok, %{source: "gmail", count: 0, filters: [], response: response}}

      {:error, reason} ->
        GmailApiHelpers.normalize_error(reason)
    end
  end

  defp get_filter(args) do
    with {:ok, filter_id} <- ActionHelpers.required_string(args, "filter_id") do
      case GmailApiHelpers.request(
             args,
             :get,
             "/users/me/settings/filters/#{URI.encode(filter_id)}"
           ) do
        {:ok, filter} -> {:ok, %{source: "gmail", filter_id: filter_id, filter: filter}}
        {:error, reason} -> GmailApiHelpers.normalize_error(reason)
      end
    end
  end

  defp create_filter(args) do
    body =
      %{
        criteria: criteria(args),
        action: filter_action(args)
      }
      |> GmailApiHelpers.compact()

    case GmailApiHelpers.request(args, :post, "/users/me/settings/filters", body) do
      {:ok, filter} -> {:ok, %{source: "gmail", filter: filter}}
      {:error, reason} -> GmailApiHelpers.normalize_error(reason)
    end
  end

  defp delete_filter(args) do
    with {:ok, filter_id} <- ActionHelpers.required_string(args, "filter_id") do
      case GmailApiHelpers.request(
             args,
             :delete,
             "/users/me/settings/filters/#{URI.encode(filter_id)}"
           ) do
        {:ok, response} -> {:ok, %{source: "gmail", filter_id: filter_id, response: response}}
        {:error, reason} -> GmailApiHelpers.normalize_error(reason)
      end
    end
  end

  defp criteria(args) do
    %{
      from: ActionHelpers.optional_string(args, "from"),
      to: ActionHelpers.optional_string(args, "to"),
      subject: ActionHelpers.optional_string(args, "subject"),
      query: ActionHelpers.optional_string(args, "query"),
      negatedQuery: ActionHelpers.optional_string(args, "negated_query"),
      hasAttachment: GmailApiHelpers.optional_bool(args, "has_attachment"),
      excludeChats: GmailApiHelpers.optional_bool(args, "exclude_chats"),
      size: ActionHelpers.optional_integer(args, "size"),
      sizeComparison: ActionHelpers.optional_string(args, "size_comparison")
    }
    |> GmailApiHelpers.compact()
  end

  defp filter_action(args) do
    %{
      addLabelIds: ActionHelpers.optional_csv(args, "add_label_ids"),
      removeLabelIds: ActionHelpers.optional_csv(args, "remove_label_ids"),
      forward: ActionHelpers.optional_string(args, "forward")
    }
    |> GmailApiHelpers.compact()
  end

  defp normalize_action(nil, default), do: default
  defp normalize_action(action, _default), do: String.downcase(action)
end
