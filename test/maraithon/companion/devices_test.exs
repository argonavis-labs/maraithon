defmodule Maraithon.Companion.DevicesTest do
  use Maraithon.DataCase, async: true

  alias Maraithon.Accounts
  alias Maraithon.Companion.Device
  alias Maraithon.Companion.Devices

  defp create_user(email) do
    {:ok, user} = Accounts.get_or_create_user_by_email(email)
    user
  end

  describe "register/3" do
    test "creates a new device row with a hashed token and bumps last_seen_at" do
      user = create_user("devices-register-#{System.unique_integer([:positive])}@example.com")
      device_id = Ecto.UUID.generate()

      {:ok, %{device: device, token: token}} =
        Devices.register(user.id, device_id, device_name: "Kent's Mac")

      assert device.user_id == user.id
      assert device.device_id == device_id
      assert device.device_name == "Kent's Mac"
      assert is_binary(token)
      assert byte_size(token) > 16
      assert device.token_hash == Devices.hash_token(token)
      assert device.last_seen_at
      refute device.revoked_at
    end

    test "is idempotent on (user, device): rotates the token and clears revoked_at" do
      user = create_user("devices-rotate-#{System.unique_integer([:positive])}@example.com")
      device_id = Ecto.UUID.generate()

      {:ok, %{token: token_a, device: device_a}} = Devices.register(user.id, device_id)
      {:ok, _} = Devices.revoke(user.id, device_a.id)
      {:ok, %{token: token_b, device: device_b}} = Devices.register(user.id, device_id)

      assert device_a.id == device_b.id
      assert token_a != token_b
      refute device_b.revoked_at
      assert device_b.token_hash == Devices.hash_token(token_b)
    end
  end

  describe "verify_token/1" do
    test "returns the device for an active token" do
      user = create_user("devices-verify-#{System.unique_integer([:positive])}@example.com")
      {:ok, %{device: device, token: token}} = Devices.register(user.id, Ecto.UUID.generate())

      assert %Device{id: id} = Devices.verify_token(token)
      assert id == device.id
    end

    test "returns nil for a revoked device" do
      user = create_user("devices-revoke-#{System.unique_integer([:positive])}@example.com")
      {:ok, %{device: device, token: token}} = Devices.register(user.id, Ecto.UUID.generate())

      {:ok, _} = Devices.revoke(user.id, device.id)

      assert is_nil(Devices.verify_token(token))
    end

    test "returns nil for unknown or empty tokens" do
      assert is_nil(Devices.verify_token("does-not-exist"))
      assert is_nil(Devices.verify_token(""))
      assert is_nil(Devices.verify_token(nil))
    end
  end

  describe "touch_last_seen/1" do
    test "moves last_seen_at forward" do
      user = create_user("devices-touch-#{System.unique_integer([:positive])}@example.com")
      {:ok, %{device: device}} = Devices.register(user.id, Ecto.UUID.generate())

      :timer.sleep(5)
      touched = Devices.touch_last_seen(device)

      assert DateTime.compare(touched.last_seen_at, device.last_seen_at) == :gt
    end
  end

  describe "list_for_user/1" do
    test "returns rows for a user (including revoked) sorted by recency" do
      user = create_user("devices-list-#{System.unique_integer([:positive])}@example.com")
      {:ok, %{device: a}} = Devices.register(user.id, Ecto.UUID.generate())
      {:ok, %{device: b}} = Devices.register(user.id, Ecto.UUID.generate())

      list = Devices.list_for_user(user.id)
      ids = Enum.map(list, & &1.id)

      assert a.id in ids
      assert b.id in ids
    end
  end
end
