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
  @page_text_limit 8_000

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

  def fetch_page(url, opts \\ [])

  def fetch_page(url, opts) when is_binary(url) and is_list(opts) do
    url = normalize_string(url)

    cond do
      is_nil(url) ->
        {:error, :url_required}

      not enabled?(opts) ->
        {:error, :web_search_disabled}

      not fetchable_url?(url, opts) ->
        {:error, :invalid_url}

      true ->
        do_fetch_page(url, opts)
    end
  end

  def fetch_page(_url, _opts), do: {:error, :url_required}

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

  defp do_fetch_page(url, opts) do
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
      {:ok, %{status: status, body: body} = response} when status in 200..299 ->
        final_url = Map.get(response, :url) || Map.get(response, "url") || url

        case response_body_to_binary(body) do
          body when is_binary(body) ->
            {:ok,
             %{
               "source" => "web_page",
               "url" => final_url |> to_string(),
               "title" => html_title(body),
               "description" => html_meta_description(body),
               "text" =>
                 body
                 |> readable_html_text()
                 |> truncate(Keyword.get(opts, :text_limit, @page_text_limit)),
               "fetched_at" =>
                 DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
             }
             |> compact_map()}

          nil ->
            {:error, :invalid_body}
        end

      {:ok, %{status: status}} ->
        {:error, {:http_status, status}}

      {:error, reason} ->
        Logger.warning("Web page fetch failed", url: url, reason: inspect(reason))
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

  defp response_body_to_binary(body) when is_binary(body), do: body

  defp response_body_to_binary(body) when is_list(body) do
    IO.iodata_to_binary(body)
  rescue
    ArgumentError -> nil
  end

  defp response_body_to_binary(_body), do: nil

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

  defp readable_html_text(value) when is_binary(value) do
    value
    |> String.replace(~r/<script\b.*?<\/script>/is, " ")
    |> String.replace(~r/<style\b.*?<\/style>/is, " ")
    |> String.replace(~r/<noscript\b.*?<\/noscript>/is, " ")
    |> String.replace(~r/<svg\b.*?<\/svg>/is, " ")
    |> String.replace(~r/<!--.*?-->/s, " ")
    |> String.replace(~r/<\/(?:p|div|section|article|header|footer|main|li|h[1-6])>/i, "\n")
    |> String.replace(~r/<[^>]+>/, " ")
    |> html_decode()
    |> String.replace(~r/[ \t]+/, " ")
    |> String.replace(~r/\n\s+/, "\n")
    |> String.replace(~r/\n{3,}/, "\n\n")
    |> String.trim()
    |> normalize_string()
  end

  defp readable_html_text(_value), do: nil

  defp html_title(body) when is_binary(body) do
    case Regex.run(~r/<title\b[^>]*>(.*?)<\/title>/is, body, capture: :all_but_first) do
      [title] -> clean_html(title)
      _ -> nil
    end
  end

  defp html_title(_body), do: nil

  defp html_meta_description(body) when is_binary(body) do
    description =
      Regex.run(
        ~r/<meta\b[^>]*(?:name|property)=["'](?:description|og:description)["'][^>]*content=["']([^"']+)["'][^>]*>/is,
        body,
        capture: :all_but_first
      ) ||
        Regex.run(
          ~r/<meta\b[^>]*content=["']([^"']+)["'][^>]*(?:name|property)=["'](?:description|og:description)["'][^>]*>/is,
          body,
          capture: :all_but_first
        )

    case description do
      [value] -> clean_html(value)
      _ -> nil
    end
  end

  defp html_meta_description(_body), do: nil

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

  defp fetchable_url?(url, opts) do
    uri = URI.parse(url)

    uri.scheme in ["http", "https"] and is_binary(uri.host) and
      (Keyword.get(opts, :allow_private, false) or public_host?(uri.host))
  rescue
    URI.Error -> false
  end

  defp public_host?(host) when is_binary(host) do
    host = String.downcase(host)

    cond do
      host in ["localhost", "0.0.0.0"] ->
        false

      String.ends_with?(host, ".local") ->
        false

      true ->
        public_ip_or_hostname?(host)
    end
  end

  defp public_host?(_host), do: false

  defp public_ip_or_hostname?(host) do
    case :inet.parse_address(String.to_charlist(host)) do
      {:ok, ip} -> public_ip?(ip)
      {:error, :einval} -> true
    end
  end

  defp public_ip?({10, _, _, _}), do: false
  defp public_ip?({127, _, _, _}), do: false
  defp public_ip?({169, 254, _, _}), do: false
  defp public_ip?({172, second, _, _}) when second >= 16 and second <= 31, do: false
  defp public_ip?({192, 168, _, _}), do: false
  defp public_ip?({0, _, _, _}), do: false
  defp public_ip?({_, _, _, _}), do: true
  defp public_ip?({0, 0, 0, 0, 0, 0, 0, 1}), do: false
  defp public_ip?({0xFE80, _, _, _, _, _, _, _}), do: false
  defp public_ip?({0xFC00, _, _, _, _, _, _, _}), do: false
  defp public_ip?({0xFD00, _, _, _, _, _, _, _}), do: false
  defp public_ip?({_a, _b, _c, _d, _e, _f, _g, _h}), do: true
  defp public_ip?(_ip), do: false

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

  # Fetched pages can contain invalid UTF-8; String.length/String.slice
  # raise on such bytes (this crashed the whole agent process mid-briefing),
  # so scrub before any grapheme walking.
  defp truncate(value, limit) when is_binary(value) do
    value = scrub_utf8(value)

    if String.length(value) > limit do
      String.slice(value, 0, limit) <> "..."
    else
      value
    end
  end

  defp scrub_utf8(value) do
    if String.valid?(value) do
      value
    else
      value
      |> String.chunk(:valid)
      |> Enum.filter(&String.valid?/1)
      |> Enum.join()
    end
  end

  defp compact_map(map) do
    map
    |> Enum.reject(fn {_key, value} -> value in [nil, "", [], %{}] end)
    |> Map.new()
  end
end
