defmodule Maraithon.Tools.BrowserHistoryGet do
  @moduledoc """
  Fetch one browser visit using a `visit_id` returned by browser
  history search, host, or recent-visit tools.

  Calls `Maraithon.LocalBrowserHistory.get_by_guid/2`.
  """

  import Maraithon.Tools.ActionHelpers

  alias Maraithon.LocalBrowserHistory
  alias Maraithon.Tools.LocalBrowserHistoryHelpers

  def execute(args) when is_map(args) do
    with {:ok, user_id} <- required_string(args, "user_id"),
         {:ok, visit_id} <- required_string(args, "visit_id") do
      case LocalBrowserHistory.get_by_guid(user_id, visit_id) do
        nil ->
          {:error, "visit_not_found"}

        visit ->
          {:ok,
           %{
             source: "local_browser_history",
             visit: LocalBrowserHistoryHelpers.serialize_full(visit)
           }}
      end
    end
  end

  def execute(_args), do: {:error, "invalid_args"}
end
