defmodule Maraithon.LocalRemindersTest do
  use Maraithon.DataCase, async: true

  alias Maraithon.LocalReminders
  alias Maraithon.LocalReminders.LocalReminder
  alias Maraithon.Repo

  defp sample_reminder(guid, overrides \\ %{}) do
    Map.merge(
      %{
        "local_id" => "r:1",
        "guid" => guid,
        "title" => "Buy milk",
        "notes" => nil,
        "list_name" => "Personal",
        "list_color" => "#FF3B30",
        "priority" => 0,
        "due_at" => "2026-05-12T10:00:00Z",
        "is_completed" => false,
        "has_alarm" => false,
        "url_attachment" => nil,
        "created_at" => "2026-05-09T08:00:00Z",
        "modified_at" => "2026-05-10T13:14:22Z"
      },
      overrides
    )
  end

  defp reminders_for(user_id, device_id) do
    Repo.all(
      from reminder in LocalReminder,
        where: reminder.user_id == ^user_id and reminder.device_id == ^device_id
    )
  end

  defp reminder_count(user_id, device_id) do
    Repo.aggregate(
      from(reminder in LocalReminder,
        where: reminder.user_id == ^user_id and reminder.device_id == ^device_id
      ),
      :count,
      :id
    )
  end

  describe "ingest_batch/3" do
    test "inserts a fresh batch and reports accepted counts" do
      user_id = "rem-ingest-#{System.unique_integer([:positive])}@example.com"
      device_id = Ecto.UUID.generate()

      reminders =
        for i <- 1..3 do
          sample_reminder("guid-#{i}", %{"title" => "task #{i}"})
        end

      {:ok, %{accepted: 3, duplicate: 0, invalid: 0}} =
        LocalReminders.ingest_batch(user_id, device_id, reminders)

      stored = reminders_for(user_id, device_id)
      assert length(stored) == 3
      assert Enum.all?(stored, &(&1.user_id == user_id))
      assert Enum.all?(stored, &(&1.title in ["task 1", "task 2", "task 3"]))
    end

    test "upserts on re-send and reflects new completion state" do
      user_id = "rem-upsert-#{System.unique_integer([:positive])}@example.com"
      device_id = Ecto.UUID.generate()

      [reminder] = [sample_reminder("rg-1")]

      {:ok, %{accepted: 1}} = LocalReminders.ingest_batch(user_id, device_id, [reminder])

      # Re-send with completion flipped.
      updated =
        sample_reminder("rg-1", %{
          "is_completed" => true,
          "completed_at" => "2026-05-10T14:00:00Z",
          "title" => "Buy milk (done)"
        })

      {:ok, _} = LocalReminders.ingest_batch(user_id, device_id, [updated])

      assert reminder_count(user_id, device_id) == 1
      [stored] = reminders_for(user_id, device_id)
      assert stored.is_completed == true
      assert stored.title == "Buy milk (done)"
      assert %DateTime{} = stored.completed_at
    end

    test "applies the default source when omitted" do
      user_id = "rem-source-#{System.unique_integer([:positive])}@example.com"
      device_id = Ecto.UUID.generate()

      {:ok, _} =
        LocalReminders.ingest_batch(user_id, device_id, [
          sample_reminder("g1") |> Map.delete("source")
        ])

      [stored] = reminders_for(user_id, device_id)
      assert stored.source == "reminders"
    end

    test "clamps priority to 0..9 and defaults to 0 when missing" do
      user_id = "rem-prio-#{System.unique_integer([:positive])}@example.com"
      device_id = Ecto.UUID.generate()

      {:ok, _} =
        LocalReminders.ingest_batch(user_id, device_id, [
          sample_reminder("p-default") |> Map.delete("priority"),
          sample_reminder("p-high", %{"priority" => 1}),
          sample_reminder("p-overflow", %{"priority" => 50}),
          sample_reminder("p-negative", %{"priority" => -2})
        ])

      stored = reminders_for(user_id, device_id) |> Map.new(&{&1.guid, &1.priority})
      assert stored["p-default"] == 0
      assert stored["p-high"] == 1
      assert stored["p-overflow"] == 9
      assert stored["p-negative"] == 0
    end

    test "rejects non-list input" do
      assert {:error, :invalid_batch} =
               LocalReminders.ingest_batch("u", Ecto.UUID.generate(), "x")
    end
  end

  describe "open_reminders/2" do
    test "returns only incomplete reminders ordered by due date then priority" do
      user_id = "rem-open-#{System.unique_integer([:positive])}@example.com"
      device_id = Ecto.UUID.generate()

      {:ok, _} =
        LocalReminders.ingest_batch(user_id, device_id, [
          sample_reminder("a", %{
            "title" => "later",
            "due_at" => "2026-05-15T10:00:00Z",
            "priority" => 0
          }),
          sample_reminder("b", %{
            "title" => "soon high",
            "due_at" => "2026-05-12T10:00:00Z",
            "priority" => 1
          }),
          sample_reminder("c", %{
            "title" => "soon med",
            "due_at" => "2026-05-12T10:00:00Z",
            "priority" => 5
          }),
          sample_reminder("d", %{
            "title" => "completed",
            "is_completed" => true,
            "completed_at" => "2026-05-10T11:00:00Z"
          })
        ])

      open = LocalReminders.open_reminders(user_id)
      assert Enum.map(open, & &1.title) == ["soon high", "soon med", "later"]
      refute Enum.any?(open, &(&1.title == "completed"))
    end

    test "filters by list_name (case-insensitive)" do
      user_id = "rem-open-list-#{System.unique_integer([:positive])}@example.com"
      device_id = Ecto.UUID.generate()

      {:ok, _} =
        LocalReminders.ingest_batch(user_id, device_id, [
          sample_reminder("g1", %{"list_name" => "Work", "title" => "ship"}),
          sample_reminder("g2", %{"list_name" => "Personal", "title" => "shop"})
        ])

      [only_work] = LocalReminders.open_reminders(user_id, list_name: "work")
      assert only_work.title == "ship"
    end

    test "honors the limit option" do
      user_id = "rem-open-limit-#{System.unique_integer([:positive])}@example.com"
      device_id = Ecto.UUID.generate()

      reminders =
        for i <- 1..5 do
          sample_reminder("g-#{i}", %{
            "title" => "open #{i}",
            "due_at" => "2026-05-1#{i}T10:00:00Z"
          })
        end

      {:ok, _} = LocalReminders.ingest_batch(user_id, device_id, reminders)

      assert length(LocalReminders.open_reminders(user_id, limit: 2)) == 2
    end
  end

  describe "due_soon/2" do
    test "returns open reminders due within the window, including overdue" do
      user_id = "rem-due-#{System.unique_integer([:positive])}@example.com"
      device_id = Ecto.UUID.generate()

      now = DateTime.utc_now()
      overdue_at = now |> DateTime.add(-3 * 86_400, :second) |> DateTime.to_iso8601()
      soon_at = now |> DateTime.add(2 * 86_400, :second) |> DateTime.to_iso8601()
      far_at = now |> DateTime.add(30 * 86_400, :second) |> DateTime.to_iso8601()

      {:ok, _} =
        LocalReminders.ingest_batch(user_id, device_id, [
          sample_reminder("over", %{"title" => "overdue", "due_at" => overdue_at}),
          sample_reminder("soon", %{"title" => "soon", "due_at" => soon_at}),
          sample_reminder("far", %{"title" => "far", "due_at" => far_at}),
          sample_reminder("none", %{"title" => "no due", "due_at" => nil}),
          sample_reminder("done", %{
            "title" => "done already",
            "due_at" => soon_at,
            "is_completed" => true
          })
        ])

      titles = LocalReminders.due_soon(user_id, days_ahead: 7) |> Enum.map(& &1.title)
      assert "overdue" in titles
      assert "soon" in titles
      refute "far" in titles
      refute "no due" in titles
      refute "done already" in titles
      # Overdue should be ordered before soon (asc by due_at).
      assert Enum.find_index(titles, &(&1 == "overdue")) <
               Enum.find_index(titles, &(&1 == "soon"))
    end
  end

  describe "recent_completed/2" do
    test "returns only completed reminders, newest completed first" do
      user_id = "rem-rc-#{System.unique_integer([:positive])}@example.com"
      device_id = Ecto.UUID.generate()

      {:ok, _} =
        LocalReminders.ingest_batch(user_id, device_id, [
          sample_reminder("a", %{
            "title" => "older done",
            "is_completed" => true,
            "completed_at" => "2026-05-09T10:00:00Z"
          }),
          sample_reminder("b", %{
            "title" => "newer done",
            "is_completed" => true,
            "completed_at" => "2026-05-10T10:00:00Z"
          }),
          sample_reminder("c", %{"title" => "open"})
        ])

      recent = LocalReminders.recent_completed(user_id)
      assert Enum.map(recent, & &1.title) == ["newer done", "older done"]
    end
  end

  describe "search/3" do
    test "matches substring on title, notes, and list_name" do
      user_id = "rem-search-#{System.unique_integer([:positive])}@example.com"
      device_id = Ecto.UUID.generate()

      {:ok, _} =
        LocalReminders.ingest_batch(user_id, device_id, [
          sample_reminder("g1", %{"title" => "Pick up passport", "list_name" => "Travel"}),
          sample_reminder("g2", %{
            "title" => "Call dentist",
            "notes" => "ask about whitening",
            "list_name" => "Health"
          }),
          sample_reminder("g3", %{"title" => "Run errands", "list_name" => "Personal"})
        ])

      assert [%{title: "Pick up passport"}] = LocalReminders.search(user_id, "passport")
      assert [%{title: "Call dentist"}] = LocalReminders.search(user_id, "WHITENING")
      assert length(LocalReminders.search(user_id, "personal")) == 1
    end
  end

  describe "get_by_guid/2" do
    test "returns the matching reminder or nil" do
      user_id = "rem-get-#{System.unique_integer([:positive])}@example.com"
      device_id = Ecto.UUID.generate()

      {:ok, _} =
        LocalReminders.ingest_batch(user_id, device_id, [
          sample_reminder("found-it", %{"title" => "Hello"})
        ])

      assert %LocalReminder{title: "Hello"} = LocalReminders.get_by_guid(user_id, "found-it")
      assert nil == LocalReminders.get_by_guid(user_id, "missing")
    end
  end

  describe "purge_device/2" do
    test "removes all rows for the (user, device) pair" do
      user_id = "rem-purge-#{System.unique_integer([:positive])}@example.com"
      device_id = Ecto.UUID.generate()

      {:ok, _} =
        LocalReminders.ingest_batch(user_id, device_id, [
          sample_reminder("g1"),
          sample_reminder("g2")
        ])

      assert reminder_count(user_id, device_id) == 2
      {:ok, %{deleted: 2}} = LocalReminders.purge_device(user_id, device_id)
      assert reminder_count(user_id, device_id) == 0
    end
  end
end
