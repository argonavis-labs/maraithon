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
      "missing_user_id"
    ]

    for reason <- reasons do
      copy = ActionFailureCopy.tool_error(reason)

      assert copy ==
               "Could not complete that check. Open the latest message or review Maraithon before continuing."

      refute copy =~ "DBConnection"
      refute copy =~ "token=secret"
      refute copy =~ "oauth_tokens"
      refute copy =~ "linear_lookup_failed"
      refute copy =~ "missing_user_id"
      refute String.contains?(String.downcase(copy), "try again")
    end
  end

  test "tool errors keep common recoverable input failures actionable" do
    assert ActionFailureCopy.tool_error("missing_project_name") ==
             "Give the project a name before saving it."

    assert ActionFailureCopy.tool_error("missing_project_attrs") ==
             "Choose what should change on that project before saving."

    assert ActionFailureCopy.tool_error("invalid_snooze_until") ==
             "Choose a valid snooze time for that work item."

    assert ActionFailureCopy.tool_error("invalid_local_hour") ==
             "Choose a valid morning briefing time."

    for reason <- [
          "missing_project_name",
          "missing_project_attrs",
          "invalid_snooze_until",
          "invalid_local_hour"
        ] do
      refute ActionFailureCopy.tool_error(reason) =~ reason
    end
  end

  test "tool errors translate policy decisions without leaking policy tuples" do
    confirmation_copy =
      ActionFailureCopy.tool_error(
        {:tool_policy_needs_confirmation,
         %{"reason_code" => "confirmation_required", "message" => "Confirm first."}}
      )

    denied_copy =
      ActionFailureCopy.tool_error(
        {:tool_policy_denied,
         %{"reason_code" => "unknown_tool", "message" => "Action is not available."}}
      )

    assert confirmation_copy == "Confirm this action before Maraithon continues."

    assert denied_copy ==
             "That assistant action is not available. Refresh the message before asking again."

    refute confirmation_copy =~ "tool_policy"
    refute denied_copy =~ "unknown_tool"
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
