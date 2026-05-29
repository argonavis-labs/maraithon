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
             "Action did not complete. Open the latest message or review it in Maraithon before deciding."

    refute copy =~ ":db"
    refute copy =~ "timeout"
    refute copy =~ "I couldn't"
    refute String.contains?(String.downcase(copy), "try again")
  end

  test "hides unknown todo callback reasons" do
    copy = ActionFailureCopy.todo_callback({:stale_row, :not_found})

    assert copy ==
             "Could not update that work item. Refresh the latest work message before using this action."

    refute copy =~ "stale_row"
    refute copy =~ ":not_found"
    refute copy =~ "I couldn't"
    refute String.contains?(String.downcase(copy), "try again")
  end

  test "keeps stale todo callback states specific" do
    assert ActionFailureCopy.todo_callback(:not_found) ==
             "That work item is no longer available. Refresh the latest work message."

    assert ActionFailureCopy.todo_callback(:chat_mismatch) ==
             "This work item is not linked to this chat anymore. Refresh the latest work message."
  end

  test "tool errors keep known recovery states actionable" do
    assert ActionFailureCopy.tool_error("linear_not_connected") =~
             "Connect Linear before looking up issues"

    assert ActionFailureCopy.tool_error(:agent_not_found) ==
             "That automation is no longer available. Refresh automations."

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
               "Could not complete that check. Open the latest message or review Maraithon before continuing."

      refute copy =~ "DBConnection"
      refute copy =~ "token=secret"
      refute copy =~ "oauth_tokens"
      refute copy =~ "linear_lookup_failed"
      refute copy =~ "missing_project_name"
      refute String.contains?(String.downcase(copy), "try again")
    end
  end

  test "linear lookup and prepared action copy hide raw persistence failures" do
    linear_copy = ActionFailureCopy.linear_lookup({:timeout, "DBConnection.ConnectionError"})
    prepared_copy = ActionFailureCopy.prepared_action({:error, %{changeset: :invalid}})

    assert linear_copy ==
             "Could not check Linear right now. Refresh the Linear connection before checking that issue."

    assert prepared_copy ==
             "Could not prepare that action. Refresh the latest message before deciding."

    refute linear_copy =~ "DBConnection"
    refute prepared_copy =~ "changeset"
    refute String.contains?(String.downcase(linear_copy), "try again")
    refute String.contains?(String.downcase(prepared_copy), "try again")
  end
end
