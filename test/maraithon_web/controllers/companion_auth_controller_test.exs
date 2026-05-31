defmodule MaraithonWeb.CompanionAuthControllerTest do
  use MaraithonWeb.ConnCase, async: true

  alias Maraithon.Companion.Device
  alias Maraithon.Companion.Devices
  alias Maraithon.Repo

  describe "GET /companion/auth" do
    test "renders the approve/deny consent screen for authenticated users", %{conn: conn} do
      device_id = Ecto.UUID.generate()

      conn =
        conn
        |> log_in_test_user("companion-auth-show@example.com")
        |> get("/companion/auth", %{device_id: device_id, device_name: "Kent's MacBook"})

      body = html_response(conn, 200)
      assert body =~ "Pair Companion app"
      assert body =~ "Kent&#39;s MacBook" or body =~ "Kent's MacBook"
      assert body =~ "will make local context from this Mac available to your assistant"
      assert body =~ "Only approve this request if it was opened from the Mac you are pairing"
      assert body =~ "Approve and connect"
      assert body =~ ~s(name="device_id")
      assert body =~ ~s(value="#{device_id}")
      refute body =~ "device_id:"
      refute body =~ "iMessages first"
      refute body =~ "sync local context"
    end

    test "redirects to / when device_id is missing or malformed", %{conn: conn} do
      conn =
        conn
        |> log_in_test_user("companion-auth-bad@example.com")
        |> get("/companion/auth", %{device_id: "not-a-uuid!!", device_name: "Bad"})

      assert redirected_to(conn) == "/"
    end

    test "redirects unauthenticated requests to the sign-in page", %{conn: conn} do
      device_id = Ecto.UUID.generate()
      conn = get(conn, "/companion/auth", %{device_id: device_id})
      assert redirected_to(conn) == "/"
    end
  end

  describe "POST /companion/auth/approve" do
    test "stores a hashed token and redirects to the maraithon:// URL", %{conn: conn} do
      email = "companion-approve-#{System.unique_integer([:positive])}@example.com"
      device_id = Ecto.UUID.generate()

      conn =
        conn
        |> log_in_test_user(email)
        |> post("/companion/auth/approve", %{
          device_id: device_id,
          device_name: "Kent's MacBook"
        })

      target = redirected_to(conn, 302)
      assert String.starts_with?(target, "maraithon://device-token/")

      "maraithon://device-token/" <> token = target

      assert %Device{} = device = Repo.get_by(Device, device_id: device_id)
      assert device.user_id == String.downcase(email)
      assert device.device_name == "Kent's MacBook"
      assert device.token_hash == Devices.hash_token(token)
      refute device.revoked_at
    end
  end

  describe "GET /companion/auth/denied" do
    test "renders the denial page and does not store a device", %{conn: conn} do
      device_id = Ecto.UUID.generate()

      conn =
        conn
        |> log_in_test_user("companion-deny@example.com")
        |> get("/companion/auth/denied", %{device_id: device_id})

      assert html_response(conn, 200) =~ "Pairing denied"
      assert is_nil(Repo.get_by(Device, device_id: device_id))
    end
  end
end
