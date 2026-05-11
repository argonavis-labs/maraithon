defmodule Maraithon.Tools.BrowserHistorySearch do
  @moduledoc """
  Search the user's browser history for a substring in title, URL, or
  host. Use when the user references something they were reading or
  researching online by topic.

  Calls `Maraithon.LocalBrowserHistory.search/3`.
  """

  import Maraithon.Tools.ActionHelpers

  alias Maraithon.LocalBrowserHistory
  alias Maraithon.Tools.LocalBrowserHistoryHelpers

  @default_limit 20
  @max_limit 100

  def execute(args) when is_map(args) do
    with {:ok, user_id} <- required_string(args, "user_id"),
         {:ok, query} <- required_string(args, "query") do
      limit = LocalBrowserHistoryHelpers.normalize_limit(args, @default_limit, @max_limit)

      opts =
        []
        |> Keyword.put(:limit, limit)
        |> maybe_put(:browser, optional_string(args, "browser"))

      visits = LocalBrowserHistory.search(user_id, query, opts)

      {:ok,
       %{
         source: "local_browser_history",
         query: query,
         browser: Keyword.get(opts, :browser),
         count: length(visits),
         visits: Enum.map(visits, &LocalBrowserHistoryHelpers.serialize_summary/1)
       }}
    end
  end

  def execute(_args), do: {:error, "invalid_args"}
end
