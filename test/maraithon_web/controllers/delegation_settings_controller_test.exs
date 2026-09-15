defmodule MaraithonWeb.DelegationSettingsControllerTest do
  use MaraithonWeb.ConnCase, async: false
  alias Maraithon.{Accounts, OAuth}
  alias Maraithon.Companion.Devices
  alias Maraithon.Delegations.Preferences

  test "Mac and iPhone use the same owned settings and choices", %{conn: conn} do
    user = "settings-device-#{Ecto.UUID.generate()}@example.invalid"
    other = "other-settings-#{Ecto.UUID.generate()}@example.invalid"
    {:ok, person} = Accounts.get_or_create_user_by_email(user)
    {:ok, _} = Accounts.get_or_create_user_by_email(other)
    {:ok, %{token: mobile}} = Accounts.create_session_for_user(person)

    {:ok, %{token: mac}} =
      Devices.register(user, Ecto.UUID.generate(), device_name: "Settings Mac")

    for email <- [user, other],
        do: OAuth.store_tokens(email, "google:#{email}", %{access_token: "must-not-leak"})

    previous =
      Map.new(
        [:delegations_enabled, :delegation_user_allowlist],
        &{&1, Application.fetch_env(:maraithon, &1)}
      )

    Application.put_env(:maraithon, :delegations_enabled, true)
    Application.put_env(:maraithon, :delegation_user_allowlist, [user])

    on_exit(fn ->
      Enum.each(previous, fn
        {key, {:ok, value}} -> Application.put_env(:maraithon, key, value)
        {key, :error} -> Application.delete_env(:maraithon, key)
      end)
    end)

    for {root, token, minutes} <- [{"/api/v1/companion", mac, 45}, {"/api/mobile", mobile, 60}] do
      c = recycle(conn) |> put_req_header("authorization", "Bearer #{token}")
      response = get(c, root <> "/delegation-settings")
      settings = json_response(response, 200)["settings"]
      assert settings["enabled"]
      assert [%{"label" => ^user}] = settings["accounts"]
      assert Enum.any?(settings["timezones"], &(&1["value"] == "America/Toronto"))
      assert Enum.any?(settings["numeric_preferences"], &(&1["key"] == "default_duration_min"))
      refute response.resp_body =~ "must-not-leak"
      refute response.resp_body =~ other

      saved =
        post(recycle(response), root <> "/delegation-settings/preferences", %{
          "user_id" => other,
          "default_duration_min" => minutes,
          "work_days" => [1, 3, 5],
          "proposals_enabled" => false
        })

      assert json_response(saved, 200)["settings"]["preferences"]["default_duration_min"] ==
               minutes

      assert Preferences.get(user)["work_days"] == [1, 3, 5]
      refute Preferences.get(other)["default_duration_min"] == minutes
    end
  end
end
