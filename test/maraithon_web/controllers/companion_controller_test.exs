defmodule MaraithonWeb.CompanionControllerTest do
  use MaraithonWeb.ConnCase, async: true

  alias Maraithon.Accounts
  alias Maraithon.Companion.Devices
  alias Maraithon.LocalMessages
  alias Maraithon.LocalMessages.LocalMessage
  alias Maraithon.Repo

  import Ecto.Query

  defp pair_device(email \\ nil) do
    email = email || "companion-#{System.unique_integer([:positive])}@example.com"
    {:ok, user} = Accounts.get_or_create_user_by_email(email)
    device_id = Ecto.UUID.generate()

    {:ok, %{device: device, token: token}} =
      Devices.register(user.id, device_id, device_name: "Kent's Mac")

    %{user: user, device: device, token: token}
  end

  defp sample_message(guid, overrides \\ %{}) do
    Map.merge(
      %{
        "local_id" => "p:1",
        "guid" => guid,
        "service" => "iMessage",
        "is_from_me" => false,
        "sender_handle" => "+14165550199",
        "chat_handles" => ["+14165550199"],
        "chat_style" => "im",
        "text" => "Coffee tomorrow?",
        "sent_at" => "2026-05-10T13:14:22Z",
        "has_attachments" => false,
        "attachments" => []
      },
      overrides
    )
  end

  defp message_count(user_id, device_id) do
    Repo.aggregate(
      from(message in LocalMessage,
        where: message.user_id == ^user_id and message.device_id == ^device_id
      ),
      :count,
      :id
    )
  end

  describe "POST /api/v1/companion/messages" do
    test "401 without bearer token", %{conn: conn} do
      conn = post(conn, "/api/v1/companion/messages", %{messages: []})
      assert json_response(conn, 401) == %{"error" => "unauthorized"}
    end

    test "401 for revoked device", %{conn: conn} do
      %{user: user, device: device, token: token} = pair_device()
      {:ok, _} = Devices.revoke(user.id, device.id)

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> post("/api/v1/companion/messages", %{messages: []})

      assert json_response(conn, 401) == %{"error" => "unauthorized"}
    end

    test "200 happy path: inserts messages and reports counts", %{conn: conn} do
      %{user: user, device: device, token: token} = pair_device()

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> post("/api/v1/companion/messages", %{
          "source" => "imessage",
          "messages" => [sample_message("g1"), sample_message("g2")]
        })

      body = json_response(conn, 200)
      assert body["accepted"] == 2
      assert body["duplicate"] == 0
      assert message_count(user.id, device.device_id) == 2
    end

    test "dedupes on the second send", %{conn: conn} do
      %{token: token} = pair_device()
      messages = [sample_message("g1"), sample_message("g2")]

      conn1 =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> post("/api/v1/companion/messages", %{"messages" => messages})

      assert json_response(conn1, 200)["accepted"] == 2

      conn2 =
        build_conn()
        |> put_req_header("authorization", "Bearer #{token}")
        |> post("/api/v1/companion/messages", %{"messages" => messages})

      body = json_response(conn2, 200)
      assert body["accepted"] == 0
      assert body["duplicate"] == 2
    end

    test "400 when messages is missing", %{conn: conn} do
      %{token: token} = pair_device()

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> post("/api/v1/companion/messages", %{})

      assert json_response(conn, 400)["error"] =~ "messages"
    end
  end

  describe "GET /api/v1/companion/whoami" do
    test "returns email + device metadata", %{conn: conn} do
      %{user: user, device: device, token: token} = pair_device()

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> get("/api/v1/companion/whoami")

      body = json_response(conn, 200)
      assert body["email"] == user.email
      assert body["device_name"] == device.device_name
      assert body["device_id"] == device.device_id
    end

    test "401 without token", %{conn: conn} do
      conn = get(conn, "/api/v1/companion/whoami")
      assert json_response(conn, 401)
    end
  end

  describe "DELETE /api/v1/companion/devices/:id/messages" do
    test "purges all messages for the device", %{conn: conn} do
      %{user: user, device: device, token: token} = pair_device()

      {:ok, _} =
        LocalMessages.ingest_batch(user.id, device.device_id, [
          sample_message("g1"),
          sample_message("g2")
        ])

      assert message_count(user.id, device.device_id) == 2

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> delete("/api/v1/companion/devices/#{device.id}/messages")

      body = json_response(conn, 200)
      assert body["deleted"] == 2
      assert message_count(user.id, device.device_id) == 0
    end
  end
end
