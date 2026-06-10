defmodule Maraithon.Todos.SourceActions do
  @moduledoc """
  Builds the per-source action descriptor for a todo.

  Product surfaces use this to offer a one-tap path back into the channel the
  work came from (Gmail, Slack, WhatsApp, Messages, Calendar) together with the
  full suggested draft, so the user can copy or send the prepared wording
  without hunting for the source thread.
  """

  alias Maraithon.Todos.{ActionDrafts, PublicMetadata, Todo}

  @max_draft_length 2_000
  @max_prefill_length 700

  @provider_labels %{
    "gmail" => "Gmail",
    "slack" => "Slack",
    "whatsapp" => "WhatsApp",
    "imessage" => "Messages",
    "telegram" => "Telegram",
    "calendar" => "Calendar"
  }

  @gmail_thread_keys ~w(thread_id gmail_thread_id source_thread_id)
  @gmail_message_keys ~w(message_id gmail_message_id source_message_id)
  @link_keys ~w(permalink html_link source_url url event_link)
  @phone_keys ~w(wa_phone phone sender_phone chat_key)
  @handle_keys ~w(chat_key sender_handle handle)
  @recipient_keys ~w(person chat_display_name sender_name requested_by contact)

  @doc """
  Returns a source action map for product surfaces, or nil when the todo has
  neither a usable deep link nor draft material.
  """
  def for_todo(%Todo{} = todo) do
    metadata = todo.metadata || %{}
    provider = provider(todo, metadata)
    draft = draft_text(todo)
    open_url = open_url(provider, todo, metadata, draft)

    if is_nil(open_url) and is_nil(draft) do
      nil
    else
      label = provider_label(provider)

      %{
        "provider" => provider,
        "provider_label" => label,
        "open_url" => open_url,
        "open_label" => open_label(label, open_url),
        "draft_text" => draft,
        "draft_kind" => draft_kind(todo),
        "recipient" => recipient(metadata),
        "recipient_handle" => recipient_handle(provider, metadata)
      }
      |> compact()
    end
  end

  def for_todo(_todo), do: nil

  defp provider(%Todo{source: source, kind: kind}, metadata) do
    cond do
      source == "gmail" or kind == "gmail_triage" -> "gmail"
      source == "slack" -> "slack"
      source == "whatsapp" -> "whatsapp"
      source == "telegram" -> "telegram"
      source in ["calendar", "google_calendar"] -> "calendar"
      imessage_like?(source, metadata) -> "imessage"
      true -> nil
    end
  end

  defp imessage_like?(source, metadata) do
    source in ["imessage", "local_patterns", "desktop", "messages"] and
      is_binary(message_handle(metadata))
  end

  defp open_url(provider, todo, metadata, draft) do
    explicit_link(metadata) || built_url(provider, todo, metadata, draft)
  end

  defp explicit_link(metadata) do
    @link_keys
    |> Enum.find_value(&read_string(metadata, &1))
    |> safe_web_url()
  end

  defp built_url("gmail", todo, metadata, _draft) do
    id =
      Enum.find_value(@gmail_thread_keys, &read_string(metadata, &1)) ||
        Enum.find_value(@gmail_message_keys, &read_string(metadata, &1)) ||
        gmail_source_item_id(todo)

    if id, do: "https://mail.google.com/mail/u/0/#all/#{URI.encode(id)}"
  end

  defp built_url("slack", _todo, metadata, _draft) do
    team = read_string(metadata, "team_id")
    channel = read_string(metadata, "channel_id")

    if team && channel do
      "slack://channel?team=#{URI.encode(team)}&id=#{URI.encode(channel)}"
    end
  end

  defp built_url("whatsapp", _todo, metadata, draft) do
    case phone_digits(metadata) do
      nil ->
        nil

      digits when is_binary(draft) and draft != "" ->
        "https://wa.me/#{digits}?text=#{URI.encode_www_form(truncate(draft, @max_prefill_length))}"

      digits ->
        "https://wa.me/#{digits}"
    end
  end

  defp built_url("imessage", _todo, metadata, _draft) do
    case message_handle(metadata) do
      nil -> nil
      handle -> "sms:#{URI.encode(handle)}"
    end
  end

  defp built_url(_provider, _todo, _metadata, _draft), do: nil

  defp gmail_source_item_id(%Todo{source: "gmail", source_item_id: id})
       when is_binary(id) and id != "" do
    # Gmail source_item_id values are raw API ids; anything with separators is
    # a composite tracking key, not an id Gmail web can open.
    if String.match?(id, ~r/^[A-Za-z0-9_-]+$/), do: id
  end

  defp gmail_source_item_id(_todo), do: nil

  defp safe_web_url(url) when is_binary(url) do
    case URI.parse(String.trim(url)) do
      %URI{scheme: scheme, host: host}
      when scheme in ["https", "http"] and is_binary(host) and host != "" ->
        String.trim(url)

      _other ->
        nil
    end
  end

  defp safe_web_url(_url), do: nil

  defp phone_digits(metadata) do
    @phone_keys
    |> Enum.find_value(fn key ->
      with value when is_binary(value) <- read_string(metadata, key),
           digits = String.replace(value, ~r/[^\d]/, ""),
           true <- String.length(digits) >= 7 do
        digits
      else
        _ -> nil
      end
    end)
  end

  defp message_handle(metadata) do
    Enum.find_value(@handle_keys, fn key ->
      value = read_string(metadata, key)

      if is_binary(value) and (phone_like?(value) or email_like?(value)) do
        String.replace(value, ~r/\s+/, "")
      end
    end)
  end

  defp phone_like?(value), do: String.match?(value, ~r/^\+?[\d\s().-]{7,}$/)
  defp email_like?(value), do: String.match?(value, ~r/^[^@\s]+@[^@\s]+\.[^@\s]+$/)

  defp draft_text(%Todo{action_draft: draft}) do
    with text when is_binary(text) <- ActionDrafts.preview(draft || %{}),
         text = text |> String.replace(~r/\r\n?/, "\n") |> String.trim(),
         true <- text != "",
         true <- PublicMetadata.public_text?(single_line(text)) do
      truncate(text, @max_draft_length)
    else
      _ -> nil
    end
  end

  defp draft_kind(%Todo{action_draft: draft}) when is_map(draft) do
    case read_string(draft, "kind") do
      kind when kind in ["reply", "draft", "next_step"] -> kind
      _other -> nil
    end
  end

  defp draft_kind(_todo), do: nil

  defp recipient(metadata) do
    Enum.find_value(@recipient_keys, fn key ->
      value = read_string(metadata, key)
      if is_binary(value) and PublicMetadata.public_text?(value), do: value
    end)
  end

  defp recipient_handle("imessage", metadata), do: message_handle(metadata)

  defp recipient_handle("whatsapp", metadata) do
    case phone_digits(metadata) do
      nil -> nil
      digits -> "+" <> digits
    end
  end

  defp recipient_handle(_provider, _metadata), do: nil

  defp provider_label(provider), do: Map.get(@provider_labels, provider)

  defp open_label(nil, url) when is_binary(url), do: "Open source"
  defp open_label(_label, nil), do: nil
  defp open_label(label, _url), do: "Open in #{label}"

  defp single_line(text), do: String.replace(text, ~r/\s+/, " ")

  defp truncate(text, max) do
    if String.length(text) <= max do
      text
    else
      String.slice(text, 0, max - 1) <> "…"
    end
  end

  defp compact(map) do
    map
    |> Enum.reject(fn {_key, value} -> is_nil(value) or value == "" end)
    |> Map.new()
  end

  defp read_string(map, key) when is_map(map) do
    case Map.get(map, key) || Map.get(map, safe_atom(key)) do
      value when is_binary(value) ->
        value = String.trim(value)
        if value == "", do: nil, else: value

      _other ->
        nil
    end
  end

  defp read_string(_map, _key), do: nil

  defp safe_atom(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> nil
  end
end
