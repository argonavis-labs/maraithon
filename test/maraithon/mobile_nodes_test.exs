defmodule Maraithon.MobileNodesTest do
  use Maraithon.DataCase, async: true

  alias Maraithon.Accounts
  alias Maraithon.MobileNodes

  test "pairs devices with a one-time code and only authorizes narrow commands" do
    user_id = "mobile-#{System.unique_integer([:positive])}@example.com"
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

    assert {:ok, %{pairing: pairing, code: code}} =
             MobileNodes.create_pairing(user_id, allowed_commands: ["notify"])

    assert pairing.status == "pending"
    assert is_binary(code)
    refute inspect(pairing) =~ code

    assert {:ok, %{pairing: claimed_pairing, device: device}} =
             MobileNodes.claim_pairing(user_id, code, %{
               "device_id" => "iphone-15",
               "label" => "Kent iPhone",
               "platform" => "ios",
               "public_key_fingerprint" => "sha256:abc"
             })

    assert claimed_pairing.status == "claimed"
    assert claimed_pairing.claimed_device_id == "iphone-15"
    assert device.allowed_commands == ["notify"]

    assert {:ok, command} = MobileNodes.authorize_command(device, "notify", %{"title" => "Hello"})
    assert command.command == "notify"

    assert {:error, :mobile_command_not_granted} =
             MobileNodes.authorize_command(device, "open_url", %{})

    assert {:error, :forbidden_mobile_command} =
             MobileNodes.authorize_command(device, "shell", %{"cmd" => "whoami"})
  end

  test "rejects forbidden commands at pairing time" do
    user_id = "mobile-forbidden-#{System.unique_integer([:positive])}@example.com"
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

    assert {:error, :forbidden_mobile_command} =
             MobileNodes.create_pairing(user_id, allowed_commands: ["notify", "exec"])
  end
end
