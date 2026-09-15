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

  def scope_enabled?(d, grant) do
    sends_enabled?(d.user_id, d.provider) and
      (Application.get_env(:maraithon, :delegation_eval_only, false) != true or
         controlled_scope?(d, grant.data["scope"]))
  end

  defp controlled_scope?(d, scope) do
    pair = ~w(kent@runner.now kent.fenwick@gmail.com)

    d.user_id == "kent@runner.now" and d.provider == "gmail" and
      get_in(scope, ["identity", "email"]) in pair and
      is_binary(scope["subject"]) and String.starts_with?(scope["subject"], "[Maraithon eval]") and
      scope["to"] != [] and Enum.all?(scope["to"] ++ scope["cc"], &(&1 in pair))
  end
end
