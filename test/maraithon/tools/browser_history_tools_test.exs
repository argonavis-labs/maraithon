defmodule Maraithon.Tools.BrowserHistoryToolsTest do
  use Maraithon.DataCase, async: true

  alias Maraithon.Capabilities
  alias Maraithon.LocalBrowserHistory
  alias Maraithon.Tools

  defp sample_visit(guid, overrides \\ %{}) do
    Map.merge(
      %{
        "local_id" => "v:#{guid}",
        "guid" => guid,
        "browser" => "chrome",
        "url" => "https://example.com/article-#{guid}",
        "title" => "Article #{guid}",
        "host" => "example.com",
        "visit_count" => 1,
        "is_typed_url" => false,
        "last_visited_at" => "2026-05-10T13:14:22Z"
      },
      overrides
    )
  end

  defp seed_user(label) do
    user_id = "bh-tool-#{label}-#{System.unique_integer([:positive])}@example.com"
    device_id = Ecto.UUID.generate()
    {user_id, device_id}
  end

  describe "browser_history_recent input_schema" do
    test "marks user_id as required" do
      schema = Capabilities.tool_descriptor("browser_history_recent").input_schema
      assert "user_id" in schema["required"]
      assert schema["properties"]["limit"]["type"] == "integer"
      assert schema["properties"]["browser"]["type"] == "string"
    end
  end

  describe "browser_history_recent execute/1" do
    test "returns visits newest first" do
      {user_id, device_id} = seed_user("recent")

      {:ok, _} =
        LocalBrowserHistory.ingest_batch(user_id, device_id, [
          sample_visit("g1", %{
            "title" => "older",
            "last_visited_at" => "2026-05-10T10:00:00Z"
          }),
          sample_visit("g2", %{
            "title" => "newer",
            "last_visited_at" => "2026-05-10T12:00:00Z"
          })
        ])

      assert {:ok, result} =
               Tools.execute("browser_history_recent", %{"user_id" => user_id})

      assert result.source == "local_browser_history"
      assert result.count == 2
      [first, _] = result.visits
      assert first.title == "newer"
      assert first.visit_id == "chrome:g2"
    end

    test "filters by browser" do
      {user_id, device_id} = seed_user("recent-b")

      {:ok, _} =
        LocalBrowserHistory.ingest_batch(user_id, device_id, [
          sample_visit("c1", %{"browser" => "chrome"}),
          sample_visit("s1", %{"browser" => "safari"})
        ])

      assert {:ok, %{count: 1, visits: [v]}} =
               Tools.execute("browser_history_recent", %{
                 "user_id" => user_id,
                 "browser" => "safari"
               })

      assert v.browser == "safari"
    end

    test "rejects missing user_id" do
      assert {:error, _} = Tools.execute("browser_history_recent", %{})
    end
  end

  describe "browser_history_by_host execute/1" do
    test "filters by host substring" do
      {user_id, device_id} = seed_user("host")

      {:ok, _} =
        LocalBrowserHistory.ingest_batch(user_id, device_id, [
          sample_visit("t1", %{
            "host" => "www.techmeme.com",
            "url" => "https://www.techmeme.com/a"
          }),
          sample_visit("hn", %{
            "host" => "news.ycombinator.com",
            "url" => "https://news.ycombinator.com/x"
          })
        ])

      assert {:ok, %{count: 1, visits: [v]}} =
               Tools.execute("browser_history_by_host", %{
                 "user_id" => user_id,
                 "host" => "techmeme"
               })

      assert v.host == "www.techmeme.com"
    end

    test "rejects missing host" do
      {user_id, _} = seed_user("host-missing")

      assert {:error, _} =
               Tools.execute("browser_history_by_host", %{"user_id" => user_id})
    end
  end

  describe "browser_history_search execute/1" do
    test "matches title and url substring" do
      {user_id, device_id} = seed_user("search")

      {:ok, _} =
        LocalBrowserHistory.ingest_batch(user_id, device_id, [
          sample_visit("t1", %{
            "host" => "techmeme.com",
            "url" => "https://techmeme.com/transformers-explained",
            "title" => "Transformers explained"
          }),
          sample_visit("b", %{
            "host" => "blog.example.com",
            "url" => "https://blog.example.com/biking",
            "title" => "Weekend ride"
          })
        ])

      assert {:ok, %{count: 1, visits: [v]}} =
               Tools.execute("browser_history_search", %{
                 "user_id" => user_id,
                 "query" => "transformer"
               })

      assert v.title == "Transformers explained"
    end

    test "rejects missing query" do
      {user_id, _} = seed_user("search-missing")

      assert {:error, _} =
               Tools.execute("browser_history_search", %{"user_id" => user_id})
    end
  end

  describe "browser_history_get execute/1" do
    test "returns full record by guid" do
      {user_id, device_id} = seed_user("get")

      {:ok, _} =
        LocalBrowserHistory.ingest_batch(user_id, device_id, [
          sample_visit("findme", %{
            "title" => "Hello",
            "url" => "https://example.com/findme"
          })
        ])

      assert {:ok, %{visit: visit}} =
               Tools.execute("browser_history_get", %{
                 "user_id" => user_id,
                 "visit_id" => "chrome:findme"
               })

      assert visit.guid == "chrome:findme"
      assert visit.title == "Hello"
      assert visit.url == "https://example.com/findme"
    end

    test "returns visit_not_found when guid is missing" do
      {user_id, _} = seed_user("get-miss")

      assert {:error, "visit_not_found"} =
               Tools.execute("browser_history_get", %{
                 "user_id" => user_id,
                 "visit_id" => "no-such"
               })
    end
  end
end
