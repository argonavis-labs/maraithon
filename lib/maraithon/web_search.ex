defmodule Maraithon.WebSearch do
  @moduledoc """
  Lightweight public web search used to enrich sparse internal context.

  The briefing pipeline uses this only as a fallback after CRM and connected
  sources fail to explain a meeting participant or company.
  """

  require Logger

  @default_base_url "https://duckduckgo.com/html/"
  @default_limit 3
  @max_limit 5
  @connect_timeout_ms 3_000
  @receive_timeout_ms 6_000

  def search(query, opts \\ [])

  def search(query, opts) when is_binary(query) and is_list(opts) do
    query = normalize_string(query)

    cond do
      is_nil(query) ->
        {:error, :query_required}

      not enabled?(opts) ->
        {:error, :web_search_disabled}

      true ->
        do_search(query, opts)
    end
  end

  def search(_query, _opts), do: {:error, :query_required}

  defp do_search(query, opts) do
    limit = opts |> Keyword.get(:limit, configured(:limit, @default_limit)) |> clamp_limit()

    url =
      search_url(Keyword.get(opts, :base_url, configured(:base_url, @default_base_url)), query)

    case Req.get(url,
           headers: [
             {"accept", "text/html,application/xhtml+xml"},
             {"user-agent", "Maraithon/1.0 (+https://maraithon.local)"}
           ],
           retry: false,
           redirect: true,
           connect_options: [timeout: @connect_timeout_ms],
           receive_timeout: Keyword.get(opts, :receive_timeout, @receive_timeout_ms)
         ) do
      {:ok, %{status: status, body: body}} when status in 200..299 and is_binary(body) ->
        {:ok,
         %{
           "source" => "duckduckgo",
           "query" => query,
           "results" => body |> parse_results() |> Enum.take(limit),
           "fetched_at" =>
             DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
         }}

      {:ok, %{status: status}} ->
        {:error, {:http_status, status}}

      {:error, reason} ->
        Logger.warning("Web search failed", query: query, reason: inspect(reason))
        {:error, {:http_error, reason}}
    end
  end

  defp parse_results(body) when is_binary(body) do
    anchors =
      ~r/<a\b[^>]*class=["'][^"']*result__a[^"']*["'][^>]*href=["']([^"']+)["'][^>]*>(.*?)<\/a>/is
      |> Regex.scan(body)
      |> Enum.map(fn [_all, href, title] ->
        %{
          "title" => clean_html(title),
          "url" => decode_result_url(href)
        }
      end)

    snippets =
      ~r/<(?:a|div)\b[^>]*class=["'][^"']*result__snippet[^"']*["'][^>]*>(.*?)<\/(?:a|div)>/is
      |> Regex.scan(body)
      |> Enum.map(fn [_all, snippet] -> clean_html(snippet) end)

    anchors
    |> Enum.with_index()
    |> Enum.map(fn {result, index} ->
      result
      |> Map.put("snippet", Enum.at(snippets, index))
      |> Map.put("source", "duckduckgo")
      |> compact_map()
    end)
    |> Enum.reject(&(is_nil(&1["title"]) or is_nil(&1["url"])))
  end

  defp search_url(base_url, query) when is_binary(base_url) do
    uri = URI.parse(base_url)

    query_params =
      uri.query
      |> empty_to_string()
      |> URI.decode_query()
      |> Map.put("q", query)

    %{uri | query: URI.encode_query(query_params)}
    |> URI.to_string()
  end

  defp search_url(_base_url, query), do: search_url(@default_base_url, query)

  defp decode_result_url(href) when is_binary(href) do
    href = html_decode(href)

    href =
      cond do
        String.starts_with?(href, "//") -> "https:" <> href
        String.starts_with?(href, "/") -> "https://duckduckgo.com" <> href
        true -> href
      end

    uri = URI.parse(href)

    case URI.decode_query(uri.query || "") do
      %{"uddg" => uddg} when is_binary(uddg) -> URI.decode(uddg)
      _ -> href
    end
  end

  defp clean_html(value) when is_binary(value) do
    value
    |> String.replace(~r/<script\b.*?<\/script>/is, " ")
    |> String.replace(~r/<style\b.*?<\/style>/is, " ")
    |> String.replace(~r/<[^>]+>/, " ")
    |> html_decode()
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    |> truncate(320)
    |> normalize_string()
  end

  defp html_decode(value) when is_binary(value) do
    value
    |> String.replace("&amp;", "&")
    |> String.replace("&quot;", "\"")
    |> String.replace("&#39;", "'")
    |> String.replace("&apos;", "'")
    |> String.replace("&lt;", "<")
    |> String.replace("&gt;", ">")
    |> String.replace("&nbsp;", " ")
    |> decode_numeric_entities()
  end

  defp decode_numeric_entities(value) do
    Regex.replace(~r/&#(\d+);/, value, fn _match, digits ->
      case Integer.parse(digits) do
        {codepoint, ""} when codepoint > 0 ->
          <<codepoint::utf8>>

        _ ->
          " "
      end
    end)
  end

  defp enabled?(opts) do
    case Keyword.get(opts, :enabled, configured(:enabled, true)) do
      false -> false
      "false" -> false
      "0" -> false
      _ -> true
    end
  end

  defp configured(key, default) do
    :maraithon
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(key, default)
  end

  defp clamp_limit(value) when is_integer(value), do: value |> max(1) |> min(@max_limit)
  defp clamp_limit(_value), do: @default_limit

  defp empty_to_string(nil), do: ""
  defp empty_to_string(value), do: value

  defp normalize_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_string(_value), do: nil

  defp truncate(nil, _limit), do: nil

  defp truncate(value, limit) when is_binary(value) do
    if String.length(value) > limit do
      String.slice(value, 0, limit) <> "..."
    else
      value
    end
  end

  defp compact_map(map) do
    map
    |> Enum.reject(fn {_key, value} -> value in [nil, "", [], %{}] end)
    |> Map.new()
  end
end
