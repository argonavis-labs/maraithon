defmodule MaraithonWeb.ActivityLiveTest do
  use MaraithonWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Maraithon.Accounts
  alias Maraithon.ActionLedger
  alias Maraithon.Crm
  alias Maraithon.Memory
  alias Maraithon.TelegramAssistant
  alias Maraithon.Todos

  @user_email "activity-live@example.com"

  setup %{conn: conn} do
    {:ok, _user} = Accounts.get_or_create_user_by_email(@user_email)
    {:ok, conn: log_in_test_user(conn, @user_email)}
  end

  test "renders today's rollups, notable rows, and highlights the Activity nav", %{conn: conn} do
    {:ok, [_todo]} =
      Todos.upsert_many(@user_email, [
        %{
          "source" => "manual",
          "kind" => "general",
          "title" => "Send the Acme proposal",
          "dedupe_key" => "activity-live-todo"
        }
      ])

    {:ok, _memory} =
      Memory.write(@user_email, %{
        "content" => "Prefers async updates over calls.",
        "kind" => "preference"
      })

    {:ok, _person} = Crm.create_person(@user_email, %{"display_name" => "Dana Lee"})

    dedupe_key = "activity-live-ping"

    {:ok, _action} =
      ActionLedger.record(%{
        user_id: @user_email,
        surface: "telegram",
        event_type: "proactive.sent",
        status: "sent",
        source_evidence: %{"dedupe_key" => dedupe_key},
        model_summary: "Acme's renewal is due Friday and nobody has replied.",
        result_object_refs: %{"dedupe_key" => dedupe_key}
      })

    {:ok, _receipt} =
      TelegramAssistant.record_push_receipt(%{
        user_id: @user_email,
        dedupe_key: dedupe_key,
        origin_type: "insight",
        decision: "sent_now"
      })

    {:ok, _held_action} =
      ActionLedger.record(%{
        user_id: @user_email,
        surface: "telegram",
        event_type: "proactive.held",
        status: "held",
        model_summary: "Held a low-urgency nudge during quiet hours.",
        metadata: %{"hold_reason" => "quiet_hours"}
      })

    {:ok, _view, html} = live(conn, "/activity")

    assert html =~ "What did Maraithon do?"
    assert html =~ "Send the Acme proposal"
    assert html =~ "Dana Lee"
    assert html =~ "Acme&#39;s renewal is due Friday" or html =~ "Acme's renewal is due Friday"
    assert html =~ "quiet hours"
    assert html =~ ~s(aria-current="page")
  end

  test "the yesterday link switches the shown period", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/activity")

    view
    |> element("a", "Yesterday")
    |> render_click()

    assert_patch(view, "/activity?day=yesterday")
    assert render(view) =~ "Showing yesterday"
  end
end
