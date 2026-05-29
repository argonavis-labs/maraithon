defmodule MaraithonWeb.MemoriesLiveTest do
  use MaraithonWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Maraithon.Memory

  @user_email "memories-live@example.com"

  setup %{conn: conn} do
    {:ok, conn: log_in_test_user(conn, @user_email)}
  end

  test "renders memory rows and highlights the Memory nav", %{conn: conn} do
    {:ok, memory} =
      Memory.write(@user_email, %{
        "kind" => "preference",
        "title" => "School notices matter",
        "content" => "Surface school notices when they affect pickup or forms.",
        "source" => "telegram",
        "source_ref_type" => "telegram_message",
        "source_ref_id" => "telegram-secret-message-123",
        "importance" => 97,
        "decay_at" => ~U[2026-06-01 12:00:00Z],
        "confidence" => 0.97
      })

    {:ok, view, html} = live(conn, "/operator/memories?id=#{memory.id}")

    assert html =~ "Saved context"
    assert html =~ "School notices matter"
    assert html =~ "Learned from Telegram"
    assert html =~ "Linked message available"
    assert html =~ "What Maraithon remembers"
    assert has_element?(view, "a[href='/operator/memories'][aria-current='page']", "Memory")
    refute html =~ "Durable memories"
    refute html =~ "Provenance"
    refute html =~ "Importance"
    refute html =~ "Decay"
    refute html =~ "telegram-secret-message-123"
    refute html =~ "Confidence"
    refute html =~ "97%"
  end

  test "filters, displays supersession chain, and archives an active memory", %{conn: conn} do
    {:ok, old} =
      Memory.write(@user_email, %{
        "kind" => "preference",
        "title" => "Charlie channel",
        "content" => "Charlie prefers Slack.",
        "dedupe_key" => "memories-live:charlie"
      })

    {:ok, replacement} =
      Memory.write(@user_email, %{
        "kind" => "preference",
        "title" => "Charlie channel",
        "content" => "Charlie now prefers email.",
        "dedupe_key" => "memories-live:charlie",
        "supersedes_id" => old.id
      })

    {:ok, view, _html} = live(conn, "/operator/memories?status=all&id=#{replacement.id}")

    html = render(view)
    assert html =~ "Charlie now prefers email."
    assert html =~ "Charlie prefers Slack."
    assert html =~ "Change history"
    assert html =~ "Updated by newer context"
    refute html =~ "Supersession chain"

    view
    |> form("#memory-filters", filters: %{"q" => "Charlie", "status" => "active"})
    |> render_change()

    assert_patch(view, "/operator/memories?q=Charlie&status=active")

    view
    |> element("button[phx-click=archive_memory][phx-value-id='#{replacement.id}']", "Archive")
    |> render_click()

    assert Memory.get_item_for_user(@user_email, replacement.id).status == "archived"
    assert render(view) =~ "Memory archived"
  end
end
