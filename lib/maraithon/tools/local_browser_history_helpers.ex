defmodule Maraithon.Tools.LocalBrowserHistoryHelpers do
  @moduledoc """
  Shared serialization and argument helpers for the browser history
  tool surface (`browser_history_recent`, `browser_history_by_host`,
  `browser_history_search`, `browser_history_get`).
  """

  alias Maraithon.LocalBrowserHistory
  alias Maraithon.LocalBrowserHistory.LocalVisit

  @doc """
  Compact summary used by list, host, and search results.

  Returns the URL as-is for normal hosts but redacts to `<private>` if
  the host is on the privacy deny-list. The ingest layer already drops
  these rows, so this is defense-in-depth — the assistant must never
  surface a banking, medical, or adult URL verbatim even if a row
  somehow slipped through.
  """
  def serialize_summary(%LocalVisit{} = visit) do
    private? = LocalBrowserHistory.private_host?(visit.host)

    %{
      visit_id: visit.guid,
      guid: visit.guid,
      browser: visit.browser,
      url: redact_if_private(visit.url, private?),
      title: redact_if_private(visit.title, private?),
      host: visit.host,
      visit_count: visit.visit_count,
      is_typed_url: visit.is_typed_url,
      last_visited_at: iso8601(visit.last_visited_at)
    }
  end

  def serialize_summary(visit) when is_map(visit), do: visit

  def serialize_full(%LocalVisit{} = visit) do
    private? = LocalBrowserHistory.private_host?(visit.host)

    %{
      visit_id: visit.guid,
      guid: visit.guid,
      source: visit.source,
      browser: visit.browser,
      url: redact_if_private(visit.url, private?),
      title: redact_if_private(visit.title, private?),
      host: visit.host,
      visit_count: visit.visit_count,
      is_typed_url: visit.is_typed_url,
      last_visited_at: iso8601(visit.last_visited_at)
    }
  end

  def serialize_full(visit) when is_map(visit), do: visit

  @doc """
  Clamp an integer `limit` argument to `[1, max_limit]`, defaulting to
  `default` when the argument is missing or unparseable.
  """
  def normalize_limit(args, default, max_limit)
      when is_map(args) and is_integer(default) and is_integer(max_limit) do
    case Map.get(args, "limit") do
      value when is_integer(value) and value > 0 -> min(value, max_limit)
      value when is_binary(value) -> parse_limit(value, default, max_limit)
      _ -> default
    end
  end

  defp parse_limit(value, default, max_limit) do
    case Integer.parse(String.trim(value)) do
      {parsed, ""} when parsed > 0 -> min(parsed, max_limit)
      _ -> default
    end
  end

  defp redact_if_private(_value, true), do: "<private>"
  defp redact_if_private(value, false), do: value

  defp iso8601(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp iso8601(_value), do: nil
end
