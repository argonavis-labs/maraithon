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

  test "fetch_page extracts readable source text" do
    bypass = Bypass.open()

    Bypass.expect_once(bypass, "GET", "/", fn conn ->
      body = """
      <html>
        <head>
          <title>Kiln Studio</title>
          <meta name="description" content="AI adoption, made practical">
          <style>.hidden { display: none; }</style>
        </head>
        <body>
          <h1>AI adoption, made practical</h1>
          <p>Workshops and training on AI tools, agents, and automation.</p>
          <p>Scoped agent builds start at $5K.</p>
          <script>window.noisy = true;</script>
        </body>
      </html>
      """

      Plug.Conn.resp(conn, 200, body)
    end)

    assert {:ok, page} =
             WebSearch.fetch_page("http://localhost:#{bypass.port}/",
               enabled: true,
               allow_private: true
             )

    assert page["title"] == "Kiln Studio"
    assert page["description"] == "AI adoption, made practical"
    assert page["text"] =~ "Workshops and training"
    assert page["text"] =~ "Scoped agent builds start at $5K"
    refute page["text"] =~ "window.noisy"
  end
end
