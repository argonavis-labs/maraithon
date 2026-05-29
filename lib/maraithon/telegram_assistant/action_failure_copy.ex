defmodule Maraithon.TelegramAssistant.ActionFailureCopy do
  @moduledoc false

  alias Maraithon.AppUrl

  @generic_action_failure "Could not complete that yet. Try again from the latest message or open Maraithon to review it."
  @generic_todo_failure "Could not update that work item. Refresh the latest work message and try again."
  @generic_tool_failure "Could not complete that check yet. Try again from the latest message or open Maraithon to review it."

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
    "That work item is no longer available."
  end

  def todo_callback(reason) when reason in [:chat_mismatch, "chat_mismatch"] do
    "This work item is not linked to this chat anymore."
  end

  def todo_callback("google_account_reauth_required"), do: "Reconnect Google in Maraithon."
  def todo_callback("slack_workspace_reauth_required"), do: "Reconnect Slack in Maraithon."
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
        "Could not check Linear right now. Try again after refreshing the Linear connection."
    end
  end

  def agent_inspection(reason) do
    case normalize_reason(reason) do
      "agent_not_found" -> "That automation is no longer available."
      "agent_control_disabled" -> "Automation controls are not enabled."
      _ -> "Could not load that automation right now. Refresh automations and try again."
    end
  end

  def prepared_action(reason) do
    case normalize_reason(reason) do
      "write_tools_disabled" ->
        "Action drafting is not enabled."

      "agent_control_disabled" ->
        "Automation controls are not enabled."

      "agent_not_found" ->
        "That automation is no longer available."

      "project_not_found" ->
        "That project is no longer available."

      "unsupported_agent_action" ->
        "That automation action is not available."

      "unsupported_external_action" ->
        "That action is not available in Telegram."

      "unsupported_project_action" ->
        "That project action is not available."

      "invalid_external_payload" ->
        "Could not prepare that action. Review the details and try again."

      _ ->
        "Could not prepare that action. Refresh the latest message and try again."
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
      technical_message?(reason) -> @generic_tool_failure
      code_like?(reason) -> @generic_tool_failure
      true -> reason
    end
  end

  defp tool_error_for_code(_reason), do: @generic_tool_failure

  defp normalize_reason({:error, reason}), do: normalize_reason(reason)
  defp normalize_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp normalize_reason(reason) when is_binary(reason), do: String.trim(reason)
  defp normalize_reason(_reason), do: @generic_tool_failure

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
