defmodule MaraithonWeb.OperationFailureCopyTest do
  use ExUnit.Case, async: true

  alias MaraithonWeb.OperationFailureCopy

  @internal_reason {:db, :timeout, [query: "select * from oauth_tokens"]}

  test "connector disconnect copy keeps the provider and hides internals" do
    copy = OperationFailureCopy.disconnect("GitHub", @internal_reason)

    assert copy == "Could not disconnect GitHub. Refresh the page and try again."
    refute_leaks_internal_reason(copy)
  end

  test "connector disconnect copy falls back when the label is empty" do
    assert OperationFailureCopy.disconnect("  ", @internal_reason) ==
             "Could not disconnect that app. Refresh the page and try again."
  end

  test "dashboard project copy hides internal reasons" do
    copies = [
      OperationFailureCopy.project(:create, @internal_reason),
      OperationFailureCopy.project(:memory, @internal_reason),
      OperationFailureCopy.project(:recommendation_decision, @internal_reason),
      OperationFailureCopy.project(:repo_access, @internal_reason),
      OperationFailureCopy.project(:implementation_run, @internal_reason)
    ]

    assert "Could not create that project. Review the details and try again." in copies
    assert "Could not start that delivery work. Refresh the dashboard and try again." in copies

    Enum.each(copies, &refute_leaks_internal_reason/1)
  end

  test "project validation copy is display-ready" do
    changeset =
      {%{}, %{name: :string}}
      |> Ecto.Changeset.cast(%{}, [:name])
      |> Ecto.Changeset.validate_required([:name])

    assert OperationFailureCopy.project(:create, changeset) ==
             "Could not create that project. Name can't be blank."
  end

  test "insight and relationship copy hides internal reasons" do
    copies = [
      OperationFailureCopy.insight(:acknowledge, @internal_reason),
      OperationFailureCopy.insight(:dismiss, @internal_reason),
      OperationFailureCopy.insight(:snooze, @internal_reason),
      OperationFailureCopy.insight_delivery(@internal_reason),
      OperationFailureCopy.relationship(:apply, @internal_reason)
    ]

    assert "Could not apply that relationship suggestion. Refresh insights and try again." in copies
    assert "Delivery failed. Check the connected channel and try again." in copies

    Enum.each(copies, &refute_leaks_internal_reason/1)
  end

  test "inline dashboard error copy hides internal reasons" do
    copies = [
      OperationFailureCopy.onboarding_preview(@internal_reason),
      OperationFailureCopy.fly_logs(@internal_reason),
      OperationFailureCopy.memory(:archive, @internal_reason)
    ]

    assert "Could not fetch platform logs right now. Refresh the logs and try again." in copies

    Enum.each(copies, &refute_leaks_internal_reason/1)
  end

  test "briefing schedule copy is actionable and hides internals" do
    assert OperationFailureCopy.briefing_schedule(:morning, :invalid_local_hour) ==
             "Choose a valid morning briefing time."

    assert OperationFailureCopy.briefing_schedule(:morning, :invalid_local_minute) ==
             "Choose a valid morning briefing minute."

    assert OperationFailureCopy.briefing_schedule(:morning, :no_briefing_agents) ==
             "Install Chief of Staff before changing the morning briefing schedule."

    copy =
      OperationFailureCopy.briefing_schedule(
        :morning,
        "DBConnection.ConnectionError: token abc123"
      )

    assert copy ==
             "Could not save the morning briefing time. Refresh Chief of Staff and try again."

    refute copy =~ "DBConnection"
    refute copy =~ "token"
    refute copy =~ "abc123"
    refute copy =~ "agent"
  end

  test "admin API copy hides internal reasons" do
    copies = [
      OperationFailureCopy.admin(:diagnostics_export, @internal_reason),
      OperationFailureCopy.admin(:fly_logs, @internal_reason),
      OperationFailureCopy.admin(:gmail_recent, "google_account_not_connected"),
      OperationFailureCopy.admin(:todo_dismiss, @internal_reason),
      OperationFailureCopy.admin(:reset_operator_state, @internal_reason),
      OperationFailureCopy.admin(:telegram_push, @internal_reason),
      OperationFailureCopy.admin(:chief_of_staff_ensure, @internal_reason),
      OperationFailureCopy.admin(:disconnect_connection, @internal_reason)
    ]

    assert "Could not fetch recent Gmail messages. Check the Google connection and try again." in copies
    assert "Could not dismiss this work item. Refresh the list and try again." in copies
    assert "Could not refresh Chief of Staff setup. Refresh the page and try again." in copies

    Enum.each(copies, &refute_leaks_internal_reason/1)
    refute Enum.any?(copies, &String.contains?(&1, "google_account_not_connected"))
    refute Enum.any?(copies, &String.contains?(&1, "todo"))
    refute Enum.any?(copies, &String.contains?(&1, "agents"))
  end

  defp refute_leaks_internal_reason(copy) do
    refute copy =~ "db"
    refute copy =~ "timeout"
    refute copy =~ "oauth_tokens"
    refute copy =~ "{"
    refute copy =~ "["
  end
end
