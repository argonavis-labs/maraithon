defmodule Maraithon.Tools.LocalMessagesHelpers do
  @moduledoc """
  Shared serialization and argument helpers for the local messages tool
  surface (`messages_search`, `messages_get`, `messages_list_recent`,
  `messages_chats_recent`).
  """

  alias Maraithon.Crm
  alias Maraithon.Crm.Person
  alias Maraithon.LocalMessages.LocalMessage

  @snippet_limit 200

  @doc """
  Compact summary for list/search results.
  """
  def serialize_summary(%LocalMessage{} = msg) do
    serialize_summary(msg, nil)
  end

  def serialize_summary(%LocalMessage{} = msg, user_id) do
    %{
      message_id: msg.guid,
      guid: msg.guid,
      sender_handle: msg.sender_handle,
      text_snippet: truncate_snippet(msg.text),
      chat_key: msg.chat_key,
      chat_display_name: msg.chat_display_name,
      sent_at: iso8601(msg.sent_at),
      is_from_me: msg.is_from_me
    }
    |> add_resolved_sender(user_id, msg)
  end

  @doc """
  Full record returned by `messages_get`.
  """
  def serialize_full(%LocalMessage{} = msg) do
    serialize_full(msg, nil)
  end

  def serialize_full(%LocalMessage{} = msg, user_id) do
    %{
      message_id: msg.guid,
      guid: msg.guid,
      sender_handle: msg.sender_handle,
      text: msg.text,
      chat_key: msg.chat_key,
      chat_display_name: msg.chat_display_name,
      chat_style: msg.chat_style,
      source: msg.source,
      is_from_me: msg.is_from_me,
      has_attachments: msg.has_attachments,
      attachments: msg.attachments,
      sent_at: iso8601(msg.sent_at)
    }
    |> add_resolved_sender(user_id, msg)
  end

  @doc """
  Compact chat summary for `messages_chats_recent`.
  """
  def serialize_chat_summary(summary), do: serialize_chat_summary(summary, nil)

  def serialize_chat_summary(
        %{
          chat_key: chat_key,
          chat_display_name: chat_display_name,
          latest_message: %LocalMessage{} = latest,
          message_count_last_7d: count
        },
        user_id
      ) do
    %{
      chat_key: chat_key,
      chat_display_name: chat_display_name,
      latest_text_snippet: truncate_snippet(latest.text),
      latest_sent_at: iso8601(latest.sent_at),
      message_count_last_7d: count
    }
    |> add_resolved_latest_sender(user_id, latest)
  end

  def serialize_chat_summary(
        %{
          chat_key: chat_key,
          chat_display_name: chat_display_name,
          latest_message: nil,
          message_count_last_7d: count
        },
        _user_id
      ) do
    %{
      chat_key: chat_key,
      chat_display_name: chat_display_name,
      latest_text_snippet: nil,
      latest_sent_at: nil,
      message_count_last_7d: count
    }
  end

  @doc """
  Clamp an integer `limit` argument to `[1, max_limit]`, defaulting to
  `default` when the argument is missing or unparseable.
  """
  def normalize_limit(args, default, max_limit)
      when is_map(args) and is_integer(default) and is_integer(max_limit) do
    case Map.get(args, "limit") do
      value when is_integer(value) and value > 0 -> min(value, max_limit)
      value when is_binary(value) -> parse_limit(value, default, max_limit)
      _ -> default
    end
  end

  defp parse_limit(value, default, max_limit) do
    case Integer.parse(String.trim(value)) do
      {parsed, ""} when parsed > 0 -> min(parsed, max_limit)
      _ -> default
    end
  end

  defp add_resolved_sender(summary, user_id, %LocalMessage{sender_handle: handle})
       when is_binary(user_id) and is_binary(handle) do
    case Crm.find_person_by_contact(user_id, handle) do
      %Person{} = person ->
        summary
        |> Map.put(:sender_display_name, person.display_name)
        |> Map.put(:sender_person_id, person.id)
        |> maybe_put(:sender_relationship, person.relationship)

      nil ->
        summary
    end
  end

  defp add_resolved_sender(summary, _user_id, _msg), do: summary

  defp add_resolved_latest_sender(summary, user_id, %LocalMessage{sender_handle: handle})
       when is_binary(user_id) and is_binary(handle) do
    case Crm.find_person_by_contact(user_id, handle) do
      %Person{} = person ->
        summary
        |> Map.put(:latest_sender_display_name, person.display_name)
        |> Map.put(:latest_sender_person_id, person.id)

      nil ->
        summary
    end
  end

  defp add_resolved_latest_sender(summary, _user_id, _latest), do: summary

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, ""), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp truncate_snippet(nil), do: nil

  defp truncate_snippet(value) when is_binary(value) do
    trimmed = String.trim(value)

    if String.length(trimmed) > @snippet_limit do
      String.slice(trimmed, 0, @snippet_limit) <> "..."
    else
      trimmed
    end
  end

  defp truncate_snippet(_value), do: nil

  defp iso8601(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp iso8601(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  defp iso8601(_value), do: nil
end
