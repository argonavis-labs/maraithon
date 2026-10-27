defmodule Maraithon.Tools.BrowserHistoryByHost do
  @moduledoc """
  Filter the user's browser history by host substring. Use when the
  user references a domain (e.g. "what was that article from
  techmeme?").

  Calls `Maraithon.LocalBrowserHistory.visits_by_host/3`.
  """

  import Maraithon.Tools.ActionHelpers

  alias Maraithon.LocalBrowserHistory
  alias Maraithon.Tools.LocalBrowserHistoryHelpers

  @default_limit 20
  @max_limit 100

  def execute(args) when is_map(args) do
    with {:ok, user_id} <- required_string(args, "user_id"),
         {:ok, host} <- required_string(args, "host") do
      limit = LocalBrowserHistoryHelpers.normalize_limit(args, @default_limit, @max_limit)

      opts =
        []
        |> Keyword.put(:limit, limit)
        |> maybe_put(:browser, optional_string(args, "browser"))

      visits = LocalBrowserHistory.visits_by_host(user_id, host, opts)

      {:ok,
       %{
         source: "local_browser_history",
         host: host,
         browser: Keyword.get(opts, :browser),
         count: length(visits),
         visits: Enum.map(visits, &LocalBrowserHistoryHelpers.serialize_summary/1)
       }}
    end
  end

  def execute(_args), do: {:error, "invalid_args"}
end
