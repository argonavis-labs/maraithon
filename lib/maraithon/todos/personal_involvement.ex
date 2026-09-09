defmodule Maraithon.Todos.PersonalInvolvement do
  @moduledoc """
  Validates the model's source-grounded assessment of the user's involvement.

  The model interprets direct and implicit responsibility. This boundary keeps
  generated todo copy out of its evidence and prevents a request addressed to
  another Slack participant from being relabelled as a direct ask to the user.
  """

  @kinds ~w(direct implicit)
  @evidence_keys ~w(source_record source_body source_excerpt body_excerpt source_quote quote matching_message_excerpt last_meaningful_message)

  def identity_context(user_id) do
    identity = Maraithon.UserIdentity.identity(user_id)

    slack_accounts =
      user_id
      |> Maraithon.OAuth.list_user_tokens()
      |> Enum.filter(&String.starts_with?(&1.provider, "slack:"))
      |> Enum.map(fn token ->
        Map.take(token.metadata || %{}, ~w(team_id authed_user_id slack_user_id))
      end)

    %{
      "names" => identity.names,
      "emails" => identity.emails,
      "phones" => identity.phones,
      "slack_accounts" => slack_accounts
    }
  end

  def assess(decision, candidate, context) do
    assessment = map(decision["involvement"])
    metadata = map(candidate["metadata"])
    evidence = Enum.flat_map(@evidence_keys, &strings(metadata[&1]))
    instructions = Enum.flat_map(context["todo_instructions"] || [], &strings(&1["content"]))
    quote = clean(assessment["source_quote"])
    connection = clean(assessment["connection"])
    connection_quote = clean(assessment["connection_quote"])

    cond do
      explicitly_requested?(candidate) ->
        {:ok,
         %{
           "kind" => "direct",
           "connection" => "Explicitly requested by the user.",
           "version" => 1
         }}

      assessment["kind"] not in @kinds ->
        {:skip, "No direct or source-supported implicit responsibility for the user."}

      is_nil(connection) or not quoted?(quote, evidence) ->
        {:skip, "Personal involvement is missing source evidence."}

      assessment["kind"] == "implicit" and
          not quoted?(connection_quote, evidence ++ instructions) ->
        {:skip,
         "Implicit responsibility needs a source or user-instruction quote linking the user to the work."}

      assessment["kind"] == "direct" and other_slack_addressee?(candidate, quote, context) ->
        {:skip, "The quoted Slack request addresses another person, not the connected user."}

      true ->
        {:ok,
         Map.take(assessment, ~w(kind source_quote connection connection_quote))
         |> Map.put("version", 1)}
    end
  end

  defp explicitly_requested?(candidate) do
    metadata = map(candidate["metadata"])

    candidate["source"] in ~w(user assistant mcp telegram telegram_assistant) and
      (metadata["explicit_user_request"] == true or metadata["user_requested"] == true)
  end

  defp other_slack_addressee?(%{"source" => "slack", "metadata" => metadata}, quote, context) do
    record = map(metadata["source_record"])
    account = map(metadata["source_account_identity"])
    team_id = record["team_id"] || account["team_id"] || metadata["team_id"]

    own_ids =
      Enum.filter(
        get_in(context, ["operator_identity", "slack_accounts"]) || [],
        &(is_binary(team_id) and &1["team_id"] == team_id)
      )
      |> Enum.flat_map(&[&1["authed_user_id"], &1["slack_user_id"]])
      |> Enum.filter(&is_binary/1)

    mentions =
      Regex.scan(~r/<@([A-Z0-9]+)(?:\|[^>]+)?>/, quote, capture: :all_but_first) |> List.flatten()

    names = get_in(context, ["operator_identity", "names"]) || []

    named_user? =
      Enum.any?(names, fn name ->
        Regex.match?(~r/(?<![\p{L}\p{N}])#{Regex.escape(name)}(?![\p{L}\p{N}])/iu, quote)
      end)

    record["is_dm"] != true and record["conversation_kind"] != "dm" and
      record["user"] not in own_ids and mentions != [] and
      not Enum.any?(mentions, &(&1 in own_ids)) and not named_user?
  end

  defp other_slack_addressee?(_candidate, _quote, _context), do: false

  defp quoted?(nil, _evidence), do: false

  defp quoted?(quote, evidence) do
    normalized = normalize(quote)

    String.length(normalized) >= 8 and
      Enum.any?(evidence, &String.contains?(normalize(&1), normalized))
  end

  defp normalize(text), do: text |> String.replace(~r/\s+/u, " ") |> String.trim()

  defp clean(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      value -> value
    end
  end

  defp clean(_value), do: nil

  defp map(value) when is_map(value), do: value
  defp map(_value), do: %{}

  defp strings(value) when is_binary(value), do: [value]
  defp strings(value) when is_list(value), do: Enum.flat_map(value, &strings/1)
  defp strings(value) when is_map(value), do: value |> Map.values() |> Enum.flat_map(&strings/1)
  defp strings(_value), do: []
end
