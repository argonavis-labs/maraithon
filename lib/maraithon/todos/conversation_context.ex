defmodule Maraithon.Todos.ConversationContext do
  @moduledoc "User-scoped, synced conversation history tied to an exact provider thread."
  import Ecto.Query
  alias Maraithon.{Repo, LocalMessages}
  alias Maraithon.Crm.Observation
  alias Maraithon.LocalMessages.LocalMessage

  def messages(user_id, provider, payload, limit \\ 24)

  def messages(user_id, "imessage", payload, limit) do
    case message_chat(user_id, payload) do
      nil ->
        []

      chat ->
        LocalMessages.recent_for_chat(user_id, chat, limit: limit)
        |> Enum.uniq_by(& &1.guid)
        |> Enum.reverse()
        |> Enum.map(fn m ->
          %{
            id: "imessage:" <> (m.guid || m.id),
            provider: "imessage",
            speaker:
              if(m.is_from_me,
                do: "You",
                else:
                  payload["recipient_name"] || m.chat_display_name || m.sender_handle || "Contact"
              ),
            text: String.slice(m.text || "", 0, 8_000),
            at: iso(m.sent_at),
            from_user: m.is_from_me
          }
        end)
        |> Enum.reject(&(&1.text == ""))
    end
  end

  def messages(user_id, provider, payload, limit) when provider in ~w(gmail slack) do
    query =
      from o in Observation,
        where: o.user_id == ^user_id and o.source == ^provider,
        order_by: [desc: o.occurred_at],
        limit: ^limit

    case thread_query(query, provider, payload) do
      nil ->
        []

      scoped ->
        scoped
        |> Repo.all()
        |> Enum.reverse()
        |> Enum.map(fn o ->
          %{
            id: o.source <> ":" <> o.source_item_id,
            provider: o.source,
            speaker: if(o.direction == "outbound", do: "You", else: speaker(o)),
            text: String.slice(o.metadata["text"] || o.excerpt || "", 0, 8_000),
            at: iso(o.occurred_at),
            from_user: o.direction == "outbound"
          }
        end)
        |> Enum.reject(&(&1.text == ""))
    end
  end

  def messages(_, _, _, _), do: []

  def message_chat(user_id, payload) do
    recipient = normalize(payload["recipient"] || payload["to"] || "")
    guid = payload["source_message_id"]

    source = if is_binary(guid), do: LocalMessages.get_by_guid(user_id, guid)

    cond do
      source && source.chat_style != "group" && normalize(source.sender_handle || "") == recipient ->
        source.chat_key

      recipient == "" ->
        nil

      true ->
        Repo.one(
          from m in LocalMessage,
            where:
              m.user_id == ^user_id and m.source == "imessage" and
                (is_nil(m.chat_style) or m.chat_style != "group") and not is_nil(m.chat_key) and
                fragment(
                  "lower(regexp_replace(?, '[[:space:]()\\-]', '', 'g')) = ?",
                  m.sender_handle,
                  ^recipient
                ),
            order_by: [desc: m.sent_at],
            limit: 1,
            select: m.chat_key
        )
    end
  end

  defp thread_query(query, "gmail", payload) do
    thread = payload["thread_id"] || payload["gmail_thread_id"]
    provider = payload["google_provider"] || payload["provider"]
    account = payload["google_account_email"] || payload["account_email"] || payload["account"]

    provider =
      if is_binary(provider) and String.starts_with?(provider, "google:"),
        do: provider,
        else:
          if(is_binary(account),
            do:
              if(String.starts_with?(account, "google:"), do: account, else: "google:" <> account)
          )

    if is_binary(thread) and is_binary(provider) do
      from o in query,
        where:
          fragment(
            "?->>'thread_id' = ? AND ?->>'google_provider' = ?",
            o.metadata,
            ^thread,
            o.metadata,
            ^provider
          )
    end
  end

  defp thread_query(query, "slack", payload) do
    team = payload["team_id"]
    channel = payload["channel"] || payload["channel_id"]
    thread = payload["thread_ts"]

    if is_binary(team) and is_binary(channel) do
      scoped =
        from o in query,
          where:
            fragment(
              "?->>'team_id' = ? AND ?->>'channel' = ?",
              o.metadata,
              ^team,
              o.metadata,
              ^channel
            )

      cond do
        is_binary(thread) ->
          from o in scoped,
            where:
              fragment("COALESCE(?->>'thread_ts', ?->>'ts') = ?", o.metadata, o.metadata, ^thread)

        String.starts_with?(channel, "D") ->
          scoped

        true ->
          nil
      end
    end
  end

  defp speaker(o) do
    from = Enum.find(o.participants || [], &(&1["role"] == "from")) || %{}
    identity = from["identifier"] || %{}
    from["display_name"] || identity["email"] || identity["slack_id"] || "Contact"
  end

  defp normalize(value), do: value |> String.downcase() |> String.replace(~r/[\s()\-]/, "")
  defp iso(%DateTime{} = date), do: DateTime.to_iso8601(date)
  defp iso(_), do: nil
end
