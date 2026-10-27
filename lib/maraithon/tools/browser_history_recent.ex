defmodule Maraithon.Tools.BrowserHistoryRecent do
  @moduledoc """
  List the user's most recently visited URLs across one or all
  browsers. Use for sweeping "what have I been looking at?" questions.

  Calls `Maraithon.LocalBrowserHistory.recent_visits/2`.
  """

  import Maraithon.Tools.ActionHelpers

  alias Maraithon.LocalBrowserHistory
  alias Maraithon.Tools.LocalBrowserHistoryHelpers

  @default_limit 20
  @max_limit 100

  def execute(args) when is_map(args) do
    with {:ok, user_id} <- required_string(args, "user_id") do
      limit = LocalBrowserHistoryHelpers.normalize_limit(args, @default_limit, @max_limit)

      opts =
        []
        |> Keyword.put(:limit, limit)
        |> maybe_put(:browser, optional_string(args, "browser"))

      visits = LocalBrowserHistory.recent_visits(user_id, opts)

      {:ok,
       %{
         source: "local_browser_history",
         count: length(visits),
         browser: Keyword.get(opts, :browser),
         visits: Enum.map(visits, &LocalBrowserHistoryHelpers.serialize_summary/1)
       }}
    end
  end

  def execute(_args), do: {:error, "invalid_args"}
end
