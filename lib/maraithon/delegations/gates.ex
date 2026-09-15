defmodule Maraithon.Delegations.Gates do
  @moduledoc "Explicit rollout gates; disabling sends never discards a conversation."
  def enabled?(user_id) do
    Application.get_env(:maraithon, :delegations_enabled, false) == true and
      user_id in Application.get_env(:maraithon, :delegation_user_allowlist, [])
  end

  def sends_enabled?(user_id, provider) when provider in ~w(gmail slack) do
    gates = Application.get_env(:maraithon, :delegation_sends_enabled, %{})
    key = if provider == "gmail", do: :gmail, else: :slack
    enabled?(user_id) and Map.get(gates, key, false) == true
  end

  def sends_enabled?(_, _), do: false
end
