defmodule MaraithonWeb.ApiErrorCopyTest do
  use ExUnit.Case, async: true

  alias MaraithonWeb.ApiErrorCopy

  @internal_reason {:db, :timeout, [query: "select * from telegram_assistant_runs"]}

  test "mobile payloads preserve stable public codes" do
    assert ApiErrorCopy.mobile(:not_found) == %{
             error: "not_found",
             message: "That item is no longer available."
           }

    assert ApiErrorCopy.mobile_chat(:assistant_run_in_progress) == %{
             error: "assistant_run_in_progress",
             message: "Maraithon is still working on the last message."
           }
  end

  test "mobile payloads hide structured internal failures" do
    copy = ApiErrorCopy.mobile(@internal_reason)

    assert copy == %{
             error: "request_failed",
             message: "Request did not complete. Refresh before retrying."
           }

    refute_leaks_internal_reason(copy.error)
    refute_leaks_internal_reason(copy.message)
  end

  test "mobile chat payloads give human validation copy" do
    assert ApiErrorCopy.mobile_chat(:message_too_long) == %{
             error: "message_too_long",
             message: "Message is too long. Send a shorter note."
           }

    assert ApiErrorCopy.mobile_chat(:empty_message) == %{
             error: "empty_message",
             message: "Enter a message before sending."
           }

    assert ApiErrorCopy.mobile_chat(:message_not_found) == %{
             error: "message_not_found",
             message: "That message is no longer available."
           }
  end

  test "mobile chat run errors hide raw assistant failures" do
    raw = "http_status: 500 internal_stacktrace db_timeout token=secret"

    assert ApiErrorCopy.mobile_chat_run_error(raw) ==
             "I could not finish that response. Ask for a narrower check or refresh the conversation before continuing."

    assert ApiErrorCopy.mobile_chat_run_error("google_account_not_connected") ==
             "Connect the missing account before running this again."

    assert ApiErrorCopy.mobile_chat_run_error("tool_timeout") ==
             "That response took too long. Ask for a narrower check."

    refute_leaks_internal_reason(ApiErrorCopy.mobile_chat_run_error(raw))
  end

  test "mobile changeset payloads return safe validation details" do
    changeset =
      {%{}, %{title: :string}}
      |> Ecto.Changeset.cast(%{}, [:title])
      |> Ecto.Changeset.validate_required([:title])

    copy = ApiErrorCopy.mobile(changeset)

    assert copy.error == "invalid_params"
    assert copy.message == "Review the highlighted details before saving again."
    assert copy.details == %{title: ["can't be blank"]}
    refute inspect(copy) =~ "Ecto.Changeset"
  end

  test "companion and integration payloads hide internal failures" do
    copies = [
      ApiErrorCopy.companion_recall(@internal_reason),
      ApiErrorCopy.companion_sync(@internal_reason, "messages"),
      ApiErrorCopy.companion_device(@internal_reason),
      ApiErrorCopy.companion_device_key(@internal_reason),
      ApiErrorCopy.notaui_sync(@internal_reason)
    ]

    assert %{
             error: "recall_unavailable",
             message: "Recall could not finish. No saved data changed; search again in a moment."
           } in copies

    assert %{
             error: "invalid_batch",
             message:
               "Some items were not accepted. Sync again from the companion app; Maraithon will keep the last successful data until then."
           } in copies

    assert %{
             error: "device_request_failed",
             message: "Could not update that Mac. Refresh the device list before trying again."
           } in copies

    assert %{
             error: "invalid_device_key",
             message:
               "Maraithon could not save this Mac's encryption key. Re-pair this Mac before syncing encrypted sources."
           } in copies

    Enum.each(copies, fn copy ->
      refute_leaks_internal_reason(copy.error)
      if Map.has_key?(copy, :message), do: refute_leaks_internal_reason(copy.message)
      refute Map.has_key?(copy, :reason)
    end)
  end

  test "companion device and key payloads use actionable product copy" do
    assert ApiErrorCopy.companion_device(:not_found) == %{
             error: "device_not_found",
             message:
               "That Mac is no longer paired. Refresh the device list; pair it again if it should still sync."
           }

    assert ApiErrorCopy.companion_device(:delete_failed) == %{
             error: "device_delete_failed",
             message: "Could not remove that Mac. Refresh the device list before trying again."
           }

    assert ApiErrorCopy.companion_device_key(:missing_key_id) == %{
             error: "missing_key_id",
             message:
               "Encryption setup is incomplete. Re-pair this Mac before syncing encrypted sources."
           }

    assert ApiErrorCopy.companion_device_key(:missing_public_key) == %{
             error: "missing_public_key",
             message:
               "Encryption setup is incomplete. Re-pair this Mac before syncing encrypted sources."
           }

    assert ApiErrorCopy.companion_recall(:missing_query) == %{
             error: "missing_query",
             message: "Enter what you want Maraithon to recall."
           }
  end

  test "companion sync payloads pair stable codes with product copy" do
    assert ApiErrorCopy.companion_sync(:missing_items, "messages") == %{
             error: "messages_required",
             message:
               "The Mac sent an incomplete sync batch. Sync again from the companion app; Maraithon will keep the last successful data until then."
           }

    assert ApiErrorCopy.companion_sync(:too_many_items, 200) == %{
             error: "batch_too_large",
             message:
               "Sync fewer than 200 items at a time. Maraithon will keep the last successful data until then."
           }

    assert ApiErrorCopy.companion_channel_error(:device_mismatch, nil) == %{
             reason: "device_mismatch",
             message: "This Mac is paired as a different device. Sign out and pair it again."
           }
  end

  test "mcp tool errors do not leak raw internal reasons" do
    assert ApiErrorCopy.mcp_tool("unknown_tool: internal_secret_tool") ==
             "Action is not available."

    assert ApiErrorCopy.mcp_tool("google_api_failed: 500 %{token: \"secret\"}") ==
             "Action did not complete. No confirmed change was recorded."

    raw_sentence = "Provider returned HTTP 500 for token=secret and request_id=req_123"

    assert ApiErrorCopy.mcp_tool(raw_sentence) ==
             "Action did not complete. No confirmed change was recorded."

    assert ApiErrorCopy.mcp_tool(@internal_reason) ==
             "Action did not complete. No confirmed change was recorded."

    assert ApiErrorCopy.mcp_batch(@internal_reason) == %{
             "reason" => "A request in the batch failed unexpectedly."
           }

    refute ApiErrorCopy.mcp_tool(raw_sentence) =~ "token=secret"
    refute ApiErrorCopy.mcp_tool(raw_sentence) =~ "req_123"
  end

  test "mcp unknown-tool policy decisions keep the code and hide the raw tool name" do
    decision =
      ApiErrorCopy.mcp_policy_decision(%{
        "reason_code" => "unknown_tool",
        "message" => "Unknown tool: internal_secret_tool.",
        "metadata" => %{"tool_name" => "internal_secret_tool", "side_effect" => "read"}
      })

    assert decision["reason_code"] == "unknown_tool"
    assert decision["message"] == "Action is not available."
    assert decision["metadata"] == %{"side_effect" => "read"}
    refute inspect(decision) =~ "internal_secret_tool"
    refute inspect(decision) =~ "Unknown tool:"
  end

  defp refute_leaks_internal_reason(copy) do
    refute copy =~ "db"
    refute copy =~ "timeout"
    refute copy =~ "telegram_assistant_runs"
    refute copy =~ "{"
    refute copy =~ "["
  end
end
