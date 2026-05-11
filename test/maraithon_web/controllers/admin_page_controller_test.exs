defmodule MaraithonWeb.AdminPageControllerTest do
  use MaraithonWeb.ConnCase, async: true

  alias Maraithon.Accounts
  alias Maraithon.Companion.Devices
  alias Maraithon.LocalMessages

  defp sample_message(guid) do
    %{
      "local_id" => "p:#{guid}",
      "guid" => guid,
      "service" => "iMessage",
      "is_from_me" => false,
      "sender_handle" => "+1",
      "chat_handles" => ["+1"],
      "chat_style" => "im",
      "text" => "hi",
      "sent_at" => "2026-05-10T13:14:22Z",
      "has_attachments" => false,
      "attachments" => []
    }
  end

  describe "GET /admin/companion-devices" do
    test "renders the paired-devices table for the signed-in admin", %{conn: conn} do
      email = "admin-devices-#{System.unique_integer([:positive])}@example.com"
      {:ok, user} = Accounts.get_or_create_user_by_email(email)

      {:ok, %{device: device}} =
        Devices.register(user.id, Ecto.UUID.generate(), device_name: "Studio Mac")

      {:ok, _} =
        LocalMessages.ingest_batch(user.id, device.device_id, [
          sample_message("admin-g1"),
          sample_message("admin-g2")
        ])

      conn =
        conn
        |> log_in_admin_user(email)
        |> get(~p"/admin/companion-devices")

      body = html_response(conn, 200)
      assert body =~ "Paired devices"
      assert body =~ "Studio Mac"
      assert body =~ device.device_id
      # The messages count cell holds "2" in the same row as the device name.
      # We pull just the messages-column cells out so the assertion is robust
      # to surrounding whitespace.
      assert Regex.scan(~r/tabular-nums">\s*2\s*</, body) != []
    end

    test "shows an empty state when no devices are paired", %{conn: conn} do
      email = "admin-empty-#{System.unique_integer([:positive])}@example.com"
      {:ok, _user} = Accounts.get_or_create_user_by_email(email)

      conn =
        conn
        |> log_in_admin_user(email)
        |> get(~p"/admin/companion-devices")

      body = html_response(conn, 200)
      assert body =~ "No devices are paired"
    end
  end
end
