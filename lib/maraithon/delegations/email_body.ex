defmodule Maraithon.Delegations.EmailBody do
  @moduledoc "Plain and HTML alternatives share the reviewed body and the frozen mailbox signature."

  def plain(scope, body) do
    signature = signature(scope, "signature")
    body = String.trim_trailing(body)
    if signature == "" or signed?(body, signature), do: body, else: body <> "\n\n" <> signature
  end

  def html(scope, body) do
    footer = signature(scope, "signature_html")

    if footer != "" do
      signature = signature(scope, "signature")
      body = String.trim_trailing(body)

      body =
        if signature != "" and signed?(body, signature),
          do: String.trim_trailing(String.replace_suffix(body, signature, "")),
          else: body

      text_html(body) <> "<br><br>" <> footer
    end
  end

  def text_html(text),
    do:
      text
      |> Phoenix.HTML.html_escape()
      |> Phoenix.HTML.safe_to_string()
      |> String.replace("\n", "<br>")

  defp signature(scope, key), do: String.trim(get_in(scope, ["identity", key]) || "")

  defp signed?(body, signature),
    do: body == signature or String.ends_with?(body, "\n" <> signature)
end
