defmodule Maraithon.Push.NotifierTest do
  use Maraithon.DataCase, async: false

  alias Maraithon.Accounts
  alias Maraithon.Push.APNS
  alias Maraithon.Push.Devices
  alias Maraithon.Push.Notifier

  defmodule OkHTTP do
    def post(url, _headers, body) do
      recipient = Application.fetch_env!(:maraithon, :apns) |> Keyword.fetch!(:test_pid)
      send(recipient, {:apns_sent, url, Jason.decode!(body)})
      {:ok, 200, ""}
    end
  end

  defmodule GoneHTTP do
    def post(_url, _headers, _body), do: {:ok, 410, ~s({"reason":"Unregistered"})}
  end

  defmodule RejectedHTTP do
    def post(_url, _headers, _body), do: {:ok, 429, ~s({"reason":"TooManyRequests"})}
  end

  defmodule UnknownHTTP do
    def post(_url, _headers, _body), do: {:error, :closed}
  end

  setup do
    previous = Application.get_env(:maraithon, :apns, [])

    ec_key = :public_key.generate_key({:namedCurve, {1, 2, 840, 10_045, 3, 1, 7}})
    pem = :public_key.pem_encode([:public_key.pem_entry_encode(:ECPrivateKey, ec_key)])

    Application.put_env(:maraithon, :apns,
      team_id: "TEAM123456",
      key_id: "KEY1234567",
      private_key: pem,
      http_module: OkHTTP,
      test_pid: self()
    )

    APNS.reset_jwt_cache()

    on_exit(fn ->
      APNS.reset_jwt_cache()
      Application.put_env(:maraithon, :apns, previous)
    end)

    email = "push-notifier-#{System.unique_integer([:positive])}@example.com"
    {:ok, user} = Accounts.get_or_create_user_by_email(email)
    %{user_id: user.id}
  end

  test "enabled_for_user? requires a registered active device", %{user_id: user_id} do
    refute Notifier.enabled_for_user?(user_id)

    {:ok, _device} = Devices.register(user_id, %{device_token: String.duplicate("a", 64)})
    assert Notifier.enabled_for_user?(user_id)
  end

  test "notify fans out to active devices with the alert payload", %{user_id: user_id} do
    {:ok, _} = Devices.register(user_id, %{device_token: String.duplicate("a", 64)})
    {:ok, _} = Devices.register(user_id, %{device_token: String.duplicate("b", 64)})

    assert {:ok, 2} =
             Notifier.notify(user_id, %{
               title: "Hello",
               body: "World",
               deeplink: "maraithon://today"
             })

    assert_receive {:apns_sent, _url, %{"aps" => %{"alert" => %{"title" => "Hello"}}}}
    assert_receive {:apns_sent, _url, _payload}
  end

  test "notify prunes tokens APNs reports unregistered", %{user_id: user_id} do
    token = String.duplicate("c", 64)
    {:ok, _} = Devices.register(user_id, %{device_token: token})

    Application.put_env(
      :maraithon,
      :apns,
      Keyword.put(Application.get_env(:maraithon, :apns), :http_module, GoneHTTP)
    )

    assert {:error, :no_devices} = Notifier.notify(user_id, %{title: "x", body: "y"})
    assert Devices.active_for_user(user_id) == []
    refute Notifier.enabled_for_user?(user_id)
  end

  test "notify distinguishes definitive rejection from ambiguous transport loss", %{
    user_id: user_id
  } do
    {:ok, _} = Devices.register(user_id, %{device_token: String.duplicate("7", 64)})
    original = Application.get_env(:maraithon, :apns)

    Application.put_env(
      :maraithon,
      :apns,
      Keyword.put(original, :http_module, RejectedHTTP)
    )

    assert {:error, :undelivered} = Notifier.notify(user_id, %{title: "x", body: "y"})

    Application.put_env(
      :maraithon,
      :apns,
      Keyword.put(original, :http_module, UnknownHTTP)
    )

    assert {:error, :delivery_unknown} =
             Notifier.notify(user_id, %{title: "x", body: "y"})
  end

  test "re-registering a disabled token reactivates it", %{user_id: user_id} do
    token = String.duplicate("d", 64)
    {:ok, device} = Devices.register(user_id, %{device_token: token})
    {:ok, _} = Devices.disable(device)
    refute Notifier.enabled_for_user?(user_id)

    {:ok, _} = Devices.register(user_id, %{device_token: token})
    assert Notifier.enabled_for_user?(user_id)
  end

  test "a token moves to the user who registers it last", %{user_id: user_id} do
    other_email = "push-notifier-other-#{System.unique_integer([:positive])}@example.com"
    {:ok, other} = Accounts.get_or_create_user_by_email(other_email)

    token = String.duplicate("e", 64)
    {:ok, _} = Devices.register(other.id, %{device_token: token})
    {:ok, _} = Devices.register(user_id, %{device_token: token})

    assert [device] = Devices.active_for_user(user_id)
    assert device.device_token == token
    assert Devices.active_for_user(other.id) == []
  end

  test "kill switch disables the channel", %{user_id: user_id} do
    {:ok, _} = Devices.register(user_id, %{device_token: String.duplicate("f", 64)})

    previous = Application.get_env(:maraithon, :mobile_push, [])
    Application.put_env(:maraithon, :mobile_push, enabled: false)
    on_exit(fn -> Application.put_env(:maraithon, :mobile_push, previous) end)

    refute Notifier.enabled_for_user?(user_id)
  end
end
