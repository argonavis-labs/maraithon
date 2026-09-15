defmodule MaraithonWeb.AssistantSettings do
  @moduledoc "Shared, credential-free assistant settings for web and native clients."
  alias Maraithon.{AssistantIdentities, ConnectedAccounts}
  alias Maraithon.Delegations.{Gates, Preferences}

  def load(user_id, params \\ %{}) do
    if Gates.enabled?(user_id) do
      identity = AssistantIdentities.get(user_id)

      accounts =
        ConnectedAccounts.list_for_user(user_id)
        |> Enum.filter(
          &(&1.status == "connected" and
              (&1.provider == "google" or String.starts_with?(&1.provider, "google:")))
        )
        |> Enum.map(&%{id: &1.id, label: &1.external_account_id || &1.provider})

      selected =
        integer(params["assistant_account"]) || (identity && identity.gmail_connected_account_id)

      selected = if Enum.any?(accounts, &(&1.id == selected)), do: selected

      {aliases, error} =
        if selected do
          case AssistantIdentities.send_as(user_id, selected) do
            {:ok, aliases} ->
              {Enum.map(aliases, &%{email: &1["sendAsEmail"], primary: &1["isPrimary"] == true}),
               nil}

            {:error, reason} ->
              {[], MaraithonWeb.DelegationCopy.error(reason)}
          end
        else
          {[], nil}
        end

      data = if identity, do: Map.drop(identity.data, ["_bound"]), else: %{"disclose_ai" => true}

      %{
        enabled: true,
        accounts: accounts,
        selected_account: selected,
        aliases: aliases,
        error: error,
        identity: Map.put(data, "gmail_mode", (identity && identity.gmail_mode) || "account"),
        preferences: Preferences.get(user_id)
      }
    else
      %{enabled: false}
    end
  end

  def save_identity(user_id, attrs) do
    if Gates.enabled?(user_id) do
      attrs =
        attrs
        |> Map.put("gmail_connected_account_id", integer(attrs["gmail_connected_account_id"]))
        |> Map.put("disclose_ai", truthy?(attrs["disclose_ai"]))
        |> Map.put("cc_user_on_first_send", truthy?(attrs["cc_user_on_first_send"]))

      AssistantIdentities.configure(user_id, attrs)
    else
      {:error, :delegations_disabled}
    end
  end

  def save_preferences(user_id, attrs) do
    if Gates.enabled?(user_id) do
      defaults = Preferences.defaults()

      values =
        Map.new(Map.take(attrs, Map.keys(defaults)), fn {key, value} ->
          default = defaults[key]

          normalized =
            cond do
              is_integer(default) ->
                integer(value)

              is_boolean(default) ->
                truthy?(value)

              is_list(default) and is_list(value) ->
                value |> Enum.reject(&(&1 == "")) |> Enum.map(&integer/1)

              true ->
                value
            end

          {key, normalized}
        end)

      Preferences.put(user_id, values)
    else
      {:error, :delegations_disabled}
    end
  end

  defp integer(value) when is_integer(value), do: value

  defp integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {number, ""} -> number
      _ -> nil
    end
  end

  defp integer(_), do: nil
  defp truthy?(value), do: value in [true, "true", "on", "1"]
end
