defmodule Maraithon.Delegations.Ledger do
  @moduledoc "Compact, cited conversation facts. The grant remains the only authority."
  alias Maraithon.{DurablePayload, PromptBudget}
  alias Maraithon.Delegations.{GmailSource, Ingress, Scope}

  @max_bytes 32_768
  @fact_bytes 28_000

  def snapshot(context),
    do: context.run.prompt_snapshot["fact_ledger"] || context.delegation.data["ledger"] || %{}

  def facts(context), do: snapshot(context)["facts"] || %{}

  def prompt(context) do
    Map.put(
      snapshot(context),
      "facts",
      Map.new(facts(context), fn {key, fact} ->
        {key,
         %{"text" => fact["text"], "evidence" => Enum.map(fact["evidence"], & &1["message_id"])}}
      end)
    )
  end

  def messages(context) do
    recent = Enum.take(context.run.prompt_snapshot["sources"]["messages"] || [], -6)
    recalled = Enum.map(context.run.prompt_snapshot["recalled_sources"] || [], & &1["message"])
    Enum.uniq_by(recent ++ recalled, & &1["message_id"])
  end

  def reference(context, message) do
    source = context.run.prompt_snapshot["sources"]

    %{
      "provider" => Map.get(context.delegation, :provider, "gmail"),
      "account_id" => source["account_id"],
      "channel" => message["channel"],
      "thread_id" => message["thread_id"],
      "message_id" => message["message_id"],
      "digest" => digest(message)
    }
  end

  def digest(%{"provider" => "slack", "revision" => revision}), do: revision

  def digest(message),
    do:
      Scope.hash(%{
        "headers" => GmailSource.fingerprint([message]),
        "body" => message["text_body"]
      })

  def references(context),
    do: facts(context) |> Map.values() |> Enum.flat_map(& &1["evidence"]) |> Enum.uniq()

  def requested_ids(decision) when is_map(decision) do
    updates = Map.get(decision, "facts", [])
    evidence = decision["evidence"]
    forgotten = Map.get(decision, "forget_facts", [])

    if is_list(updates) and length(updates) <= 8 and Enum.all?(updates, &valid_update?/1) and
         ids?(evidence, 0, 6) and is_list(forgotten) and length(forgotten) <= 8 and
         Enum.all?(forgotten, &key?/1) and length(Enum.uniq(forgotten)) == length(forgotten) do
      {:ok, Enum.uniq(evidence ++ Enum.flat_map(updates, & &1["evidence"]))}
    else
      {:error, :invalid_fact_update}
    end
  end

  def requested_ids(_), do: {:error, :invalid_decision}

  def merge(context, decision, now) do
    with {:ok, requested} <- requested_ids(decision) do
      updates = Map.get(decision, "facts", [])
      forgotten = Map.get(decision, "forget_facts", [])
      existing = facts(context)
      messages = Map.new(messages(context), &{&1["message_id"], &1})
      keys = Enum.map(updates, & &1["key"])

      cond do
        Enum.any?(requested, &(not Map.has_key?(messages, &1))) ->
          {:error, :unverified_evidence}

        length(Enum.uniq(keys)) != length(keys) or
            Enum.any?(forgotten, &(&1 in keys or not Map.has_key?(existing, &1))) ->
          {:error, :invalid_fact_update}

        Enum.any?(updates, fn fact ->
          Enum.any?(fact["evidence"], fn id ->
            ref = source_reference(context, messages[id])

            not counterparty?(context, messages[id]) or not is_integer(ref["account_id"]) or
                not is_binary(ref["thread_id"])
          end)
        end) ->
          {:error, :unverified_fact}

        true ->
          facts =
            Enum.reduce(updates, Map.drop(existing, forgotten), fn fact, acc ->
              evidence = Enum.map(fact["evidence"], &source_reference(context, messages[&1]))

              Map.put(acc, fact["key"], %{
                "text" => fact["text"],
                "evidence" => evidence,
                "recorded_at" => DateTime.to_iso8601(now),
                "source_revision" => context.turn.source_revision
              })
            end)

          ledger = Map.put(snapshot(context), "facts", facts)

          if map_size(facts) <= 64 and PromptBudget.encoded_bytes(facts) <= @fact_bytes and
               valid_storage?(ledger),
             do: {:ok, ledger},
             else: {:error, :fact_ledger_full}
      end
    end
  end

  def valid_storage?(ledger),
    do: is_map(ledger) and match?({:ok, _}, DurablePayload.prepare_map(ledger, @max_bytes))

  defp source_reference(context, message) do
    case Enum.find(context.run.prompt_snapshot["recalled_sources"] || [], fn recalled ->
           recalled["message"]["message_id"] == message["message_id"]
         end) do
      nil -> reference(context, message)
      recalled -> recalled["reference"]
    end
  end

  def counterparty?(context, message) do
    scope = context.grant.data["scope"]
    ref = source_reference(context, message)

    scope =
      if Map.get(context.delegation, :provider, "gmail") == "gmail" and
           ref["account_id"] == scope["source_account_id"] and
           is_binary(scope["source_user_email"]),
         do: put_in(scope, ["identity", "email"], scope["source_user_email"]),
         else: scope

    Ingress.classify(message, scope) == "reply"
  end

  defp valid_update?(%{"key" => key, "text" => text, "evidence" => ids} = fact),
    do:
      map_size(fact) == 3 and key?(key) and is_binary(text) and String.trim(text) != "" and
        byte_size(text) <= 800 and ids?(ids, 1, 3)

  defp valid_update?(_), do: false
  defp key?(key), do: is_binary(key) and Regex.match?(~r/^[a-z][a-z0-9_]{0,63}$/, key)

  defp ids?(ids, min, max),
    do:
      is_list(ids) and length(ids) in min..max and
        length(Enum.uniq(ids)) == length(ids) and
        Enum.all?(ids, &(is_binary(&1) and byte_size(&1) in 1..128))
end
