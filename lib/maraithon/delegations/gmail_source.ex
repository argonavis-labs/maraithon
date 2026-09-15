defmodule Maraithon.Delegations.GmailSource do
  @moduledoc "Incremental Gmail evidence: a complete header index, durable ingress progress, and six recent bodies."
  import Ecto.Query
  alias Maraithon.{DurablePayload, Repo}
  alias Maraithon.Connectors.{Gmail, GoogleAccount}
  alias Maraithon.Delegations.{Event, Scope, Turn}
  alias Maraithon.TelegramAssistant.Run

  @batch_size 8
  @max_messages 10_000
  @fields ~w(message_id thread_id from to cc subject internet_message_id original_internet_message_id in_reply_to references auto_submitted return_path content_type labels internal_date)

  def index(d, scope) do
    account =
      if d.provider_thread_id, do: d.connected_account_id, else: scope["source_account_id"]

    thread = d.provider_thread_id || scope["source_thread_id"]

    with true <- is_integer(account),
         {:ok, token} <- GoogleAccount.access_token(d.user_id, account),
         {:ok, messages} <- Gmail.fetch_thread_metadata(token, thread, access_token: true),
         {:ok, index} <- metadata(messages, thread) do
      {:ok, %{account: account, thread: thread, token: token, messages: index}}
    else
      false -> {:error, :invalid_google_account}
      error -> error
    end
  end

  def read(context) do
    with {:ok, index} <- index(context.delegation, context.grant.data["scope"]),
         do: read(context, index)
  end

  def read(context, index) do
    d = context.delegation
    known = processed(d, index)
    missing = Enum.reject(index.messages, &MapSet.member?(known, &1["message_id"]))
    batch = Enum.take(missing, @batch_size)
    done? = length(missing) <= @batch_size
    recent = if done?, do: Enum.take(index.messages, -6), else: []

    # Historical messages need headers for their durable ingress record. Only
    # recent context and newly arrived messages need bodies for classification.
    needed = Enum.filter(batch, &(DateTime.compare(date(&1), d.inserted_at) != :lt)) ++ recent
    cache = if needed == [], do: %{}, else: cached_messages(context, index)

    with {:ok, bodies} <- bodies(index, Enum.uniq_by(needed, & &1["message_id"]), cache),
         {:ok, snapshot} <- maybe_snapshot(done?, index, bodies) do
      messages = Enum.map(batch, &for_ingress(Map.get(bodies, &1["message_id"], &1)))
      {:ok, messages, snapshot}
    end
  end

  def fingerprint(messages), do: Scope.hash(Enum.map(messages, &header/1))

  def unchanged?(index, %{"complete" => true, "messages" => messages} = snapshot) do
    previous = snapshot["fingerprint"] || fingerprint(messages)

    snapshot["account_id"] == index.account and snapshot["thread_id"] == index.thread and
      fingerprint(index.messages) == previous
  end

  def unchanged?(_, _), do: false

  def snapshot(messages, account, thread) do
    with {:ok, index} <- metadata(messages, thread) do
      bodies =
        Map.new(messages, fn message ->
          message = normalize(message)
          {message["message_id"], message}
        end)

      maybe_snapshot(true, %{messages: index, account: account, thread: thread}, bodies)
    end
  end

  defp metadata(messages, thread) when is_list(messages) do
    messages =
      messages
      |> Enum.map(&normalize/1)
      |> Enum.reject(&(&1["labels"] |> List.wrap() |> Enum.member?("DRAFT")))

    ids = Enum.map(messages, & &1["message_id"])

    if length(messages) in 1..@max_messages and length(Enum.uniq(ids)) == length(ids) and
         Enum.all?(messages, &valid?(&1, thread)) do
      {:ok, Enum.sort_by(messages, &{DateTime.to_unix(date(&1), :microsecond), &1["message_id"]})}
    else
      {:error, :source_gap}
    end
  end

  defp metadata(_, _), do: {:error, :source_gap}

  defp processed(d, index) do
    keys = Enum.map(index.messages, &"gmail:#{index.account}:#{&1["message_id"]}")

    Repo.all(
      from e in Event,
        where:
          e.user_id == ^d.user_id and e.delegation_id == ^d.id and
            e.kind == "inbound_message" and e.event_key in ^keys,
        select: e.source_ref
    )
    |> MapSet.new()
  end

  defp cached_messages(context, index) do
    Repo.all(
      from t in Turn,
        join: r in Run,
        on: r.id == t.run_id and r.user_id == t.user_id,
        where:
          t.user_id == ^context.delegation.user_id and
            t.delegation_id == ^context.delegation.id and t.seq < ^context.turn.seq,
        order_by: [desc: t.seq],
        limit: 3,
        select: r
    )
    |> Enum.reduce(%{}, fn row, cache ->
      source = Run.hydrate_payloads(row).prompt_snapshot["sources"] || %{}

      if source["account_id"] == index.account and source["thread_id"] == index.thread and
           source["complete"] == true do
        Enum.reduce(source["messages"] || [], cache, fn message, acc ->
          Map.put_new(acc, message["message_id"], normalize(message))
        end)
      else
        cache
      end
    end)
  end

  defp bodies(index, needed, cache) do
    Enum.reduce_while(needed, {:ok, %{}}, fn meta, {:ok, found} ->
      id = meta["message_id"]
      cached = cache[id]

      result =
        if is_map(cached) and is_binary(cached["text_body"]) and header(cached) == header(meta),
          do: {:ok, cached},
          else: Gmail.fetch_message_content(index.token, id, access_token: true)

      with {:ok, message} <- result,
           message = normalize(message),
           true <- header(message) == header(meta) and is_binary(message["text_body"]) do
        {:cont, {:ok, Map.put(found, id, message)}}
      else
        {:error, _} = error -> {:halt, error}
        _ -> {:halt, {:error, :source_changed}}
      end
    end)
  end

  defp maybe_snapshot(false, _, _), do: {:ok, nil}

  defp maybe_snapshot(true, index, bodies) do
    recent = Enum.map(Enum.take(index.messages, -6), &Map.get(bodies, &1["message_id"]))

    if Enum.all?(recent, &(is_map(&1) and is_binary(&1["text_body"]))) do
      case DurablePayload.prepare_map(
             %{
               "account_id" => index.account,
               "thread_id" => index.thread,
               "read_at" => DateTime.to_iso8601(DateTime.utc_now()),
               "complete" => true,
               "message_count" => length(index.messages),
               "fingerprint" => fingerprint(index.messages),
               "messages" => recent
             },
             240_000
           ) do
        {:ok, _} = result -> result
        _ -> {:error, :source_gap}
      end
    else
      {:error, :source_gap}
    end
  end

  defp normalize(message) when is_map(message) do
    message = Map.new(message, fn {key, value} -> {to_string(key), value} end)

    Map.take(message, ["text_body" | @fields])
    |> Map.update("internal_date", nil, fn
      %DateTime{} = value -> DateTime.to_iso8601(value)
      value -> value
    end)
  end

  defp normalize(_), do: %{}

  defp header(message) do
    message = normalize(message)

    Map.new(@fields, &{&1, message[&1]})
    |> Map.put(
      "internal_date",
      if(date(message), do: DateTime.to_unix(date(message), :millisecond))
    )
    |> Map.put(
      "labels",
      Enum.sort(Enum.filter(List.wrap(message["labels"]), &(&1 in ~w(SENT DRAFT))))
    )
  end

  defp valid?(m, thread),
    do:
      Gmail.valid_id?(m["message_id"]) and m["thread_id"] == thread and
        is_list(m["labels"] || []) and
        not is_nil(date(m)) and is_binary(m["internet_message_id"]) and
        m["internet_message_id"] != "" and
        length(Enum.filter(Gmail.message_participants(m), &(&1["role"] == "from"))) == 1

  defp date(m) do
    result = if is_binary(m["internal_date"]), do: DateTime.from_iso8601(m["internal_date"])

    case result do
      {:ok, date, _} -> date
      _ -> nil
    end
  end

  defp for_ingress(message), do: Map.put(message, "internal_date", date(message))
end
