defmodule Maraithon.Delegations.ReplyIntent do
  @moduledoc "Whole-message acknowledgements. Agreement, outcomes and requests remain substantive."

  def thanks_only?(message) when is_map(message) do
    text = field(message, :text_body)

    field(message, :text_only) == true and is_binary(text) and byte_size(text) <= 128 and
      Regex.match?(
        ~r/\A\s*(?:thanks(?: so much| a lot)?|thank you(?: very much| so much)?|many thanks|thx|ty)[.!]*\s*\z/iu,
        text
      )
  end

  def slack_text_only?(%{"text" => text} = message)
      when is_binary(text) and byte_size(text) <= 128 do
    Enum.all?(~w(files attachments), &(message[&1] in [nil, []])) and
      (message["blocks"] in [nil, []] or block_text(message["blocks"]) == text)
  end

  def slack_text_only?(message), do: message["text_only"] == true

  defp block_text(%{"type" => "text", "text" => text}) when is_binary(text), do: text

  defp block_text(%{"type" => type, "elements" => elements})
       when type in ~w(rich_text rich_text_section),
       do: block_text(elements)

  defp block_text(elements) when is_list(elements) do
    parts = Enum.map(elements, &block_text/1)
    if Enum.all?(parts, &is_binary/1), do: Enum.join(parts)
  end

  defp block_text(_), do: nil
  defp field(map, key), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))
end
