defmodule Maraithon.Delegations.GatesTest do
  use ExUnit.Case, async: false
  alias Maraithon.Delegations.Gates

  test "the live eval gate excludes other recipients, accounts and unlabelled threads" do
    config = [
      delegations_enabled: true,
      delegation_user_allowlist: ["kent@runner.now"],
      delegation_sends_enabled: %{gmail: true},
      delegation_eval_only: true
    ]

    originals = Map.new(config, fn {key, _} -> {key, Application.get_env(:maraithon, key)} end)
    Enum.each(config, fn {key, value} -> Application.put_env(:maraithon, key, value) end)

    on_exit(fn ->
      Enum.each(originals, fn {key, value} ->
        if value == nil,
          do: Application.delete_env(:maraithon, key),
          else: Application.put_env(:maraithon, key, value)
      end)
    end)

    d = %{user_id: "kent@runner.now", provider: "gmail"}

    scope = %{
      "identity" => %{"email" => "kent@runner.now"},
      "subject" => "[Maraithon eval] test",
      "to" => ["kent.fenwick@gmail.com"],
      "cc" => []
    }

    grant = %{data: %{"scope" => scope}}
    assert Gates.scope_enabled?(d, grant)

    for changed <- [
          %{"to" => ["charlie@example.invalid"]},
          %{"cc" => ["other@example.invalid"]},
          %{"first_send_cc" => ["other@example.invalid"]},
          %{"identity" => %{"email" => "someone@example.invalid"}},
          %{"subject" => "A real project"}
        ] do
      refute Gates.scope_enabled?(d, %{data: %{"scope" => Map.merge(scope, changed)}})
    end

    refute Gates.scope_enabled?(%{d | user_id: "someone@example.invalid"}, grant)
  end
end
