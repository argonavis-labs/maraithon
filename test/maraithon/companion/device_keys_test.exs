defmodule Maraithon.Companion.DeviceKeysTest do
  use Maraithon.DataCase, async: true

  alias Maraithon.Accounts
  alias Maraithon.Companion.DeviceKey
  alias Maraithon.Companion.DeviceKeys
  alias Maraithon.Companion.Devices

  defp setup_device(email_prefix) do
    {:ok, user} =
      Accounts.get_or_create_user_by_email(
        "#{email_prefix}-#{System.unique_integer([:positive])}@example.com"
      )

    {:ok, %{device: device}} = Devices.register(user.id, Ecto.UUID.generate())
    %{user: user, device: device}
  end

  describe "upsert/3" do
    test "inserts a new row" do
      %{user: user, device: device} = setup_device("upsert-insert")

      {:ok, %DeviceKey{} = key} =
        DeviceKeys.upsert(user.id, device.device_id, %{
          key_id: "k1",
          public_key: "pubkey-bytes-base64"
        })

      assert key.user_id == user.id
      assert key.device_id == device.device_id
      assert key.key_id == "k1"
      assert key.public_key == "pubkey-bytes-base64"
      refute key.revoked_at
    end

    test "rotating: a second key_id creates a second row for the same device" do
      %{user: user, device: device} = setup_device("upsert-rotate")

      {:ok, _} = DeviceKeys.upsert(user.id, device.device_id, %{key_id: "k1", public_key: "p1"})
      {:ok, _} = DeviceKeys.upsert(user.id, device.device_id, %{key_id: "k2", public_key: "p2"})

      keys = DeviceKeys.list_for(user.id, device.device_id)
      assert length(keys) == 2
    end

    test "is idempotent on (user, device, key_id): refreshes public_key + clears revoked_at" do
      %{user: user, device: device} = setup_device("upsert-idempotent")

      {:ok, original} =
        DeviceKeys.upsert(user.id, device.device_id, %{key_id: "k1", public_key: "p1"})

      {:ok, _} = DeviceKeys.revoke(user.id, device.device_id, "k1")

      {:ok, refreshed} =
        DeviceKeys.upsert(user.id, device.device_id, %{key_id: "k1", public_key: "p1-updated"})

      assert refreshed.id == original.id
      assert refreshed.public_key == "p1-updated"
      refute refreshed.revoked_at
    end

    test "rejects empty key_id / public_key" do
      %{user: user, device: device} = setup_device("upsert-invalid")

      assert {:error, %Ecto.Changeset{}} =
               DeviceKeys.upsert(user.id, device.device_id, %{key_id: "", public_key: "p"})

      assert {:error, %Ecto.Changeset{}} =
               DeviceKeys.upsert(user.id, device.device_id, %{key_id: "k", public_key: ""})
    end
  end

  describe "current_for/2" do
    test "returns the newest non-revoked key" do
      %{user: user, device: device} = setup_device("current-newest")

      {:ok, _} = DeviceKeys.upsert(user.id, device.device_id, %{key_id: "k1", public_key: "p1"})
      # ensure timestamps order — sleep is acceptable in this single test
      :timer.sleep(5)
      {:ok, _} = DeviceKeys.upsert(user.id, device.device_id, %{key_id: "k2", public_key: "p2"})

      current = DeviceKeys.current_for(user.id, device.device_id)
      assert current.key_id == "k2"
    end

    test "skips revoked keys" do
      %{user: user, device: device} = setup_device("current-skip-revoked")

      {:ok, _} = DeviceKeys.upsert(user.id, device.device_id, %{key_id: "k1", public_key: "p1"})
      :timer.sleep(5)
      {:ok, _} = DeviceKeys.upsert(user.id, device.device_id, %{key_id: "k2", public_key: "p2"})
      {:ok, _} = DeviceKeys.revoke(user.id, device.device_id, "k2")

      current = DeviceKeys.current_for(user.id, device.device_id)
      assert current.key_id == "k1"
    end

    test "returns nil when there are no keys" do
      %{user: user, device: device} = setup_device("current-none")
      assert is_nil(DeviceKeys.current_for(user.id, device.device_id))
    end
  end

  describe "get_by_key_id/3" do
    test "fetches a specific key" do
      %{user: user, device: device} = setup_device("get-by-key")

      {:ok, _} = DeviceKeys.upsert(user.id, device.device_id, %{key_id: "k1", public_key: "p1"})

      key = DeviceKeys.get_by_key_id(user.id, device.device_id, "k1")
      assert key.key_id == "k1"

      assert is_nil(DeviceKeys.get_by_key_id(user.id, device.device_id, "missing"))
    end

    test "returns nil for bad args" do
      assert is_nil(DeviceKeys.get_by_key_id(nil, "x", "y"))
    end
  end

  describe "revoke/3" do
    test "marks a key revoked" do
      %{user: user, device: device} = setup_device("revoke")

      {:ok, _} = DeviceKeys.upsert(user.id, device.device_id, %{key_id: "k1", public_key: "p1"})
      {:ok, revoked} = DeviceKeys.revoke(user.id, device.device_id, "k1")

      assert revoked.revoked_at
    end

    test "returns :not_found for an unknown key" do
      %{user: user, device: device} = setup_device("revoke-missing")
      assert {:error, :not_found} = DeviceKeys.revoke(user.id, device.device_id, "missing")
    end
  end
end
