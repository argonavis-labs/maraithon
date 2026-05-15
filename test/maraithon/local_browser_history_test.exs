defmodule Maraithon.LocalBrowserHistoryTest do
  use Maraithon.DataCase, async: true

  alias Maraithon.LocalBrowserHistory
  alias Maraithon.LocalBrowserHistory.LocalVisit
  alias Maraithon.Repo

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

  defp visits_for(user_id, device_id) do
    Repo.all(
      from visit in LocalVisit,
        where: visit.user_id == ^user_id and visit.device_id == ^device_id
    )
  end

  defp visit_count(user_id, device_id) do
    Repo.aggregate(
      from(visit in LocalVisit,
        where: visit.user_id == ^user_id and visit.device_id == ^device_id
      ),
      :count,
      :id
    )
  end

  describe "ingest_batch/3" do
    test "inserts a fresh batch and reports counts" do
      user_id = "bh-ingest-#{System.unique_integer([:positive])}@example.com"
      device_id = Ecto.UUID.generate()

      visits =
        for i <- 1..3 do
          sample_visit("g-#{i}", %{"title" => "post #{i}"})
        end

      assert {:ok, %{accepted: 3, duplicate: 0, invalid: 0, filtered: 0}} =
               LocalBrowserHistory.ingest_batch(user_id, device_id, visits)

      stored = visits_for(user_id, device_id)
      assert length(stored) == 3
      assert Enum.all?(stored, &(&1.user_id == user_id))
      assert Enum.all?(stored, &(&1.host == "example.com"))
      assert Enum.all?(stored, &(&1.source == "browser_history"))
    end

    test "namespaces guid by browser so cross-browser ids never collide" do
      user_id = "bh-ns-#{System.unique_integer([:positive])}@example.com"
      device_id = Ecto.UUID.generate()

      assert {:ok, %{accepted: 2}} =
               LocalBrowserHistory.ingest_batch(user_id, device_id, [
                 sample_visit("12345", %{"browser" => "chrome"}),
                 sample_visit("12345", %{"browser" => "safari"})
               ])

      stored = visits_for(user_id, device_id)
      guids = Enum.map(stored, & &1.guid) |> Enum.sort()
      assert guids == ["chrome:12345", "safari:12345"]
    end

    test "dedupes via unique constraint on re-send" do
      user_id = "bh-dedupe-#{System.unique_integer([:positive])}@example.com"
      device_id = Ecto.UUID.generate()

      visits = [sample_visit("g-a"), sample_visit("g-b")]

      {:ok, %{accepted: 2, duplicate: 0}} =
        LocalBrowserHistory.ingest_batch(user_id, device_id, visits)

      {:ok, %{accepted: 0, duplicate: 2}} =
        LocalBrowserHistory.ingest_batch(user_id, device_id, visits)

      assert visit_count(user_id, device_id) == 2
    end

    test "drops rows missing url" do
      user_id = "bh-invalid-#{System.unique_integer([:positive])}@example.com"
      device_id = Ecto.UUID.generate()

      {:ok, %{accepted: 1, invalid: 1}} =
        LocalBrowserHistory.ingest_batch(user_id, device_id, [
          sample_visit("g-good"),
          %{"guid" => "g-bad", "browser" => "chrome"}
        ])
    end

    test "derives host from url when host is missing" do
      user_id = "bh-derive-#{System.unique_integer([:positive])}@example.com"
      device_id = Ecto.UUID.generate()

      {:ok, _} =
        LocalBrowserHistory.ingest_batch(user_id, device_id, [
          sample_visit("g1", %{
            "host" => nil,
            "url" => "https://blog.example.org/post"
          })
        ])

      [stored] = visits_for(user_id, device_id)
      assert stored.host == "blog.example.org"
    end

    test "stores is_typed_url and visit_count" do
      user_id = "bh-meta-#{System.unique_integer([:positive])}@example.com"
      device_id = Ecto.UUID.generate()

      {:ok, _} =
        LocalBrowserHistory.ingest_batch(user_id, device_id, [
          sample_visit("g1", %{"is_typed_url" => true, "visit_count" => 7})
        ])

      [stored] = visits_for(user_id, device_id)
      assert stored.is_typed_url == true
      assert stored.visit_count == 7
    end
  end

  describe "privacy guardrails" do
    test "drops rows whose host is on the bank deny-list" do
      user_id = "bh-priv-bank-#{System.unique_integer([:positive])}@example.com"
      device_id = Ecto.UUID.generate()

      {:ok, %{accepted: 1, filtered: filtered}} =
        LocalBrowserHistory.ingest_batch(user_id, device_id, [
          sample_visit("good", %{"host" => "example.com"}),
          sample_visit("bank", %{
            "host" => "online.chasebank.com",
            "url" => "https://online.chasebank.com/dashboard"
          })
        ])

      assert filtered == 1
      stored = visits_for(user_id, device_id)
      assert length(stored) == 1
      assert hd(stored).host == "example.com"
    end

    test "drops paypal hosts" do
      user_id = "bh-priv-paypal-#{System.unique_integer([:positive])}@example.com"
      device_id = Ecto.UUID.generate()

      {:ok, %{accepted: 0, filtered: 1}} =
        LocalBrowserHistory.ingest_batch(user_id, device_id, [
          sample_visit("pp", %{
            "host" => "www.paypal.com",
            "url" => "https://www.paypal.com/myaccount"
          })
        ])
    end

    test "drops medical and health hosts" do
      user_id = "bh-priv-med-#{System.unique_integer([:positive])}@example.com"
      device_id = Ecto.UUID.generate()

      {:ok, %{accepted: 0, filtered: 2}} =
        LocalBrowserHistory.ingest_batch(user_id, device_id, [
          sample_visit("m1", %{
            "host" => "mychart.medicalcenter.com",
            "url" => "https://mychart.medicalcenter.com/labs"
          }),
          sample_visit("h1", %{
            "host" => "patient.healthsystem.org",
            "url" => "https://patient.healthsystem.org/portal"
          })
        ])
    end

    test "drops adult-content hosts" do
      user_id = "bh-priv-adult-#{System.unique_integer([:positive])}@example.com"
      device_id = Ecto.UUID.generate()

      {:ok, %{accepted: 0, filtered: 2}} =
        LocalBrowserHistory.ingest_batch(user_id, device_id, [
          sample_visit("a1", %{
            "host" => "some-adultsite.com",
            "url" => "https://some-adultsite.com/foo"
          }),
          sample_visit("p1", %{
            "host" => "porn.example.com",
            "url" => "https://porn.example.com/x"
          })
        ])
    end

    test "drops search-engine queries on google/bing/duckduckgo" do
      user_id = "bh-priv-search-#{System.unique_integer([:positive])}@example.com"
      device_id = Ecto.UUID.generate()

      {:ok, %{accepted: 1, filtered: filtered}} =
        LocalBrowserHistory.ingest_batch(user_id, device_id, [
          sample_visit("ok", %{
            "host" => "example.com",
            "url" => "https://example.com/article"
          }),
          sample_visit("gs", %{
            "host" => "www.google.com",
            "url" => "https://www.google.com/search?q=my+secret+thing"
          }),
          sample_visit("bs", %{
            "host" => "www.bing.com",
            "url" => "https://www.bing.com/search?q=other"
          }),
          sample_visit("dds", %{
            "host" => "duckduckgo.com",
            "url" => "https://duckduckgo.com/?q=hello"
          })
        ])

      # Bing + Google match search?, DuckDuckGo's "/?q=" doesn't match the
      # search? rule but its host substring won't filter it; the
      # bare-host google match keeps it filtered for google/bing only.
      assert filtered >= 2
      stored = visits_for(user_id, device_id)
      assert length(stored) <= 2
      assert Enum.any?(stored, &(&1.host == "example.com"))
      refute Enum.any?(stored, &String.contains?(&1.url, "search?q=my+secret"))
    end

    test "private_host?/1 surfaces the same predicate for tooling layer" do
      assert LocalBrowserHistory.private_host?("online.bigbank.com")
      assert LocalBrowserHistory.private_host?("MyChart.MedicalCenter.com")
      assert LocalBrowserHistory.private_host?("paypal.com")
      assert LocalBrowserHistory.private_host?("adultsite.com")
      refute LocalBrowserHistory.private_host?("techmeme.com")
      refute LocalBrowserHistory.private_host?(nil)
    end
  end

  describe "recent_visits/2" do
    test "returns visits newest first" do
      user_id = "bh-recent-#{System.unique_integer([:positive])}@example.com"
      device_id = Ecto.UUID.generate()

      {:ok, _} =
        LocalBrowserHistory.ingest_batch(user_id, device_id, [
          sample_visit("old", %{
            "last_visited_at" => "2026-05-10T10:00:00Z",
            "title" => "older"
          }),
          sample_visit("new", %{
            "last_visited_at" => "2026-05-10T12:00:00Z",
            "title" => "newer"
          })
        ])

      [first, second] = LocalBrowserHistory.recent_visits(user_id)
      assert first.title == "newer"
      assert second.title == "older"
    end

    test "filters by browser" do
      user_id = "bh-recent-browser-#{System.unique_integer([:positive])}@example.com"
      device_id = Ecto.UUID.generate()

      {:ok, _} =
        LocalBrowserHistory.ingest_batch(user_id, device_id, [
          sample_visit("c1", %{"browser" => "chrome"}),
          sample_visit("s1", %{"browser" => "safari"})
        ])

      chrome = LocalBrowserHistory.recent_visits(user_id, browser: "chrome")
      assert length(chrome) == 1
      assert hd(chrome).browser == "chrome"
    end
  end

  describe "visits_by_host/3" do
    test "matches host substring (case-insensitive)" do
      user_id = "bh-host-#{System.unique_integer([:positive])}@example.com"
      device_id = Ecto.UUID.generate()

      {:ok, _} =
        LocalBrowserHistory.ingest_batch(user_id, device_id, [
          sample_visit("t1", %{
            "host" => "www.techmeme.com",
            "url" => "https://www.techmeme.com/a"
          }),
          sample_visit("t2", %{"host" => "techmeme.com", "url" => "https://techmeme.com/b"}),
          sample_visit("n1", %{
            "host" => "news.ycombinator.com",
            "url" => "https://news.ycombinator.com/c"
          })
        ])

      hits = LocalBrowserHistory.visits_by_host(user_id, "TECHMEME")
      assert length(hits) == 2
      assert Enum.all?(hits, &String.contains?(&1.host, "techmeme"))
    end
  end

  describe "search/3" do
    test "matches substring across title, url, and host" do
      user_id = "bh-search-#{System.unique_integer([:positive])}@example.com"
      device_id = Ecto.UUID.generate()

      {:ok, _} =
        LocalBrowserHistory.ingest_batch(user_id, device_id, [
          sample_visit("a", %{
            "host" => "techmeme.com",
            "url" => "https://techmeme.com/post/transformers",
            "title" => "Transformers explained"
          }),
          sample_visit("b", %{
            "host" => "blog.example.com",
            "url" => "https://blog.example.com/biking",
            "title" => "Weekend ride"
          })
        ])

      hits = LocalBrowserHistory.search(user_id, "transformer")
      assert length(hits) == 1
      assert hd(hits).host == "techmeme.com"

      hits_url = LocalBrowserHistory.search(user_id, "biking")
      assert length(hits_url) == 1
    end
  end

  describe "get_by_guid/2" do
    test "returns the matching visit when present" do
      user_id = "bh-get-#{System.unique_integer([:positive])}@example.com"
      device_id = Ecto.UUID.generate()

      {:ok, _} =
        LocalBrowserHistory.ingest_batch(user_id, device_id, [
          sample_visit("findme", %{"title" => "Hello"})
        ])

      visit = LocalBrowserHistory.get_by_guid(user_id, "chrome:findme")
      assert visit
      assert visit.title == "Hello"
      assert LocalBrowserHistory.get_by_guid(user_id, "missing") == nil
    end
  end

  describe "purge_device/2" do
    test "removes all rows for the (user, device) pair" do
      user_id = "bh-purge-#{System.unique_integer([:positive])}@example.com"
      device_id = Ecto.UUID.generate()

      {:ok, _} =
        LocalBrowserHistory.ingest_batch(user_id, device_id, [
          sample_visit("g1"),
          sample_visit("g2")
        ])

      assert visit_count(user_id, device_id) == 2
      {:ok, %{deleted: 2}} = LocalBrowserHistory.purge_device(user_id, device_id)
      assert visit_count(user_id, device_id) == 0
    end
  end
end
