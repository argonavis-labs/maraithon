defmodule MaraithonWeb.AppcastController do
  @moduledoc """
  Sparkle appcast feed for the Maraithon Mac companion app.

  Sparkle (https://sparkle-project.org) periodically fetches an
  RSS-shaped XML feed and compares the listed `sparkle:version`
  against the installed app's `CFBundleVersion`. A higher entry
  triggers the in-app update flow, which downloads the `url`,
  verifies the EdDSA `sparkle:edSignature` against `SUPublicEDKey`
  baked into the app, then installs.

  This endpoint is public (no auth) by design — every installed app
  must be able to read it without device credentials.
  """

  use MaraithonWeb, :controller

  alias Maraithon.Companion.Releases

  @rfc1123_days ~w(Mon Tue Wed Thu Fri Sat Sun)
  @rfc1123_months ~w(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec)

  def show(conn, _params) do
    releases = Releases.list(limit: 50)
    xml = render_xml(releases)

    conn
    |> put_resp_content_type("application/xml")
    |> put_resp_header("cache-control", "public, max-age=300")
    |> send_resp(200, xml)
  end

  @doc false
  def render_xml(releases) do
    items =
      releases
      |> Enum.map(&render_item/1)
      |> Enum.join("\n")

    """
    <?xml version="1.0" encoding="utf-8"?>
    <rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" xmlns:dc="http://purl.org/dc/elements/1.1/">
      <channel>
        <title>Maraithon</title>
        <link>https://maraithon.com/companion/appcast.xml</link>
        <description>Maraithon companion app updates.</description>
        <language>en</language>
    #{items}
      </channel>
    </rss>
    """
  end

  defp render_item(release) do
    pub_date = format_rfc1123(release.released_at)
    description = escape_cdata(release.notes_markdown || "")

    enclosure_attrs =
      [
        {"url", release.url},
        {"sparkle:version", release.build_number},
        {"sparkle:shortVersionString", release.version},
        {"sparkle:edSignature", release.signature},
        {"sparkle:minimumSystemVersion", release.min_system_version},
        {"type", "application/octet-stream"}
      ]
      |> Enum.filter(fn {_k, v} -> v not in [nil, ""] end)
      |> Enum.map_join("\n        ", fn {k, v} -> ~s(#{k}="#{escape_xml(v)}") end)

    """
        <item>
          <title>Version #{escape_xml(release.version)}</title>
          <pubDate>#{pub_date}</pubDate>
          <sparkle:version>#{escape_xml(release.build_number)}</sparkle:version>
          <sparkle:shortVersionString>#{escape_xml(release.version)}</sparkle:shortVersionString>
          <description><![CDATA[#{description}]]></description>
          <enclosure
            #{enclosure_attrs} />
        </item>
    """
    |> String.trim_trailing()
  end

  # RFC 1123 / RFC 822 date format required by RSS `pubDate`.
  defp format_rfc1123(%DateTime{} = dt) do
    utc = DateTime.shift_zone!(dt, "Etc/UTC")
    day_name = Enum.at(@rfc1123_days, Date.day_of_week(DateTime.to_date(utc)) - 1)
    month_name = Enum.at(@rfc1123_months, utc.month - 1)

    :io_lib.format("~s, ~2..0B ~s ~4..0B ~2..0B:~2..0B:~2..0B GMT", [
      day_name,
      utc.day,
      month_name,
      utc.year,
      utc.hour,
      utc.minute,
      utc.second
    ])
    |> IO.iodata_to_binary()
  end

  # Inside a CDATA section, only the closing sequence `]]>` is special.
  # Defensively split it across two CDATA sections so a stray `]]>`
  # inside release notes can't terminate the description early.
  defp escape_cdata(value) when is_binary(value) do
    String.replace(value, "]]>", "]]]]><![CDATA[>")
  end

  defp escape_cdata(value), do: escape_cdata(to_string(value))

  defp escape_xml(value) when is_binary(value) do
    value
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
    |> String.replace("'", "&apos;")
  end

  defp escape_xml(value), do: escape_xml(to_string(value))
end
