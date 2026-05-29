defmodule Maraithon.TelegramAssistant.ActionFailureCopyTest do
  use ExUnit.Case, async: true

  alias Maraithon.TelegramAssistant.ActionFailureCopy

  test "keeps known connector failures actionable" do
    assert ActionFailureCopy.insight_action("linear_not_connected") =~
             "Connect Linear before creating the task"

    assert ActionFailureCopy.insight_action("google_account_reauth_required") =~
             "/connectors/google"
  end

  test "hides unknown insight action reasons" do
    copy = ActionFailureCopy.insight_action({:db, :timeout})

    assert copy ==
             "Could not complete that yet. Try again from the latest message or open Maraithon to review it."

    refute copy =~ ":db"
    refute copy =~ "timeout"
    refute copy =~ "I couldn't"
  end

  test "hides unknown todo callback reasons" do
    copy = ActionFailureCopy.todo_callback({:stale_row, :not_found})

    assert copy ==
             "Could not update that work item. Refresh the latest work message and try again."

    refute copy =~ "stale_row"
    refute copy =~ ":not_found"
    refute copy =~ "I couldn't"
  end

  test "keeps stale todo callback states specific" do
    assert ActionFailureCopy.todo_callback(:not_found) == "That work item is no longer available."

    assert ActionFailureCopy.todo_callback(:chat_mismatch) ==
             "This work item is not linked to this chat anymore."
  end

  test "tool errors keep known recovery states actionable" do
    assert ActionFailureCopy.tool_error("linear_not_connected") =~
             "Connect Linear before looking up issues"

    assert ActionFailureCopy.tool_error(:agent_not_found) ==
             "That automation is no longer available."

    assert ActionFailureCopy.tool_error("write_tools_disabled") ==
             "Action drafting is not enabled."
  end

  test "tool errors hide technical and code-like reasons" do
    reasons = [
      {:error, "DBConnection.ConnectionError token=secret stacktrace"},
      %{reason: :timeout, query: "select * from oauth_tokens"},
      "linear_lookup_failed: %{token: \"secret\" => :timeout}",
      "missing_project_name"
    ]

    for reason <- reasons do
      copy = ActionFailureCopy.tool_error(reason)

      assert copy ==
               "Could not complete that check yet. Try again from the latest message or open Maraithon to review it."

      refute copy =~ "DBConnection"
      refute copy =~ "token=secret"
      refute copy =~ "oauth_tokens"
      refute copy =~ "linear_lookup_failed"
      refute copy =~ "missing_project_name"
    end
  end

  test "linear lookup and prepared action copy hide raw persistence failures" do
    linear_copy = ActionFailureCopy.linear_lookup({:timeout, "DBConnection.ConnectionError"})
    prepared_copy = ActionFailureCopy.prepared_action({:error, %{changeset: :invalid}})

    assert linear_copy ==
             "Could not check Linear right now. Try again after refreshing the Linear connection."

    assert prepared_copy ==
             "Could not prepare that action. Refresh the latest message and try again."

    refute linear_copy =~ "DBConnection"
    refute prepared_copy =~ "changeset"
  end
end
