defmodule Maraithon.Tools.SlackHelpers do
  @moduledoc false

  alias Maraithon.OAuth
  alias Maraithon.Tools.ToolErrorCopy

  def resolve_access_token(user_id, team_id, opts \\ [])
      when is_binary(user_id) and is_binary(team_id) do
    preference = normalize_preference(Keyword.get(opts, :token_preference, "auto"))
    slack_user_id = Keyword.get(opts, :slack_user_id)
    required_scopes = normalize_required_scopes(Keyword.get(opts, :required_scopes, []))
    candidates = token_candidates(user_id, team_id, preference, slack_user_id)

    resolve_from_candidates(user_id, candidates, preference, required_scopes)
  end

  def normalize_error(:no_token), do: {:error, "slack_workspace_not_connected"}
  def normalize_error(:no_user_token), do: {:error, "slack_user_scope_not_connected"}

  def normalize_error({:missing_user_scope, scope}),
    do: {:error, "slack_user_scope_missing: #{scope}"}

  def normalize_error({:missing_bot_scope, scope}),
    do: {:error, "slack_bot_scope_missing: #{scope}"}

  def normalize_error({:slack_error, error})
      when error in ["invalid_auth", "not_authed", "token_revoked", "account_inactive"],
      do: {:error, "slack_workspace_reauth_required"}

  def normalize_error({:slack_error, "missing_scope"}),
    do: {:error, "Slack is missing the permissions it needs. Reconnect Slack in Maraithon."}

  def normalize_error({:slack_error, "channel_not_found"}),
    do: {:error, "Slack could not find that channel."}

  def normalize_error({:slack_error, "not_in_channel"}),
    do: {:error, "Slack cannot read that channel until the app is added to it."}

  def normalize_error({:slack_error, _error}),
    do: {:error, ToolErrorCopy.connected_source(:temporary_failure, slack_error_opts())}

  def normalize_error(reason),
    do: {:error, ToolErrorCopy.connected_source(reason, slack_error_opts())}

  defp resolve_from_candidates(user_id, candidates, preference, required_scopes) do
    initial_error =
      case preference do
        :user -> :no_user_token
        _ -> :no_token
      end

    Enum.reduce_while(candidates, {:error, initial_error}, fn provider, _acc ->
      case OAuth.get_token(user_id, provider) do
        nil ->
          {:cont, {:error, initial_error}}

        token ->
          case missing_required_scope(token, required_scopes) do
            nil ->
              case OAuth.get_valid_access_token(user_id, provider) do
                {:ok, access_token} ->
                  {:halt, {:ok, %{access_token: access_token, provider: provider}}}

                {:error, :no_token} ->
                  {:cont, {:error, initial_error}}

                {:error, reason} ->
                  {:halt, {:error, reason}}
              end

            missing_scope ->
              {:cont, {:error, missing_scope_error(provider, missing_scope)}}
          end
      end
    end)
  end

  defp token_candidates(user_id, team_id, preference, slack_user_id) do
    bot_provider = "slack:#{team_id}"
    user_providers = user_token_providers(user_id, team_id, slack_user_id)

    case preference do
      :user -> user_providers
      :bot -> [bot_provider]
      :auto -> user_providers ++ [bot_provider]
    end
    |> Enum.uniq()
  end

  defp user_token_providers(user_id, team_id, slack_user_id) do
    providers =
      OAuth.list_user_tokens(user_id)
      |> Enum.map(& &1.provider)
      |> Enum.filter(&is_binary/1)
      |> Enum.filter(&String.starts_with?(&1, "slack:#{team_id}:user:"))

    if is_binary(slack_user_id) and String.trim(slack_user_id) != "" do
      prioritized = "slack:#{team_id}:user:#{String.trim(slack_user_id)}"
      [prioritized | Enum.reject(providers, &(&1 == prioritized))]
    else
      providers
    end
  end

  defp normalize_preference(value) when value in [:auto, :bot, :user], do: value

  defp normalize_preference(value) when is_binary(value) do
    case String.downcase(String.trim(value)) do
      "user" -> :user
      "bot" -> :bot
      _ -> :auto
    end
  end

  defp normalize_preference(_value), do: :auto

  defp normalize_required_scopes(scopes) when is_list(scopes) do
    scopes
    |> Enum.map(&to_string/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp normalize_required_scopes(scope) when is_binary(scope),
    do: normalize_required_scopes([scope])

  defp normalize_required_scopes(_scopes), do: []

  defp missing_required_scope(_token, []), do: nil

  defp missing_required_scope(token, required_scopes) do
    token_scopes =
      token.scopes
      |> List.wrap()
      |> Enum.map(&to_string/1)
      |> MapSet.new()

    Enum.find(required_scopes, fn scope -> not MapSet.member?(token_scopes, scope) end)
  end

  defp missing_scope_error(provider, scope) do
    if String.contains?(provider, ":user:") do
      {:missing_user_scope, scope}
    else
      {:missing_bot_scope, scope}
    end
  end

  defp slack_error_opts do
    [
      label: "Slack",
      not_connected: "slack_workspace_not_connected",
      reauth_required: "slack_workspace_reauth_required",
      reconnect_required: "slack_workspace_reauth_required"
    ]
  end
end
