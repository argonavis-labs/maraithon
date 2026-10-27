defmodule Maraithon.Delegations.History do
  @moduledoc "Bounded, user-scoped conversation history. Decisions never stand in for delivery receipts."
  import Ecto.Query
  alias Maraithon.{Delegations, Repo}
  alias Maraithon.Delegations.{Event, EvidenceLinks, Policy, Turn}
  alias Maraithon.TelegramAssistant.{Continuation, Run}

  @page_size 30
  @kinds ~w(user_action inbound_message decision send_receipt send_unknown send_deferred
    reconciliation_exhausted failure capacity_hold source_gap state_changed)

  def fetch(user_id, id, before \\ nil) do
    with %{} = d <- Delegations.get(user_id, id),
         {:ok, cursor} <- cursor(before) do
      query =
        from e in Event,
          where:
            e.user_id == ^user_id and e.delegation_id == ^d.id and
              e.kind in ^@kinds,
          order_by: [desc: e.seq],
          limit: @page_size + 1

      query = if cursor, do: where(query, [e], e.seq < ^cursor), else: query
      rows = Repo.all(query)
      events = rows |> Enum.take(@page_size) |> Enum.map(&Event.hydrate/1)
      reviews = review_explanations(user_id, d.id, events)
      accounts = EvidenceLinks.accounts(user_id)
      scope = Delegations.current_grant(d).data["scope"]
      team = scope["team_id"]
      facts = get_in(d.data, ["ledger", "facts"]) || %{}

      {:ok,
       %{
         entries:
           Enum.map(events, fn event ->
             {title, detail} = describe(event)

             %{
               id: event.id,
               occurred_at: DateTime.to_iso8601(event.occurred_at),
               title: title,
               detail: Map.get(reviews, event.id) || detail,
               links: event_links(event, d, accounts, team)
             }
           end),
         next_before: if(length(rows) > @page_size, do: to_string(List.last(events).seq)),
         outcome: get_in(d.data, ["ledger", "latest_outcome"]),
         evidence: EvidenceLinks.links(d.data["evidence"] || [], accounts, team),
         facts:
           facts
           |> Enum.sort_by(fn {key, fact} -> {fact["recorded_at"], key} end, :desc)
           |> Enum.map(fn {key, fact} ->
             %{
               id: key,
               text: fact["text"],
               recorded_at: fact["recorded_at"],
               links: EvidenceLinks.links(fact["evidence"] || [], accounts, team)
             }
           end)
       }}
    else
      nil -> {:error, :not_found}
      error -> error
    end
  end

  # Older holds retain a generic question. Read their saved verdict without
  # rewriting events or putting private review text in operational logs.
  defp review_explanations(user_id, delegation_id, events) do
    holds =
      Enum.filter(events, fn event ->
        event.kind == "failure" and event.data["failure_code"] == "policy_review_required"
      end)

    ids = Enum.map(holds, & &1.data["run_id"]) |> Enum.reject(&is_nil/1) |> Enum.uniq()

    runs =
      if ids == [] do
        %{}
      else
        from(r in Run,
          join: t in Turn,
          on: t.run_id == r.id,
          where:
            r.user_id == ^user_id and t.user_id == ^user_id and
              t.delegation_id == ^delegation_id and r.id in ^ids,
          limit: @page_size
        )
        |> Repo.all()
        |> Map.new(&{&1.id, Policy.review_explanation(Continuation.response(&1))})
      end

    Map.new(holds, &{&1.id, runs[&1.data["run_id"]]})
  end

  defp cursor(nil), do: {:ok, nil}

  defp cursor(value) when is_binary(value) and byte_size(value) <= 19 do
    case Integer.parse(value) do
      {number, ""} when number > 0 and number <= 9_223_372_036_854_775_807 -> {:ok, number}
      _ -> {:error, :invalid_history_cursor}
    end
  end

  defp cursor(_), do: {:error, :invalid_history_cursor}

  defp event_links(%{kind: "inbound_message"} = event, d, accounts, team) do
    ref = Map.put(event.data, "provider", d.provider)

    ref =
      case String.split(event.event_key, ":") do
        ["gmail", account, _] ->
          case Integer.parse(account) do
            {id, ""} -> Map.put(ref, "account_id", id)
            _ -> ref
          end

        ["slack", workspace, channel | _] ->
          Map.merge(ref, %{"team_id" => workspace, "channel" => channel})

        _ ->
          ref
      end

    EvidenceLinks.links([ref], accounts, team)
  end

  defp event_links(%{kind: "send_receipt", data: data}, d, accounts, team) do
    ref =
      (data["receipt"] || %{})
      |> Map.put("account_id", d.connected_account_id)
      |> Map.put("provider", d.provider)

    if data["action_type"] == "calendar_create_event",
      do: EvidenceLinks.calendar(get_in(data, ["receipt", "html_link"])),
      else: EvidenceLinks.links([ref], accounts, team)
  end

  defp event_links(_, _, _, _), do: []

  defp describe(%{kind: "user_action", data: data}) do
    title =
      case data["action"] do
        "start" -> "Delegation started"
        "pause" -> "You paused the conversation"
        "resume" -> "You resumed the conversation"
        "take_over" -> "You took over"
        "stop" -> "You stopped the delegation"
        "answer" -> "You answered the question"
        _ -> "Conversation instructions updated"
      end

    {title, nil}
  end

  defp describe(%{kind: "inbound_message", data: data}) do
    title =
      case data["classification"] do
        "historical" -> "Earlier message saved"
        "reply" -> "Reply received"
        "own_send" -> "Sent message observed"
        "human_send" -> "Your message observed"
        "auto_reply" -> "Automatic reply received"
        "acknowledgement" -> "Thanks received"
        "bounce" -> "Delivery problem received"
        "source_changed" -> "Source message changed"
        "stop" -> "Request to stop received"
        "scope_change" -> "Conversation participants changed"
        "thread_changed" -> "Reply arrived in another thread"
        _ -> "Conversation update received"
      end

    {title, nil}
  end

  defp describe(%{kind: "decision", data: data}) do
    title =
      case data["kind"] do
        kind when kind in ~w(send propose_times) -> "Reply planned"
        "book" -> "Booking planned"
        "complete" -> "Outcome identified"
        "needs_user" -> "Your input requested"
        "wait" -> "Waiting planned"
        _ -> "Next step assessed"
      end

    {title, data["question"]}
  end

  defp describe(%{kind: "send_receipt", data: data}) do
    title =
      if data["action_type"] == "calendar_create_event",
        do: "Calendar booking confirmed",
        else: "Message sent"

    detail = if get_in(data, ["receipt", "reconciled"]), do: "Confirmed by checking the provider."
    {title, detail}
  end

  defp describe(%{kind: "state_changed", data: data}) do
    title =
      case data["state"] do
        "completed" -> "Delegation completed"
        "stopped" -> "Delegation stopped"
        "expired" -> "Delegation expired"
        "paused" -> "Conversation paused"
        "needs_user" -> "Needs your decision"
        "waiting_reply" -> "Waiting for a reply"
        "waiting_capacity" -> "Waiting for capacity"
        "reconciling" -> "Checking delivery"
        "sending" -> "Action prepared"
        "deciding" -> "Assessing the next step"
        _ -> "Refreshing conversation context"
      end

    {title, if(data["state"] == "completed", do: data["outcome"], else: data["question"])}
  end

  defp describe(%{kind: "send_unknown"}),
    do: {"Delivery uncertain", "Checking the provider before any further send."}

  defp describe(%{kind: "reconciliation_exhausted"}),
    do:
      {"Delivery still uncertain",
       "Needs your review. This does not mean the message was not sent."}

  defp describe(%{kind: "send_deferred"}),
    do: {"Sending delayed", "The provider's request limit was reached before sending."}

  defp describe(%{kind: "capacity_hold"}), do: {"Waiting for capacity", nil}

  defp describe(%{kind: "source_gap"}),
    do:
      {"Conversation context incomplete",
       "Waiting for complete source evidence before continuing."}

  defp describe(%{kind: "failure", data: data}),
    do: {"Conversation needs attention", data["question"]}
end
