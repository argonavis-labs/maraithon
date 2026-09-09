defmodule Maraithon.AssistantChat.MessageDraft do
  @moduledoc """
  Builds a native Messages draft from a user-scoped, known contact or message.
  Preparation is read-only; opening a composer is never recorded as delivery.
  """

  alias Maraithon.{Crm, LocalMessages}

  def prepare(user_id, args) do
    recipient = text(args["recipient"])
    body = text(args["body"])

    with true <- valid_handle?(recipient),
         true <- is_binary(body) and byte_size(body) <= 16_384,
         {:ok, name} <- known_recipient(user_id, recipient, args["source_message_id"]) do
      {:ok,
       %{
         draft_card: %{
           provider: "imessage",
           title: "Message to #{name}",
           recipient: recipient,
           recipient_name: name,
           body: body,
           status: "Draft",
           open_label: "Open in Messages"
         },
         message: "Draft ready for review in Messages. Nothing has been sent."
       }}
    else
      _ ->
        {:error,
         "Resolve an actual phone number or email from this user's People or Messages first; then provide a nonempty draft body."}
    end
  end

  def from_history(history) when is_list(history) do
    history
    |> Enum.reverse()
    |> Enum.find_value(fn entry ->
      if value(entry, "tool") in ["draft_imessage", "draft_message"] do
        value(value(entry, "result"), "draft_card")
      end
    end)
  end

  def from_history(_), do: nil

  defp known_recipient(user_id, recipient, guid) do
    case Crm.find_person_by_contact(user_id, recipient) do
      %{display_name: name} -> {:ok, name}
      _ -> known_message_recipient(user_id, recipient, guid)
    end
  end

  defp known_message_recipient(user_id, recipient, guid) when is_binary(guid) do
    case LocalMessages.get_by_guid(user_id, guid) do
      %{sender_handle: handle, is_from_me: false} when is_binary(handle) ->
        if normalize(handle) == normalize(recipient), do: {:ok, recipient}, else: :error

      _ ->
        :error
    end
  end

  defp known_message_recipient(_, _, _), do: :error

  defp valid_handle?(handle) when is_binary(handle) do
    Regex.match?(~r/^\+?[0-9]{7,15}$/, handle) or
      Regex.match?(~r/^[^\s<>@]+@[^\s<>@]+\.[^\s<>@]+$/, handle)
  end

  defp valid_handle?(_), do: false
  defp normalize(handle), do: handle |> String.downcase() |> String.replace(~r/[\s()\-]/, "")

  defp text(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      text -> text
    end
  end

  defp text(_), do: nil

  defp value(map, key) when is_map(map),
    do: Map.get(map, key) || Map.get(map, String.to_existing_atom(key))

  defp value(_, _), do: nil
end
