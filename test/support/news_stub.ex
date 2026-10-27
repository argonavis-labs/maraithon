defmodule Maraithon.TestSupport.NewsStub do
  def fetch_for_brief(config, now) do
    {:ok,
     %{
       "items" => [
         %{
           "source" => "Test News",
           "title" => "Slack launches a user-token briefing improvement",
           "summary" => "The update matters for private channels and DMs.",
           "url" => "https://example.com/slack-news",
           "published_at" => DateTime.to_iso8601(now)
         }
       ],
       "feeds" => Map.get(config, "news_feeds", []),
       "status" => "ready",
       "fetched_at" => DateTime.to_iso8601(now),
       "fetches" => [
         %{
           "source" => "news",
           "mode" => "rss",
           "status" => "ok",
           "count" => 1
         }
       ]
     }}
  end
end
