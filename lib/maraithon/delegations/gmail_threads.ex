defmodule Maraithon.Delegations.GmailThreads do
  @moduledoc "Verified RFC ancestry across Gmail thread boundaries, stored in the existing event ledger."
  import Ecto.Query
  alias Maraithon.{Delegations, Repo}
  alias Maraithon.Connectors.Gmail
  alias Maraithon.Delegations.{Delegation, Event, Scope}

  @kind "gmail_reference"
  @limit 2_048

  def remember!(d, account, message, eligible?) do
    unless Repo.in_transaction?(), do: raise(ArgumentError, "message references need authority")

    ids =
      if eligible?,
        do:
          Enum.uniq(
            ids(field(message, :internet_message_id)) ++
              ids(field(message, :original_internet_message_id))
          ),
        else: []

    # An untrusted or unidentified message gets a nonmatching marker, so it
    # cannot become legacy ancestry later or make the compatibility scan grow.
    for id <- if(ids == [], do: [nil], else: ids) do
      put!(
        d,
        account,
        field(message, :message_id),
        field(message, :thread_id),
        id,
        field(message, :internal_date) || d.inserted_at
      )
    end
  end

  # A reference is a consumed ledger row, not another coordinator wake. The
  # existing (delegation_id, event_key) index serves the account-scoped lookup.
  defp put!(d, account, message, thread, id, occurred) do
    key = key(account, id || "message:#{message}")

    unless Repo.exists?(from e in Event, where: e.delegation_id == ^d.id and e.event_key == ^key) do
      %Event{user_id: d.user_id}
      |> Event.changeset(%{
        delegation_id: d.id,
        kind: @kind,
        event_key: key,
        source_ref: message,
        occurred_at: occurred,
        wake_state: "consumed",
        data: %{"account_id" => account, "thread_id" => thread, "internet_message_id" => id}
      })
      |> Repo.insert!()
    end
  end

  def candidates(user, account, message) do
    refs = parents(message)

    if refs == [] do
      []
    else
      keys = Enum.map(refs, &key(account, &1))
      # A newer indexed conversation must not hide a conflicting legacy one.
      rows = references(user, account, keys) ++ legacy(user, account, refs)

      rows
      |> Enum.map(& &1.delegation_id)
      |> Enum.uniq()
      |> then(fn ids ->
        Repo.all(
          from d in Delegation,
            where: d.user_id == ^user and d.connected_account_id == ^account and d.id in ^ids,
            order_by: d.id,
            lock: "FOR UPDATE"
        )
        |> Enum.map(&Delegation.hydrate/1)
      end)
    end
  end

  defp references(user, account, keys) do
    rows =
      Repo.all(
        from d in Delegation,
          join: e in Event,
          on: e.delegation_id == d.id and e.user_id == d.user_id,
          where:
            d.user_id == ^user and d.provider == "gmail" and d.connected_account_id == ^account and
              e.kind == @kind and e.event_key in ^keys,
          limit: 65,
          select: e
      )

    if length(rows) > 64, do: Repo.rollback(:ambiguous_message_ancestry)

    rows
    |> Enum.map(&Event.hydrate/1)
    |> Enum.filter(fn event ->
      data = event.data || %{}
      data["account_id"] == account and key(account, data["internet_message_id"]) in keys
    end)
  end

  # Older releases already saved RFC headers in authenticated inbound events.
  # This bounded compatibility read needs no mailbox scan or additional API call.
  defp legacy(user, account, refs) do
    pattern = "gmail:#{account}:%"

    indexed =
      from r in Event,
        where:
          r.delegation_id == parent_as(:event).delegation_id and
            r.source_ref == parent_as(:event).source_ref and r.kind == @kind,
        select: 1

    rows =
      Repo.all(
        from d in Delegation,
          join: e in Event,
          as: :event,
          on: e.delegation_id == d.id and e.user_id == d.user_id,
          where:
            d.user_id == ^user and d.provider == "gmail" and d.connected_account_id == ^account and
              not is_nil(d.provider_thread_id) and e.kind == "inbound_message" and
              like(e.event_key, ^pattern) and not exists(subquery(indexed)),
          order_by: [desc: e.seq],
          limit: ^(@limit + 1),
          select: {d, e}
      )

    if length(rows) > @limit, do: Repo.rollback(:gmail_legacy_reference_limit)

    Enum.flat_map(rows, fn {d, row} ->
      event = Event.hydrate(row)
      data = event.data || %{}
      matches = ids(data["internet_message_id"]) ++ ids(data["original_internet_message_id"])

      if Enum.any?(matches, &(&1 in refs)) and
           data["classification"] in ~w(historical reply own_send human_send stop) do
        d = Delegation.hydrate(d)
        # Legacy rows predate rollover support, so their original thread is
        # either the still-current thread or the first saved thread segment.
        thread = List.first(d.data["gmail_threads"] || []) || d.provider_thread_id
        for id <- matches, do: put!(d, account, event.source_ref, thread, id, event.occurred_at)
        [event]
      else
        []
      end
    end)
  end

  def rollover(d, message) do
    scope = Delegations.current_grant(d).data["scope"]

    threads =
      Enum.uniq(
        (d.data["gmail_threads"] || [d.provider_thread_id]) ++ [field(message, :thread_id)]
      )

    cond do
      not Gmail.valid_id?(field(message, :thread_id)) or
        not Gmail.valid_id?(field(message, :message_id)) or
          not is_struct(field(message, :internal_date), DateTime) ->
        {:error, :source_gap}

      not is_binary(subject(scope["subject"])) ->
        {:error, :source_gap}

      subject(field(message, :subject)) != subject(scope["subject"]) ->
        {:error, :subject_changed}

      length(threads) > 128 ->
        {:error, :thread_history_limit}

      true ->
        {:ok, threads}
    end
  end

  defp parents(message) do
    direct = ids(field(message, :in_reply_to))
    refs = ids(field(message, :references))

    cond do
      length(direct) > 1 or length(refs) > 64 -> []
      direct != [] and refs != [] and List.last(refs) != hd(direct) -> []
      true -> Enum.uniq(direct ++ refs)
    end
  end

  defp ids(value) when is_binary(value) and byte_size(value) <= 16_384,
    do:
      Regex.scan(~r/<[^<>\s]+@[^<>\s]+>/, value)
      |> List.flatten()
      |> Enum.filter(&(byte_size(&1) <= 998))

  defp ids(_), do: []

  defp subject(value) when is_binary(value),
    do: value |> String.trim() |> String.replace(~r/^(?:re:\s*)+/i, "") |> String.downcase()

  defp subject(_), do: nil
  defp key(account, id), do: "gmail-ref:#{account}:#{Scope.hash(id)}"
  defp field(message, key), do: Map.get(message, key, Map.get(message, Atom.to_string(key)))
end
