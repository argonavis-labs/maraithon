defmodule MaraithonWeb.ApiErrorCopy do
  @moduledoc false

  alias Maraithon.RunErrorCopy

  @companion_context_recovery "Maraithon will keep using the last successful source check until the next check."

  @mobile_code_errors ~w(not_found invalid_email invalid_or_expired_code invalid_or_expired_link)a
  @mobile_chat_code_errors ~w(
    not_found
    assistant_run_in_progress
    message_too_long
    missing_client_message_id
    empty_message
    empty_thread_title
    thread_title_too_long
    message_not_found
    invalid_decision
    prepared_action_expired
  )a

  def mobile(reason) when reason in @mobile_code_errors do
    %{
      error: Atom.to_string(reason),
      message: mobile_message(reason)
    }
  end

  def mobile(:unsupported_todo_action) do
    %{
      error: "unsupported_todo_action",
      message: "That work item action is not available from mobile."
    }
  end

  def mobile(:missing_duplicate) do
    %{
      error: "missing_duplicate",
      message: "Choose the duplicate person to merge."
    }
  end

  def mobile(%Ecto.Changeset{} = changeset) do
    %{
      error: "invalid_params",
      message: "Review the highlighted details before saving.",
      details: validation_errors(changeset)
    }
  end

  def mobile(_reason) do
    %{
      error: "request_failed",
      message: "Request did not complete. Saved data was left unchanged."
    }
  end

  def mobile_chat(reason) when reason in @mobile_chat_code_errors do
    %{
      error: Atom.to_string(reason),
      message: mobile_chat_message(reason)
    }
  end

  def mobile_chat(%Ecto.Changeset{} = changeset) do
    %{
      error: "invalid_params",
      message: "Review the highlighted conversation details before saving.",
      details: validation_errors(changeset)
    }
  end

  def mobile_chat(_reason) do
    %{
      error: "request_failed",
      message:
        "Conversation update did not complete. Refresh the conversation before sending another message."
    }
  end

  def mobile_chat_run_error(nil), do: nil
  def mobile_chat_run_error(""), do: nil

  def mobile_chat_run_error(reason), do: RunErrorCopy.assistant_response(reason)

  def companion_recall(:missing_query) do
    %{
      error: "missing_query",
      message: "Enter what you want Maraithon to recall."
    }
  end

  def companion_recall(_reason) do
    %{
      error: "recall_unavailable",
      message: "Recall could not finish. No saved data changed; search again in a moment."
    }
  end

  def companion_device(:not_found) do
    %{
      error: "device_not_found",
      message:
        "That Mac is no longer paired. Refresh the device list; pair it again if it should keep checking this Mac."
    }
  end

  def companion_device(:delete_failed) do
    %{
      error: "device_delete_failed",
      message: "Could not remove that Mac. Refresh the device list before removing it."
    }
  end

  def companion_device(:unsupported_source) do
    %{
      error: "unsupported_source",
      message: "Choose an available source before deleting uploaded data."
    }
  end

  def companion_device(_reason) do
    %{
      error: "device_request_failed",
      message: "Could not update that Mac. Refresh the device list before changing it."
    }
  end

  def companion_device_key(:missing_key_id) do
    %{
      error: "missing_key_id",
      message:
        "Encrypted source access is not ready. Re-pair this Mac before checking encrypted sources."
    }
  end

  def companion_device_key(:missing_public_key) do
    %{
      error: "missing_public_key",
      message:
        "Encrypted source access is not ready. Re-pair this Mac before checking encrypted sources."
    }
  end

  def companion_device_key(_reason) do
    %{
      error: "invalid_device_key",
      message:
        "Maraithon could not save this Mac's encryption key. Re-pair this Mac before checking encrypted sources."
    }
  end

  def companion_sync(:missing_items, batch_key) do
    %{
      error: "#{batch_key}_required",
      message: "The Mac sent incomplete source data. #{@companion_context_recovery}"
    }
  end

  def companion_sync(:too_many_items, max_batch) do
    %{
      error: "batch_too_large",
      message:
        "That check tried to upload more than #{max_batch} items. #{@companion_context_recovery}"
    }
  end

  def companion_sync(:device_mismatch, _context) do
    %{
      error: "device_mismatch",
      message: "This Mac is paired as a different device. Sign out and pair it again."
    }
  end

  def companion_sync(:unknown_event, _context) do
    %{
      error: "unknown_event",
      message:
        "The companion app sent source data this version of Maraithon does not support. Update the app, then check again."
    }
  end

  def companion_sync(_reason, _context) do
    %{
      error: "invalid_batch",
      message: "Some items could not be saved. #{@companion_context_recovery}"
    }
  end

  def companion_channel_error(reason, context) do
    reason
    |> companion_sync(context)
    |> Map.new(fn {key, value} ->
      case key do
        :error -> {:reason, value}
        other -> {other, value}
      end
    end)
  end

  def notaui_sync(_reason) do
    %{
      error:
        "Notaui tasks did not update. Check the Notaui connection before running another update."
    }
  end

  def mcp_batch(_reason) do
    %{"reason" => "A request in the batch failed unexpectedly."}
  end

  def mcp_policy_decision(decision) when is_map(decision) do
    decision = string_key_map(decision)

    case Map.get(decision, "reason_code") do
      "unknown_tool" ->
        decision
        |> Map.put("message", "Action is not available.")
        |> Map.put("metadata", Map.drop(Map.get(decision, "metadata", %{}), ["tool_name"]))

      _ ->
        decision
    end
  end

  def mcp_policy_decision(_decision) do
    %{
      "message" => "Action did not complete. No confirmed change was recorded.",
      "reason_code" => "tool_failed"
    }
  end

  def mcp_policy_message(decision) do
    decision
    |> mcp_policy_decision()
    |> Map.get("message", "Action did not complete. No confirmed change was recorded.")
  end

  def mcp_tool(:tool_crashed) do
    "Action stopped before completion. No confirmed change was recorded."
  end

  def mcp_tool(:tool_timeout) do
    "Action took too long. Check the latest state before running it again."
  end

  def mcp_tool({:tool_policy_denied, decision}) do
    mcp_policy_message(decision)
  end

  def mcp_tool({:tool_policy_needs_confirmation, decision}) do
    mcp_policy_message(decision)
  end

  def mcp_tool(reason) when is_binary(reason) do
    cond do
      reason == "invalid_args" ->
        "Action details are invalid. Review the request before running it again."

      reason == "invalid_user_context" ->
        "Sign in again so Maraithon can confirm the account."

      String.starts_with?(reason, "unknown_tool:") ->
        "Action is not available."

      String.starts_with?(reason, "tool_crashed:") ->
        mcp_tool(:tool_crashed)

      String.starts_with?(reason, "tool_timeout:") ->
        mcp_tool(:tool_timeout)

      String.ends_with?(reason, "_not_found") ->
        "Requested item was not found."

      account_connection_error?(reason) ->
        "Connect the missing account before running this action."

      account_reauth_error?(reason) ->
        "Reconnect the account before running this action."

      String.starts_with?(reason, "missing_") ->
        "Required action details are missing."

      String.contains?(reason, ":") ->
        "Action did not complete. No confirmed change was recorded."

      Regex.match?(~r/^[a-z0-9_]+$/, reason) ->
        "Action did not complete. No confirmed change was recorded."

      true ->
        "Action did not complete. No confirmed change was recorded."
    end
  end

  def mcp_tool(_reason) do
    "Action did not complete. No confirmed change was recorded."
  end

  defp validation_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Enum.reduce(opts, message, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
  end

  defp mobile_message(:not_found) do
    "That item is no longer available. Refresh to see current work."
  end

  defp mobile_message(:invalid_email), do: "Enter a valid email address."
  defp mobile_message(:invalid_or_expired_code), do: "Sign-in code is invalid or expired."
  defp mobile_message(:invalid_or_expired_link), do: "Sign-in link is invalid or expired."

  defp mobile_chat_message(:not_found) do
    "That conversation is no longer available. Refresh conversations to see current threads."
  end

  defp mobile_chat_message(:assistant_run_in_progress) do
    "Maraithon is still working on your last request. Wait for that answer before sending another message."
  end

  defp mobile_chat_message(:message_too_long), do: "Message is too long. Send a shorter note."

  defp mobile_chat_message(:missing_client_message_id) do
    "Message could not be sent. Retry from the latest conversation."
  end

  defp mobile_chat_message(:empty_message), do: "Enter a message before sending."
  defp mobile_chat_message(:empty_thread_title), do: "Enter a chat name before saving."
  defp mobile_chat_message(:thread_title_too_long), do: "Keep the chat name shorter."

  defp mobile_chat_message(:message_not_found) do
    "That message is no longer available. Refresh the conversation before continuing."
  end

  defp mobile_chat_message(:invalid_decision), do: "Choose confirm or cancel before continuing."

  defp mobile_chat_message(:prepared_action_expired) do
    "That action expired. Ask Maraithon to prepare it again."
  end

  defp account_connection_error?(reason) do
    String.ends_with?(reason, "_not_connected") or
      reason in ["notaui_not_configured", "github_api_token_not_configured"]
  end

  defp account_reauth_error?(reason) do
    String.ends_with?(reason, "_reauth_required") or
      String.ends_with?(reason, "_reconnect_required")
  end

  defp string_key_map(map) when is_map(map) do
    Map.new(map, fn
      {key, value} when is_atom(key) or is_binary(key) ->
        {to_string(key), string_key_value(value)}

      {key, value} ->
        {key, string_key_value(value)}
    end)
  end

  defp string_key_value(value) when is_map(value), do: string_key_map(value)
  defp string_key_value(value), do: value
end
