defmodule MaraithonWeb.AppcastControllerTest do
  use MaraithonWeb.ConnCase, async: true

  alias Maraithon.Companion.Releases

  describe "GET /companion/appcast.xml" do
    test "returns an empty but valid feed when no releases are published", %{conn: conn} do
      conn = get(conn, "/companion/appcast.xml")

      assert response(conn, 200)
      body = response(conn, 200)
      assert get_resp_header(conn, "content-type") |> hd() =~ "application/xml"
      assert body =~ ~s(<?xml version="1.0" encoding="utf-8"?>)
      assert body =~ "<rss"
      assert body =~ ~s(xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle")
      assert body =~ "<channel>"
      assert body =~ "<title>Maraithon</title>"
      refute body =~ "<item>"
    end

    test "renders one item per release with the expected Sparkle fields", %{conn: conn} do
      {:ok, _} =
        Releases.publish(%{
          version: "0.1.1",
          build_number: "2",
          url: "https://maraithon.com/releases/Maraithon-0.1.1.dmg",
          signature: "EdDSASignaturePlaceholderAAAAAAAAAAAAAAAAAAAAAAAAAA==",
          min_system_version: "14.0",
          notes_markdown: "Bug fixes & improvements.",
          released_at: ~U[2026-05-10 12:00:00.000000Z]
        })

      conn = get(conn, "/companion/appcast.xml")
      body = response(conn, 200)

      assert body =~ "<item>"
      assert body =~ "<title>Version 0.1.1</title>"
      assert body =~ "<sparkle:version>2</sparkle:version>"
      assert body =~ "<sparkle:shortVersionString>0.1.1</sparkle:shortVersionString>"
      assert body =~ ~s(url="https://maraithon.com/releases/Maraithon-0.1.1.dmg")
      assert body =~ ~s(sparkle:edSignature="EdDSASignaturePlaceholder)
      assert body =~ ~s(sparkle:minimumSystemVersion="14.0")
      # Notes are wrapped in CDATA, so XML metacharacters pass through
      # unescaped — Sparkle parses them as the raw text.
      assert body =~ "<![CDATA[Bug fixes & improvements.]]>"
      assert body =~ "Sun, 10 May 2026 12:00:00 GMT"
    end

    test "escapes XML metacharacters in release notes", %{conn: conn} do
      {:ok, _} =
        Releases.publish(%{
          version: "0.2.0",
          build_number: "3",
          url: "https://maraithon.com/releases/Maraithon-0.2.0.dmg",
          signature: "AnotherSignature==",
          notes_markdown: "Adds support for <tags> & \"quotes\".",
          released_at: ~U[2026-05-10 12:00:00.000000Z]
        })

      conn = get(conn, "/companion/appcast.xml")
      body = response(conn, 200)

      # CDATA wraps the body but the content is still safe enough that
      # parsers won't break.
      assert body =~ "<![CDATA[Adds support for <tags> & \"quotes\".]]>"
    end

    test "orders items newest-first", %{conn: conn} do
      {:ok, _} =
        Releases.publish(%{
          version: "1.0.0",
          build_number: "100",
          url: "https://maraithon.com/releases/Maraithon-1.0.0.dmg",
          signature: "sig-1.0.0",
          released_at: ~U[2026-05-10 12:00:00.000000Z]
        })

      {:ok, _} =
        Releases.publish(%{
          version: "0.9.0",
          build_number: "90",
          url: "https://maraithon.com/releases/Maraithon-0.9.0.dmg",
          signature: "sig-0.9.0",
          released_at: ~U[2026-04-01 12:00:00.000000Z]
        })

      conn = get(conn, "/companion/appcast.xml")
      body = response(conn, 200)

      newer_pos = :binary.match(body, "Version 1.0.0") |> elem(0)
      older_pos = :binary.match(body, "Version 0.9.0") |> elem(0)

      assert newer_pos < older_pos
    end
  end
end
