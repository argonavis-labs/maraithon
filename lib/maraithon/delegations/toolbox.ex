defmodule Maraithon.Delegations.Toolbox do
  @moduledoc "Bounded reads of conversation evidence under the frozen grant."
  alias Maraithon.PromptBudget
  alias Maraithon.Connectors.{Gmail, Slack}
  alias Maraithon.Delegations.{GmailSource, HistoryRead, Ledger, SlackIdentity, SlackSource}

  def history(context, request) do
    with {:ok, window} <- HistoryRead.window(request) do
      saved = context.run.prompt_snapshot["history_read"]

      if is_map(saved) and saved["window"] == window do
        {:ok, context.run.prompt_snapshot["recalled_sources"] || [], saved}
      else
        {refs, coverage} = HistoryRead.select(context, window)

        if length(Enum.uniq_by(refs, & &1["message_id"])) == length(refs) do
          with {:ok, recalled} <-
                 read_all(context, Enum.map(refs, &{:ok, &1, &1["provider"] == "gmail"})),
               do: {:ok, recalled, coverage}
        else
          {:error, :unverified_evidence}
        end
      end
    end
  end

  def read(context, decision) do
    with {:ok, requested} <- Ledger.requested_ids(decision) do
      recent = Enum.take(context.run.prompt_snapshot["sources"]["messages"] || [], -6)
      ids = requested -- Enum.map(recent, & &1["message_id"])

      refs =
        (Ledger.references(context) ++
           Enum.map(context.run.prompt_snapshot["recalled_sources"] || [], & &1["reference"]))
        |> Enum.uniq()

      account = context.run.prompt_snapshot["sources"]["account_id"]
      scope = context.grant.data["scope"]

      collision? =
        Enum.any?(refs, fn ref ->
          ref["message_id"] in requested and ref["account_id"] != account and
            Enum.any?(recent, &(&1["message_id"] == ref["message_id"]))
        end) or
          (context.delegation.provider == "gmail" and scope["source_account_id"] != account and
             scope["source_message_id"] in requested and
             Enum.any?(recent, &(&1["message_id"] == scope["source_message_id"])))

      cond do
        collision? ->
          {:error, :unverified_evidence}

        length(ids) > 6 ->
          {:error, :recalled_evidence_limit}

        true ->
          read_all(context, Enum.map(ids, &reference(context, &1, refs)))
      end
    end
  end

  defp read_all(context, references) do
    Enum.reduce_while(references, {:ok, []}, fn reference, {:ok, found} ->
      case reference do
        {:ok, ref, fresh?} ->
          with true <- allowed?(context, ref),
               {:ok, message} <- cached_or_fetch(context, ref),
               ref = if(fresh?, do: Map.put(ref, "digest", Ledger.digest(message)), else: ref),
               true <- matches?(message, ref) do
            found = found ++ [%{"reference" => ref, "message" => message}]

            if PromptBudget.encoded_bytes(found) <= 128_000,
              do: {:cont, {:ok, found}},
              else: {:halt, {:error, :recalled_evidence_limit}}
          else
            {:error, _} = error -> {:halt, error}
            _ -> {:halt, {:error, :recalled_evidence_changed}}
          end

        _ ->
          {:halt, {:error, :unverified_evidence}}
      end
    end)
  end

  # A legacy conversation may not have learned any facts yet. Its original
  # task message is the one additional source the grant identifies exactly.
  defp reference(context, id, refs) do
    scope = context.grant.data["scope"]

    case Enum.filter(refs, &(&1["message_id"] == id)) do
      [ref] ->
        {:ok, ref, false}

      [] ->
        if context.delegation.provider == "gmail" and id == scope["source_message_id"] do
          {:ok,
           %{
             "provider" => "gmail",
             "account_id" => scope["source_account_id"],
             "channel" => nil,
             "thread_id" => scope["source_thread_id"],
             "message_id" => id
           }, true}
        else
          {:error, :unverified_evidence}
        end

      _ ->
        {:error, :unverified_evidence}
    end
  end

  def verify_before_send(context) do
    Enum.reduce_while(context.run.prompt_snapshot["recalled_sources"] || [], :ok, fn item, :ok ->
      ref = item["reference"]

      with true <- allowed?(context, ref),
           {:ok, message} <- fetch(context, ref),
           true <- matches?(message, ref) do
        {:cont, :ok}
      else
        {:error, _} = error -> {:halt, error}
        _ -> {:halt, {:error, :recalled_evidence_changed}}
      end
    end)
  end

  defp cached_or_fetch(context, ref) do
    source = context.run.prompt_snapshot["sources"]
    messages = if source["account_id"] == ref["account_id"], do: source["messages"], else: []

    recalled =
      for item <- context.run.prompt_snapshot["recalled_sources"] || [],
          item["reference"] == ref,
          do: item["message"]

    case Enum.find(messages ++ recalled, &matches?(&1, ref)) do
      nil -> fetch(context, ref)
      message -> {:ok, message}
    end
  end

  defp fetch(context, %{"provider" => "gmail"} = ref) do
    with {:ok, token} <-
           Maraithon.Connectors.GmailAccess.for_account(
             context.delegation.user_id,
             ref["account_id"]
           ),
         {:ok, message} <-
           Gmail.fetch_message_content(token, ref["message_id"], access_token: true),
         {:ok, snapshot} <- GmailSource.snapshot([message], ref["account_id"], ref["thread_id"]),
         do: {:ok, hd(snapshot["messages"])}
  end

  defp fetch(context, %{"provider" => "slack"} = ref) do
    identity = context.grant.data["scope"]["identity"]
    channel = ref["channel"]
    thread = ref["thread_id"]
    id = ref["message_id"]
    opts = [oldest: id, latest: id, inclusive: true, limit: 2]

    with {:ok, token} <- SlackIdentity.read_token(context.delegation.user_id, identity, channel),
         {:ok, response} <-
           if(String.starts_with?(channel, "D"),
             do: Slack.get_conversation_history(token, channel, opts),
             else: Slack.get_thread_replies(token, channel, thread, opts)
           ),
         false <- response["has_more"] == true,
         true <- get_in(response, ["response_metadata", "next_cursor"]) in [nil, ""],
         [message] <- Enum.filter(response["messages"] || [], &(&1["ts"] == id)),
         true <- message["thread_ts"] in [nil, thread],
         message = SlackSource.normalize(message, channel, thread),
         true <- SlackSource.valid?(message) do
      {:ok, message}
    else
      {:error, _} = error -> error
      _ -> {:error, :recalled_evidence_changed}
    end
  end

  defp allowed?(context, ref) do
    d = context.delegation
    scope = context.grant.data["scope"]

    source =
      ref["account_id"] == scope["source_account_id"] and
        ref["thread_id"] == scope["source_thread_id"] and
        (d.provider == "gmail" or ref["channel"] == scope["source_channel_id"])

    bound =
      ref["account_id"] == d.connected_account_id and
        ref["thread_id"] in [d.provider_thread_id | d.data["gmail_threads"] || []] and
        (d.provider == "gmail" or ref["channel"] == d.slack_channel)

    ref["provider"] == d.provider and is_integer(ref["account_id"]) and
      is_binary(ref["thread_id"]) and (source or bound)
  end

  defp matches?(message, ref),
    do:
      message["message_id"] == ref["message_id"] and
        message["thread_id"] == ref["thread_id"] and Ledger.digest(message) == ref["digest"]
end
