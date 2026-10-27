defmodule Maraithon.Tools.GoogleContactsSearch do
  @moduledoc """
  Searches connected Google Contacts.
  """

  alias Maraithon.Tools.ActionHelpers
  alias Maraithon.Tools.GmailApiHelpers

  @default_limit 10
  @max_limit 30

  def execute(args) when is_map(args) do
    with {:ok, query} <- ActionHelpers.required_string(args, "query") do
      params =
        %{
          query: query,
          pageSize: resolve_limit(args),
          readMask: "names,emailAddresses,phoneNumbers,organizations"
        }
        |> URI.encode_query()

      case GmailApiHelpers.people_request(args, :get, "/people:searchContacts?#{params}") do
        {:ok, %{"results" => results}} when is_list(results) ->
          {:ok,
           %{source: "google_contacts", query: query, count: length(results), results: results}}

        {:ok, response} ->
          {:ok,
           %{source: "google_contacts", query: query, count: 0, results: [], response: response}}

        {:error, reason} ->
          GmailApiHelpers.normalize_error(reason)
      end
    end
  end

  defp resolve_limit(args) do
    case ActionHelpers.optional_integer(args, "max_results") do
      value when is_integer(value) -> value |> max(1) |> min(@max_limit)
      _ -> @default_limit
    end
  end
end
