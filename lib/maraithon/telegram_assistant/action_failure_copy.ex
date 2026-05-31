defmodule Maraithon.TelegramAssistant.ActionFailureCopy do
  @moduledoc false

  alias Maraithon.AppUrl

  @generic_action_failure "Action did not complete. No change was made; use the latest message before deciding."
  @generic_todo_failure "Work item was not updated. No change was made; use the latest open-work message."
  @generic_tool_failure "Check did not complete. No result was saved; use the latest message before continuing."

  @known_tool_error_copy %{
    "action_not_found" => "That action is no longer available. Review the latest action history.",
    "briefing_agent_not_found" => "Select an active Chief of Staff before changing the schedule.",
    "calendar_event_not_found" => "That calendar event is no longer available.",
    "file_not_found" => "That file is no longer available.",
    "implementation_run_not_found" =>
      "That implementation run is no longer available. Refresh projects.",
    "insight_not_found" => "That insight is no longer available. Refresh insights.",
    "invalid_args" => "Review the request details before asking again.",
    "invalid_briefing_kind" => "Choose a supported briefing schedule.",
    "invalid_implementation_run_metadata" =>
      "Review the implementation run details before saving.",
    "invalid_implementation_run_status" => "Choose a valid implementation status.",
    "invalid_life_domain" => "Choose a valid life domain for that project.",
    "invalid_local_hour" => "Choose a valid morning briefing time.",
    "invalid_local_minute" => "Choose a valid morning briefing time.",
    "invalid_recommendation_decision" =>
      "Choose whether to accept or dismiss that recommendation.",
    "invalid_recommendation_decision_note" => "Keep the recommendation note brief before saving.",
    "invalid_repo_grant_status" => "Review the repository access details before saving.",
    "invalid_repo_provider" => "Review the repository access details before saving.",
    "invalid_repo_scope" => "Review the repository access details before saving.",
    "invalid_rules" => "Review the preference details before saving.",
    "invalid_snooze_until" => "Choose a valid snooze time for that work item.",
    "invalid_timezone_offset_hours" => "Choose a valid timezone for the morning briefing.",
    "invalid_todos" => "Review the work items before saving them.",
    "memory_not_found" => "That memory is no longer available. Refresh memory.",
    "message_not_found" => "That message is no longer available.",
    "missing_implementation_run_update" =>
      "Choose what changed on that implementation run before saving.",
    "missing_project_attrs" => "Choose what should change on that project before saving.",
    "missing_project_name" => "Give the project a name before saving it.",
    "missing_recommendation_id" => "Choose a project recommendation before deciding.",
    "missing_repo_full_name" => "Choose a GitHub repository before granting access.",
    "missing_rules" => "Review the preference details before saving.",
    "missing_snooze_until" => "Choose when that work item should come back.",
    "no_briefing_agents" =>
      "Install Chief of Staff before changing the morning briefing schedule.",
    "note_not_found" => "That note is no longer available.",
    "person_link_not_found" => "That linked detail is no longer available. Refresh people.",
    "person_not_found" => "That person is no longer available. Refresh people.",
    "preference_not_found" => "That preference is no longer available. Refresh preferences.",
    "project_not_found" => "That project is no longer available. Refresh projects.",
    "recommendation_not_found" =>
      "That project recommendation is no longer available. Refresh projects.",
    "reminder_not_found" => "That reminder is no longer available.",
    "todo_not_found" => "That work item is no longer available. Refresh open work.",
    "unknown_telegram_tool" =>
      "That action is not available. Refresh the message before asking again.",
    "unsupported_person_link_operation" => "That person update is not available.",
    "unsupported_todo_status" => "That work item update is not available.",
    "visit_not_found" => "That browser visit is no longer available.",
    "voice_memo_not_found" => "That voice memo is no longer available."
  }

  @technical_message_markers [
    "access_token",
    "authorization",
    "bearer ",
    "chat_id",
    "dbconnection",
    "ecto.",
    "external_account_id",
    "http_status",
    "oauth_tokens",
    "postgrex",
    "refresh_token",
    "stacktrace",
    "token=",
    "traceback"
  ]

  def insight_action("google_account_reauth_required") do
    "Google needs reconnecting before this can be sent: #{connector_url("google")}"
  end

  def insight_action("google_account_not_connected") do
    "Connect Google before sending this: #{connector_url("google")}"
  end

  def insight_action("slack_workspace_reauth_required") do
    "Slack needs reconnecting before this can run: #{connector_url("slack")}"
  end

  def insight_action("slack_workspace_not_connected") do
    "Connect Slack before running this: #{connector_url("slack")}"
  end

  def insight_action("linear_not_connected") do
    "Connect Linear before creating the task: #{connector_url("linear")}"
  end

  def insight_action("linear_default_team_missing") do
    "Choose a default Linear team before creating the task."
  end

  def insight_action(_reason), do: @generic_action_failure

  def todo_callback(reason) when reason in [:not_found, "not_found"] do
    "That work item is no longer available. Use the latest open-work message."
  end

  def todo_callback(reason) when reason in [:chat_mismatch, "chat_mismatch"] do
    "This work item is not linked to this chat anymore. Use the latest open-work message."
  end

  def todo_callback("google_account_reauth_required"),
    do: "Reconnect Google before updating this work item: #{connector_url("google")}"

  def todo_callback("slack_workspace_reauth_required"),
    do: "Reconnect Slack before updating this work item: #{connector_url("slack")}"

  def todo_callback("google_account_not_connected"), do: "Connect Google first."
  def todo_callback("slack_workspace_not_connected"), do: "Connect Slack first."
  def todo_callback(_reason), do: @generic_todo_failure

  def tool_error(reason), do: reason |> normalize_reason() |> tool_error_for_code()

  def linear_lookup(reason) do
    case normalize_reason(reason) do
      "linear_not_connected" ->
        "Connect Linear before looking up issues: #{connector_url("linear")}"

      "linear_reauth_required" ->
        "Reconnect Linear before looking up issues: #{connector_url("linear")}"

      "linear_issue_not_found" ->
        "Could not find that Linear issue."

      _ ->
        "Could not check Linear right now. Refresh the Linear connection before checking that issue."
    end
  end

  def agent_inspection(reason) do
    case normalize_reason(reason) do
      "agent_not_found" ->
        "That automation is no longer available. Refresh automations."

      "agent_control_disabled" ->
        "Automation controls are not enabled."

      _ ->
        "Could not load that automation right now. Refresh automations before using this action."
    end
  end

  def prepared_action(reason) do
    case normalize_reason(reason) do
      "write_tools_disabled" ->
        "Action drafting is not enabled."

      "agent_control_disabled" ->
        "Automation controls are not enabled."

      "agent_not_found" ->
        "That automation is no longer available. Refresh automations."

      "project_not_found" ->
        "That project is no longer available. Refresh projects."

      "unsupported_agent_action" ->
        "That automation action is not available."

      "unsupported_external_action" ->
        "That action is not available in Telegram."

      "unsupported_project_action" ->
        "That project action is not available."

      "invalid_external_payload" ->
        "Could not prepare that action. Review the action details before asking again."

      _ ->
        "Could not prepare that action. No change was made; use the latest message before deciding."
    end
  end

  defp tool_error_for_code("linear_not_connected"), do: linear_lookup("linear_not_connected")
  defp tool_error_for_code("linear_reauth_required"), do: linear_lookup("linear_reauth_required")
  defp tool_error_for_code("linear_issue_not_found"), do: linear_lookup("linear_issue_not_found")
  defp tool_error_for_code("agent_not_found"), do: agent_inspection("agent_not_found")

  defp tool_error_for_code("agent_control_disabled"),
    do: prepared_action("agent_control_disabled")

  defp tool_error_for_code("write_tools_disabled"), do: prepared_action("write_tools_disabled")
  defp tool_error_for_code("project_not_found"), do: prepared_action("project_not_found")

  defp tool_error_for_code("unsupported_agent_action"),
    do: prepared_action("unsupported_agent_action")

  defp tool_error_for_code("unsupported_external_action"),
    do: prepared_action("unsupported_external_action")

  defp tool_error_for_code("unsupported_project_action"),
    do: prepared_action("unsupported_project_action")

  defp tool_error_for_code("invalid_external_payload"),
    do: prepared_action("invalid_external_payload")

  defp tool_error_for_code(reason) when is_binary(reason) do
    cond do
      copy = Map.get(@known_tool_error_copy, reason) ->
        copy

      String.starts_with?(reason, "unknown_telegram_tool") ->
        Map.fetch!(@known_tool_error_copy, "unknown_telegram_tool")

      technical_message?(reason) ->
        @generic_tool_failure

      code_like?(reason) ->
        @generic_tool_failure

      true ->
        reason
    end
  end

  defp tool_error_for_code(_reason), do: @generic_tool_failure

  defp normalize_reason({policy_reason, decision})
       when policy_reason in [:tool_policy_denied, :tool_policy_needs_confirmation] do
    policy_decision_copy(policy_reason, decision)
  end

  defp normalize_reason({:error, reason}), do: normalize_reason(reason)
  defp normalize_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp normalize_reason(reason) when is_binary(reason), do: String.trim(reason)
  defp normalize_reason(_reason), do: @generic_tool_failure

  defp policy_decision_copy(:tool_policy_needs_confirmation, _decision) do
    "Confirm this action before it runs."
  end

  defp policy_decision_copy(:tool_policy_denied, decision) do
    case decision_value(decision, :reason_code) do
      "agent_tool_denied" ->
        "That automation is not allowed to use this action."

      "agent_tool_not_allowed" ->
        "That automation is not allowed to use this action."

      "invalid_policy_context" ->
        "The action context could not be verified, so nothing changed."

      "invalid_user_context" ->
        "Sign in again so the account can be confirmed."

      "missing_tool_name" ->
        "Choose an action before continuing."

      "unknown_tool" ->
        Map.fetch!(@known_tool_error_copy, "unknown_telegram_tool")

      _ ->
        policy_decision_message(decision) || @generic_tool_failure
    end
  end

  defp policy_decision_message(decision) do
    case decision_value(decision, :message) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> nil
          trimmed -> trimmed
        end

      _ ->
        nil
    end
  end

  defp decision_value(decision, key) when is_map(decision) and is_atom(key) do
    Map.get(decision, key) || Map.get(decision, Atom.to_string(key))
  end

  defp decision_value(_decision, _key), do: nil

  defp technical_message?(message) do
    lower = String.downcase(message)

    Enum.any?(@technical_message_markers, &String.contains?(lower, &1)) or
      String.contains?(message, ["{", "}", "=>"])
  end

  defp code_like?(message) do
    String.match?(message, ~r/^[a-z][a-z0-9_]*(?::[a-z0-9_]+)?$/)
  end

  defp connector_url(provider), do: AppUrl.url("/connectors/#{provider}")
end
