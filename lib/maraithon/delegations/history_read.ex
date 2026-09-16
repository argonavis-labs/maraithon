defmodule Maraithon.Delegations.HistoryRead do
  @moduledoc "Bounded selection of synchronized conversation evidence, never model-supplied destinations."
  import Ecto.Query
  alias Maraithon.Repo
  alias Maraithon.Delegations.Event

  @scan_limit 48
  @message_limit 6

  def window(%{"start_at" => first, "end_at" => last})
      when is_binary(first) and is_binary(last) do
    with {:ok, first, _} <- DateTime.from_iso8601(first),
         {:ok, last, _} <- DateTime.from_iso8601(last),
         micros when micros in 1..2_678_400_000_000 <- DateTime.diff(last, first, :microsecond) do
      {:ok, %{"start_at" => DateTime.to_iso8601(first), "end_at" => DateTime.to_iso8601(last)}}
    else
      _ -> {:error, :invalid_history_request}
    end
  end

  def window(_), do: {:error, :invalid_history_request}

  def select(context, window) do
    {:ok, first, _} = DateTime.from_iso8601(window["start_at"])
    {:ok, last, _} = DateTime.from_iso8601(window["end_at"])
    d = context.delegation

    recent =
      Enum.map(context.run.prompt_snapshot["sources"]["messages"] || [], & &1["message_id"])

    rows =
      Repo.all(
        from e in Event,
          where: e.user_id == ^d.user_id and e.delegation_id == ^d.id,
          where: e.kind == "inbound_message" and e.source_ref not in ^recent,
          where: e.occurred_at >= ^first and e.occurred_at < ^last,
          order_by: [desc: e.occurred_at, desc: e.seq],
          limit: ^(@scan_limit + 1)
      )

    refs =
      rows
      |> Enum.take(@scan_limit)
      |> Enum.map(&Event.hydrate/1)
      |> Enum.flat_map(fn event ->
        case reference(context, event) do
          nil -> []
          ref -> [ref]
        end
      end)
      |> Enum.uniq_by(&Map.take(&1, ~w(account_id channel thread_id message_id)))

    {Enum.take(refs, @message_limit),
     %{
       "window" => window,
       "order" => "newest_first",
       "truncated" => length(rows) > @scan_limit or length(refs) > @message_limit,
       "message_limit" => @message_limit,
       "source" => "synchronized_conversation_events"
     }}
  end

  defp reference(context, event) do
    d = context.delegation
    scope = context.grant.data["scope"]

    bindings =
      [{scope["source_account_id"], scope["source_channel_id"], scope["source_thread_id"]}] ++
        Enum.map([d.provider_thread_id | d.data["gmail_threads"] || []], fn thread ->
          {d.connected_account_id, d.slack_channel, thread}
        end)

    Enum.find_value(Enum.uniq(bindings), fn {account, channel, thread} ->
      if is_integer(account) and is_binary(thread) and event.data["thread_id"] == thread and
           event.data["message_id"] == event.source_ref and
           event.event_key == key(d.provider, scope, account, channel, event) do
        %{
          "provider" => d.provider,
          "account_id" => account,
          "channel" => channel,
          "thread_id" => thread,
          "message_id" => event.source_ref,
          "digest" => event.data["message_revision"]
        }
      end
    end)
  end

  defp key("gmail", _, account, _, event), do: "gmail:#{account}:#{event.source_ref}"

  defp key("slack", scope, _, channel, event),
    do:
      "slack:#{scope["team_id"]}:#{channel}:#{event.source_ref}:#{event.data["message_revision"]}"
end
