defmodule Maraithon.Memory.VoiceSamples do
  @moduledoc "Bounded, authored voice evidence. Removed text never reaches the profile model."
  import Ecto.Query
  alias Maraithon.{AssistantIdentities, ConnectedAccounts, Repo}
  alias Maraithon.Connectors.Gmail.BodyText
  alias Maraithon.Tools.GmailApiHelpers
  alias Maraithon.TelegramAssistant.PreparedAction

  @version 1
  @max_actions 128
  @forward ~r/^\s*(?:-{2,}\s*(?:Forwarded message|Original Message)|Begin forwarded message:|From:.*\n(?:Sent|Date):)/imu
  @reply ~r/^[\t ]*On [^\n]{1,500}(?:\n[^\n]{1,500}){0,3}wrote:[\t ]*$/imu
  @html_quote ~r/<blockquote\b|<(?:div|section)\b[^>]*class=["'][^"']*\bgmail_quote\b/iu
  @footer ~r/^\s*(?:--\s*|\+{2,}|Sent from my .+|Get Outlook for .+|CONFIDENTIALITY NOTICE.*|This (?:email|message) (?:and any attachments )?(?:is confidential|contains confidential).*)$/imu

  def version, do: @version

  # Older sends can be within the sample window even if the action was created
  # earlier. Read by update time, never silently truncate the provenance check.
  def generated_writes(user_id, channel, messages) do
    since =
      messages
      |> Enum.map(&message_time/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.min(DateTime, fn -> DateTime.utc_now() end)
      |> DateTime.add(-1, :day)

    types = if channel == "gmail", do: ~w(gmail_send gmail_draft_send), else: ["slack_post"]

    actions =
      Repo.all(
        from a in PreparedAction,
          where: a.user_id == ^user_id and a.action_type in ^types and a.updated_at >= ^since,
          order_by: a.id,
          limit: @max_actions + 1
      )

    if length(actions) <= @max_actions and Enum.all?(actions, &is_nil(&1.payload_purged_at)),
      do: {:ok, Enum.map(actions, &PreparedAction.hydrate_payload/1)},
      else: {:error, :voice_provenance_unavailable}
  end

  def gmail_identities(user_id, messages) do
    assistant = AssistantIdentities.get(user_id)

    assistant_alias =
      assistant && assistant.gmail_mode == "alias" && assistant.data["gmail_send_as_email"]

    assistant_alias = if is_binary(assistant_alias), do: String.downcase(assistant_alias)

    messages
    |> Enum.map(& &1.google_provider)
    |> Enum.uniq()
    |> Enum.reduce_while({:ok, %{}}, fn provider, {:ok, identities} ->
      with %{status: "connected"} = account <- ConnectedAccounts.get(user_id, provider),
           false <- AssistantIdentities.assistant_account?(account),
           {:ok, %{"sendAs" => aliases}} when is_list(aliases) <-
             GmailApiHelpers.get_for_account(user_id, account.id, "/users/me/settings/sendAs") do
        aliases =
          Enum.filter(
            aliases,
            &(is_map(&1) and is_binary(&1["sendAsEmail"]) and
                (&1["isPrimary"] == true or &1["verificationStatus"] == "accepted"))
          )

        authors =
          aliases
          |> Enum.map(&normalized(&1["sendAsEmail"]))
          |> Enum.reject(&(&1 == "" or &1 == assistant_alias))

        signatures =
          aliases
          |> Enum.map(& &1["signature"])
          |> Enum.filter(&is_binary/1)
          |> Enum.map(&BodyText.signature/1)

        {:cont,
         {:ok, Map.put(identities, provider, %{"authors" => authors, "signatures" => signatures})}}
      else
        {:error, _} = error -> {:halt, error}
        _ -> {:halt, {:error, :voice_identity_unavailable}}
      end
    end)
  end

  def collect(messages, channel, identities, actions) do
    {samples, excluded, cleaned} =
      Enum.reduce(messages, {[], %{}, %{}}, fn raw, {samples, excluded, cleaned} ->
        m = Map.new(raw, fn {key, value} -> {to_string(key), value} end)
        identity = identities[m["google_provider"]] || identities["slack"] || %{}

        case sample(m, channel, identity, actions) do
          {:ok, text, removed} ->
            if text in samples,
              do: {samples, count(excluded, "duplicate"), cleaned},
              else: {[text | samples], excluded, Enum.reduce(removed, cleaned, &count(&2, &1))}

          {:exclude, reason} ->
            {samples, count(excluded, reason), cleaned}
        end
      end)

    samples = Enum.reverse(samples)

    {:ok, samples,
     %{
       channel => length(samples),
       "cleaning_version" => @version,
       "excluded" => excluded,
       "cleaned" => cleaned
     }}
  end

  defp sample(m, channel, identity, actions) do
    {body, html_quote?} = body(m, channel)
    labels = m["labels"] || []
    from = if channel == "gmail", do: sender(m["from"]), else: m["user"]

    cond do
      is_nil(message_time(m)) ->
        {:exclude, "unverified_date"}

      channel == "gmail" and ("SENT" not in labels or "DRAFT" in labels) ->
        {:exclude, "not_sent"}

      from not in (identity["authors"] || []) ->
        {:exclude, "other_author"}

      channel == "slack" and m["team"] != identity["team"] ->
        {:exclude, "other_workspace"}

      automated?(m) ->
        {:exclude, "automated"}

      generated?(m, body, actions) ->
        {:exclude, "generated"}

      not is_binary(body) or String.trim(body) == "" ->
        {:exclude, "missing_body"}

      Regex.match?(@forward, body) or Regex.match?(~r/^\s*(?:fwd?|fw):/i, m["subject"] || "") ->
        {:exclude, "forwarded"}

      true ->
        case clean(body, identity["signatures"] || []) do
          {:ok, text, removed} ->
            {:ok, text, Enum.uniq(removed(removed, "quotes", html_quote?))}

          error ->
            error
        end
    end
  end

  defp automated?(m),
    do:
      normalized(m["auto_submitted"]) not in ["", "no"] or
        normalized(m["return_path"]) == "<>" or
        normalized(m["precedence"]) in ~w(bulk list junk) or is_binary(m["list_id"]) or
        is_binary(m["bot_id"]) or is_binary(m["app_id"]) or
        m["subtype"] not in [nil, ""]

  defp generated?(m, body, actions) do
    marker? =
      Enum.any?(~w(internet_message_id original_internet_message_id), fn key ->
        String.starts_with?(normalized(m[key]), "<maraithon.")
      end)

    marker? or
      Enum.any?(actions, fn action ->
        receipt =
          action.payload["_maraithon_reconciliation_receipt"] ||
            action.payload["_maraithon_execution_result"] || %{}

        generated_body = action.payload["body"] || action.payload["text"]
        # Exclusion is conservative, not a claim that a draft was delivered.
        action.id == m["client_msg_id"] or
          (is_binary(m["message_id"]) and receipt["message_id"] == m["message_id"]) or
          (is_binary(m["ts"]) and receipt["ts"] == m["ts"] and
             receipt["channel"] == channel_id(m["channel"])) or
          (is_binary(body) and is_binary(generated_body) and String.trim(generated_body) != "" and
             canonical(body) == canonical(generated_body))
      end)
  end

  defp clean(body, signatures) do
    original = canonical(body)

    quoted =
      original
      |> String.split(@reply, parts: 2)
      |> hd()
      |> String.split("\n")
      |> Enum.reject(&Regex.match?(~r/^\s*(?:>|&gt;)/, &1))
      |> Enum.join("\n")
      |> String.trim()

    signed =
      Enum.reduce(signatures, quoted, fn signature, text ->
        words = signature |> String.split() |> Enum.map(&Regex.escape/1)

        if words == [] do
          text
        else
          suffix = Regex.compile!("(?:^|\n)[\t ]*" <> Enum.join(words, "\\s+") <> "\\s*\\z", "u")
          text |> String.replace(suffix, "") |> String.trim()
        end
      end)

    text = signed |> String.split(@footer, parts: 2) |> hd() |> String.trim()

    removed =
      []
      |> removed("quotes", quoted != original)
      |> removed("signature", signed != quoted)
      |> removed("footer", text != signed)

    if text == "",
      do: {:exclude, "empty_after_cleaning"},
      else: {:ok, String.slice(text, 0, 2_000), removed}
  end

  defp canonical(text),
    do: text |> String.replace("\r\n", "\n") |> String.replace(~r/[\t ]+/u, " ") |> String.trim()

  defp body(m, "gmail") do
    html = m["html_body"]
    plain = m["text_body"]

    if is_binary(html) and plain in [nil, "", html] do
      parts = String.split(html, @html_quote, parts: 2)
      {BodyText.signature(hd(parts)), length(parts) > 1}
    else
      {plain, false}
    end
  end

  defp body(m, "slack"), do: {m["text"], false}

  defp message_time(m) do
    case m[:internal_date] || m["internal_date"] do
      %DateTime{} = date -> date
      _ -> Maraithon.Delegations.SlackSource.time(m["ts"])
    end
  end

  defp channel_id(%{"id" => id}), do: id
  defp channel_id(id) when is_binary(id), do: id
  defp channel_id(_), do: nil

  defp sender(from) when is_binary(from) do
    case Regex.scan(~r/[A-Z0-9.!#$%&'*+\/=?^_`{|}~-]+@[A-Z0-9.-]+\.[A-Z]{2,}/iu, from) do
      [[email]] -> String.downcase(email)
      _ -> nil
    end
  end

  defp sender(_), do: nil
  defp normalized(value) when is_binary(value), do: value |> String.trim() |> String.downcase()
  defp normalized(_), do: ""
  defp count(counts, reason), do: Map.update(counts, reason, 1, &(&1 + 1))
  defp removed(list, reason, true), do: [reason | list]
  defp removed(list, _, false), do: list
end
