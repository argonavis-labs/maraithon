defmodule Maraithon.WebSearchTest do
  use ExUnit.Case, async: true

  alias Maraithon.WebSearch

  test "search parses DuckDuckGo HTML results" do
    bypass = Bypass.open()

    Bypass.expect_once(bypass, "GET", "/html/", fn conn ->
      assert conn.query_string =~ "q=Glossier+company"

      body = """
      <html>
        <body>
          <div class="result">
            <a class="result__a" href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fwww.glossier.com%2F&amp;rut=abc">
              Glossier | Official Site
            </a>
            <a class="result__snippet">Glossier is a beauty company with skincare and makeup products.</a>
          </div>
        </body>
      </html>
      """

      Plug.Conn.resp(conn, 200, body)
    end)

    {:ok, result} =
      WebSearch.search("Glossier company",
        enabled: true,
        base_url: "http://localhost:#{bypass.port}/html/",
        limit: 2
      )

    assert result["source"] == "duckduckgo"
    assert [%{"title" => "Glossier | Official Site"} = first] = result["results"]
    assert first["url"] == "https://www.glossier.com/"
    assert first["snippet"] =~ "beauty company"
  end

  test "search can be disabled by configuration or options" do
    assert {:error, :web_search_disabled} = WebSearch.search("Glossier", enabled: false)
  end
end
