defmodule Maraithon.News do
  @moduledoc """
  Lightweight news acquisition for morning briefings.

  Feeds are configured on the user's briefing-capable agent config, so the
  morning brief can include operator-specific news without hard-coding a global
  editorial bundle.
  """

  alias Maraithon.HTTP

  require Logger

  @default_limit 6
  @max_feeds 8
  @max_items_per_feed 8

  def fetch_for_brief(config, now \\ DateTime.utc_now())

  def fetch_for_brief(config, now) when is_map(config) do
    if enabled?(config) do
      feeds = configured_feeds(config)
      limit = integer_in_range(config["news_limit"], @default_limit, 1, 40)

      {feed_item_lists, fetches} =
        feeds
        |> Enum.take(@max_feeds)
        |> Enum.reduce({[], []}, fn feed, {item_acc, fetch_acc} ->
          case fetch_feed(feed, now) do
            {:ok, feed_items} ->
              {[feed_items | item_acc],
               [
                 %{
                   "source" => "news",
                   "mode" => "rss",
                   "status" => "ok",
                   "url" => feed["url"],
                   "count" => length(feed_items)
                 }
                 | fetch_acc
               ]}

            {:error, reason} ->
              Logger.warning("News feed fetch failed", url: feed["url"], reason: inspect(reason))

              {item_acc,
               [
                 %{
                   "source" => "news",
                   "mode" => "rss",
                   "status" => "error",
                   "url" => feed["url"],
                   "reason" => inspect(reason)
                 }
                 | fetch_acc
               ]}
          end
        end)

      # Interleave feeds instead of globally sorting by recency: a
      # fast-publishing feed (Techmeme) would otherwise crowd every other
      # source out of the limit, leaving the brief a single-feed digest.
      items =
        feed_item_lists
        |> Enum.reverse()
        |> Enum.map(&Enum.sort_by(&1, fn item -> published_sort_key(item) end, :desc))
        |> interleave()
        |> Enum.take(limit)

      {:ok,
       %{
         "items" => items,
         "feeds" => Enum.map(feeds, &Map.take(&1, ["name", "url"])),
         "status" => if(items == [], do: "partial", else: "ready"),
         "fetched_at" => DateTime.to_iso8601(now),
         "fetches" => Enum.reverse(fetches)
       }}
    else
      {:ok,
       %{
         "items" => [],
         "feeds" => [],
         "status" => "disabled",
         "fetched_at" => DateTime.to_iso8601(now),
         "fetches" => []
       }}
    end
  end

  def fetch_for_brief(_config, _now), do: fetch_for_brief(%{})

  defp enabled?(config) do
    case config["news_enabled"] do
      false -> false
      "false" -> false
      "0" -> false
      _ -> configured_feeds(config) != []
    end
  end

  defp configured_feeds(config) do
    config
    |> Map.get("news_feeds", [])
    |> List.wrap()
    |> Enum.map(&normalize_feed/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq_by(& &1["url"])
  end

  defp normalize_feed(%{"url" => url} = feed) when is_binary(url) do
    case normalize_url(url) do
      nil ->
        nil

      normalized_url ->
        %{
          "name" => normalize_string(feed["name"]) || URI.parse(normalized_url).host || "News",
          "url" => normalized_url
        }
    end
  end

  defp normalize_feed(%{url: url} = feed) when is_binary(url) do
    normalize_feed(%{"url" => url, "name" => Map.get(feed, :name)})
  end

  defp normalize_feed(url) when is_binary(url), do: normalize_feed(%{"url" => url})
  defp normalize_feed(_feed), do: nil

  defp normalize_url(url) when is_binary(url) do
    trimmed = String.trim(url)
    uri = URI.parse(trimmed)

    if uri.scheme in ["http", "https"] and is_binary(uri.host) do
      trimmed
    end
  end

  defp fetch_feed(%{"url" => url} = feed, _now) do
    headers = [{"accept", "application/rss+xml, application/atom+xml, application/xml, text/xml"}]

    with {:ok, body} when is_binary(body) <- http_module().get(url, headers),
         {:ok, items} <- parse_feed(body, feed) do
      {:ok, Enum.take(items, @max_items_per_feed)}
    else
      {:ok, body} -> {:error, {:unexpected_body, body |> inspect() |> String.slice(0, 120)}}
      {:error, reason} -> {:error, reason}
      other -> {:error, other}
    end
  end

  defp parse_feed(body, feed) when is_binary(body) do
    items =
      parse_tag_blocks(body, "item")
      |> Enum.map(&parse_rss_item(&1, feed))
      |> Enum.reject(&is_nil/1)

    atom_items =
      parse_tag_blocks(body, "entry")
      |> Enum.map(&parse_atom_entry(&1, feed))
      |> Enum.reject(&is_nil/1)

    case items ++ atom_items do
      [] -> {:error, :no_feed_items}
      parsed -> {:ok, parsed}
    end
  end

  defp parse_tag_blocks(body, tag) do
    ~r/<#{tag}\b[^>]*>(.*?)<\/#{tag}>/is
    |> Regex.scan(body, capture: :all_but_first)
    |> Enum.map(fn [block] -> block end)
  end

  defp parse_rss_item(block, feed) do
    build_item(
      feed,
      text_tag(block, "title"),
      text_tag(block, "link"),
      text_tag(block, "description"),
      text_tag(block, "pubDate") || text_tag(block, "dc:date")
    )
  end

  defp parse_atom_entry(block, feed) do
    link =
      case Regex.run(~r/<link\b[^>]*href=["']([^"']+)["'][^>]*>/is, block) do
        [_, href] -> decode_text(href)
        _ -> text_tag(block, "link")
      end

    build_item(
      feed,
      text_tag(block, "title"),
      link,
      text_tag(block, "summary") || text_tag(block, "content"),
      text_tag(block, "updated") || text_tag(block, "published")
    )
  end

  defp build_item(_feed, nil, _url, _summary, _published_at), do: nil

  defp build_item(feed, title, url, summary, published_at) do
    %{
      "source" => feed["name"],
      "title" => truncate(title, 180),
      "url" => normalize_string(url),
      "summary" => summary |> strip_html() |> truncate(260),
      "published_at" => normalize_string(published_at)
    }
  end

  defp text_tag(block, tag) do
    escaped = Regex.escape(tag)

    case Regex.run(~r/<#{escaped}\b[^>]*>(.*?)<\/#{escaped}>/is, block) do
      [_, value] -> decode_text(value)
      _ -> nil
    end
  end

  defp decode_text(value) when is_binary(value) do
    value
    |> String.replace(~r/<!\[CDATA\[(.*?)\]\]>/s, "\\1")
    |> String.replace("&amp;", "&")
    |> String.replace("&lt;", "<")
    |> String.replace("&gt;", ">")
    |> String.replace("&quot;", "\"")
    |> String.replace("&#39;", "'")
    |> normalize_string()
  end

  defp strip_html(nil), do: nil

  defp strip_html(value) when is_binary(value) do
    value
    |> String.replace(~r/<[^>]+>/, " ")
    |> normalize_string()
  end

  defp interleave(lists) do
    if Enum.all?(lists, &(&1 == [])) do
      []
    else
      heads =
        lists
        |> Enum.map(&List.first/1)
        |> Enum.reject(&is_nil/1)

      tails =
        Enum.map(lists, fn
          [] -> []
          [_head | tail] -> tail
        end)

      heads ++ interleave(tails)
    end
  end

  defp published_sort_key(%{"published_at" => published_at}) when is_binary(published_at) do
    case DateTime.from_iso8601(published_at) do
      {:ok, datetime, _offset} -> DateTime.to_unix(datetime, :second)
      _ -> 0
    end
  end

  defp published_sort_key(_item), do: 0

  defp integer_in_range(value, default, min, max) when is_integer(value) do
    if value in min..max, do: value, else: default
  end

  defp integer_in_range(value, default, min, max) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, ""} -> integer_in_range(parsed, default, min, max)
      _ -> default
    end
  end

  defp integer_in_range(_value, default, _min, _max), do: default

  defp truncate(nil, _limit), do: nil

  defp truncate(value, limit) when is_binary(value) do
    if String.length(value) > limit do
      String.slice(value, 0, limit - 3) <> "..."
    else
      value
    end
  end

  defp normalize_string(value) when is_binary(value) do
    case value |> String.replace(~r/\s+/, " ") |> String.trim() do
      "" -> nil
      normalized -> normalized
    end
  end

  defp normalize_string(_value), do: nil

  defp http_module do
    Application.get_env(:maraithon, __MODULE__, [])
    |> Keyword.get(:http_module, HTTP)
  end
end
