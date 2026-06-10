defmodule Maraithon.Briefs.Markdown do
  @moduledoc """
  Renders the limited markdown the briefing skills emit (## headings,
  bullet lists, **bold**, `code`) as safe HTML for email and web.

  Input is HTML-escaped before any markup is applied, so source content
  can never inject tags.
  """

  @doc """
  Converts briefing markdown to an HTML string.
  """
  def to_html(nil), do: ""

  def to_html(body) when is_binary(body) do
    body
    |> String.replace("\r\n", "\n")
    |> String.split("\n")
    |> Enum.map(&String.trim_trailing/1)
    |> blocks([])
    |> Enum.map_join("\n", &render_block/1)
  end

  @doc """
  Strips markdown markers for plain-text surfaces (email text body).
  """
  def to_text(nil), do: ""

  def to_text(body) when is_binary(body) do
    body
    |> String.replace(~r/^##+\s*/m, "")
    |> String.replace("**", "")
    |> String.replace("`", "")
  end

  defp blocks([], acc), do: Enum.reverse(acc)

  defp blocks([line | rest], acc) do
    cond do
      String.trim(line) == "" ->
        blocks(rest, acc)

      String.starts_with?(line, "##") ->
        heading = line |> String.replace(~r/^#+\s*/, "") |> String.trim()
        blocks(rest, [{:heading, heading} | acc])

      bullet?(line) ->
        {items, remaining} = Enum.split_while([line | rest], &bullet?/1)
        blocks(remaining, [{:list, Enum.map(items, &strip_bullet/1)} | acc])

      true ->
        {lines, remaining} =
          Enum.split_while([line | rest], fn candidate ->
            String.trim(candidate) != "" and not String.starts_with?(candidate, "##") and
              not bullet?(candidate)
          end)

        blocks(remaining, [{:paragraph, Enum.join(lines, " ")} | acc])
    end
  end

  defp bullet?(line), do: Regex.match?(~r/^\s*[-*]\s+/, line)

  defp strip_bullet(line), do: Regex.replace(~r/^\s*[-*]\s+/, line, "")

  defp render_block({:heading, text}) do
    "<h2 style=\"margin:20px 0 8px;font-size:15px;font-weight:600;color:#18181b;\">#{inline(text)}</h2>"
  end

  defp render_block({:list, items}) do
    rendered =
      Enum.map_join(items, "", fn item ->
        "<li style=\"margin:0 0 6px;\">#{inline(item)}</li>"
      end)

    "<ul style=\"margin:0 0 12px;padding-left:20px;\">#{rendered}</ul>"
  end

  defp render_block({:paragraph, text}) do
    "<p style=\"margin:0 0 12px;\">#{inline(text)}</p>"
  end

  defp inline(text) do
    text
    |> escape()
    |> String.replace(~r/\*\*([^*]+)\*\*/, "<strong>\\1</strong>")
    |> String.replace(~r/`([^`]+)`/, "<code>\\1</code>")
  end

  defp escape(value) do
    value
    |> Phoenix.HTML.html_escape()
    |> Phoenix.HTML.safe_to_string()
  end
end
