defmodule MaraithonWeb.CompanionChannelTest do
  use MaraithonWeb.ChannelCase, async: false

  alias Maraithon.Accounts
  alias Maraithon.Companion.Devices
  alias Maraithon.LocalBrowserHistory.LocalVisit
  alias Maraithon.LocalMessages.LocalMessage
  alias Maraithon.LocalNotes.LocalNote
  alias Maraithon.LocalReminders.LocalReminder
  alias Maraithon.Repo
  alias MaraithonWeb.CompanionChannel
  alias MaraithonWeb.CompanionSocket

  import Ecto.Query

  defp pair_device(email \\ nil) do
    email = email || "channel-#{System.unique_integer([:positive])}@example.com"
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

  defp sample_note(guid, overrides \\ %{}) do
    Map.merge(
      %{
        "local_id" => "n:1",
        "guid" => guid,
        "title" => "Grocery list",
        "snippet" => "Milk, eggs, bread",
        "folder" => "Personal",
        "is_pinned" => false,
        "created_at" => "2026-05-09T08:00:00Z",
        "modified_at" => "2026-05-10T13:14:22Z"
      },
      overrides
    )
  end

  defp sample_reminder(guid, overrides \\ %{}) do
    Map.merge(
      %{
        "local_id" => "r:1",
        "guid" => guid,
        "title" => "Buy milk",
        "list_name" => "Personal",
        "priority" => 0,
        "due_at" => "2026-05-12T10:00:00Z",
        "is_completed" => false,
        "created_at" => "2026-05-09T08:00:00Z",
        "modified_at" => "2026-05-10T13:14:22Z"
      },
      overrides
    )
  end

  defp sample_visit(guid, overrides \\ %{}) do
    Map.merge(
      %{
        "local_id" => "v:#{guid}",
        "guid" => guid,
        "browser" => "chrome",
        "url" => "https://example.com/post-#{guid}",
        "title" => "Post #{guid}",
        "host" => "example.com",
        "visit_count" => 1,
        "is_typed_url" => false,
        "last_visited_at" => "2026-05-10T13:14:22Z"
      },
      overrides
    )
  end

  describe "connect/3" do
    test "rejects when no token is supplied" do
      assert :error = connect(CompanionSocket, %{})
    end

    test "rejects an invalid token" do
      assert :error = connect(CompanionSocket, %{"token" => "not-a-real-token"})
    end

    test "rejects a revoked token" do
      %{user: user, device: device, token: token} = pair_device()
      {:ok, _} = Devices.revoke(user.id, device.id)
      assert :error = connect(CompanionSocket, %{"token" => token})
    end

    test "connects with a valid token" do
      %{token: token} = pair_device()
      assert {:ok, socket} = connect(CompanionSocket, %{"token" => token})
      assert socket.assigns.current_device.device_id
      assert is_binary(socket.assigns.current_user_id)
    end
  end

  describe "join/3" do
    test "succeeds when device_id matches the token" do
      %{device: device, token: token} = pair_device()
      {:ok, socket} = connect(CompanionSocket, %{"token" => token})

      {:ok, reply, _socket} =
        subscribe_and_join(socket, CompanionChannel, "companion:device:#{device.device_id}")

      assert reply.device_id == device.device_id
    end

    test "rejects a topic that names a different device_id" do
      %{token: token} = pair_device()
      {:ok, socket} = connect(CompanionSocket, %{"token" => token})

      assert {:error, %{reason: "device_mismatch"}} =
               subscribe_and_join(
                 socket,
                 CompanionChannel,
                 "companion:device:#{Ecto.UUID.generate()}"
               )
    end
  end

  describe "handle_in/3 ingest:messages" do
    test "inserts messages and replies with counts" do
      %{user: user, device: device, token: token} = pair_device()
      {:ok, socket} = connect(CompanionSocket, %{"token" => token})

      {:ok, _reply, socket} =
        subscribe_and_join(socket, CompanionChannel, "companion:device:#{device.device_id}")

      ref =
        push(socket, "ingest:messages", %{
          "source" => "imessage",
          "messages" => [sample_message("g1"), sample_message("g2")]
        })

      assert_reply ref, :ok, %{accepted: 2, duplicate: 0, invalid: 0}

      count =
        Repo.aggregate(
          from(m in LocalMessage,
            where: m.user_id == ^user.id and m.device_id == ^device.device_id
          ),
          :count,
          :id
        )

      assert count == 2
    end

    test "idempotent on re-send: second push reports duplicates" do
      %{device: device, token: token} = pair_device()
      {:ok, socket} = connect(CompanionSocket, %{"token" => token})

      {:ok, _, socket} =
        subscribe_and_join(socket, CompanionChannel, "companion:device:#{device.device_id}")

      messages = [sample_message("g1"), sample_message("g2")]

      ref1 = push(socket, "ingest:messages", %{"messages" => messages})
      assert_reply ref1, :ok, %{accepted: 2, duplicate: 0}

      ref2 = push(socket, "ingest:messages", %{"messages" => messages})
      assert_reply ref2, :ok, %{accepted: 0, duplicate: 2}
    end

    test "replies with error when messages array is missing" do
      %{device: device, token: token} = pair_device()
      {:ok, socket} = connect(CompanionSocket, %{"token" => token})

      {:ok, _, socket} =
        subscribe_and_join(socket, CompanionChannel, "companion:device:#{device.device_id}")

      ref = push(socket, "ingest:messages", %{})
      assert_reply ref, :error, %{reason: "messages_required"}
    end
  end

  describe "handle_in/3 ingest:notes" do
    test "inserts notes and replies with counts" do
      %{user: user, device: device, token: token} = pair_device()
      {:ok, socket} = connect(CompanionSocket, %{"token" => token})

      {:ok, _, socket} =
        subscribe_and_join(socket, CompanionChannel, "companion:device:#{device.device_id}")

      ref = push(socket, "ingest:notes", %{"notes" => [sample_note("n1"), sample_note("n2")]})
      assert_reply ref, :ok, %{accepted: 2}

      count =
        Repo.aggregate(
          from(n in LocalNote,
            where: n.user_id == ^user.id and n.device_id == ^device.device_id
          ),
          :count,
          :id
        )

      assert count == 2
    end
  end

  describe "handle_in/3 ingest:reminders" do
    test "inserts reminders and replies with counts" do
      %{user: user, device: device, token: token} = pair_device()
      {:ok, socket} = connect(CompanionSocket, %{"token" => token})

      {:ok, _, socket} =
        subscribe_and_join(socket, CompanionChannel, "companion:device:#{device.device_id}")

      ref =
        push(socket, "ingest:reminders", %{
          "reminders" => [sample_reminder("r1"), sample_reminder("r2")]
        })

      assert_reply ref, :ok, %{accepted: 2, invalid: 0}

      count =
        Repo.aggregate(
          from(r in LocalReminder,
            where: r.user_id == ^user.id and r.device_id == ^device.device_id
          ),
          :count,
          :id
        )

      assert count == 2
    end
  end

  describe "handle_in/3 ingest:browser_history" do
    test "inserts visits and replies with the four-key counts" do
      %{user: user, device: device, token: token} = pair_device()
      {:ok, socket} = connect(CompanionSocket, %{"token" => token})

      {:ok, _, socket} =
        subscribe_and_join(socket, CompanionChannel, "companion:device:#{device.device_id}")

      ref =
        push(socket, "ingest:browser_history", %{
          "visits" => [sample_visit("g1"), sample_visit("g2")]
        })

      assert_reply ref, :ok, %{accepted: 2, duplicate: 0, invalid: 0, filtered: 0}

      count =
        Repo.aggregate(
          from(v in LocalVisit,
            where: v.user_id == ^user.id and v.device_id == ^device.device_id
          ),
          :count,
          :id
        )

      assert count == 2
    end
  end

  describe "handle_in/3 unknown events" do
    test "replies with unknown_event for events the channel doesn't handle" do
      %{device: device, token: token} = pair_device()
      {:ok, socket} = connect(CompanionSocket, %{"token" => token})

      {:ok, _, socket} =
        subscribe_and_join(socket, CompanionChannel, "companion:device:#{device.device_id}")

      ref = push(socket, "ingest:bogus", %{})
      assert_reply ref, :error, %{reason: "unknown_event"}
    end
  end
end
