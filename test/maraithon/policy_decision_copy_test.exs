defmodule Maraithon.PolicyDecisionCopyTest do
  use ExUnit.Case, async: true

  alias Maraithon.PolicyDecisionCopy

  test "unknown-tool decisions hide raw tool identifiers" do
    decision =
      PolicyDecisionCopy.sanitize(%{
        "status" => "deny",
        "reason_code" => "unknown_tool",
        "message" => "Unknown tool: internal_secret_tool.",
        "metadata" => %{"tool_name" => "internal_secret_tool", "side_effect" => "read"}
      })

    assert decision == %{
             "status" => "deny",
             "reason_code" => "unknown_tool",
             "message" => "Action is not available.",
             "metadata" => %{"side_effect" => "read"}
           }

    refute inspect(decision) =~ "internal_secret_tool"
    refute inspect(decision) =~ "Unknown tool"
  end

  test "unsafe decision messages and metadata fall back to product copy" do
    decision =
      PolicyDecisionCopy.sanitize(%{
        reason_code: "unexpected_policy_state",
        message: "RuntimeError stacktrace HTTP 500 token=secret",
        metadata: %{
          tool_name: "gmail_send_message",
          side_effect: "external_send",
          debug: "Authorization: Bearer secret",
          surface: "mcp"
        }
      })

    assert decision == %{
             "reason_code" => "unexpected_policy_state",
             "message" => "Action did not complete. No confirmed change was recorded.",
             "metadata" => %{"side_effect" => "external_send", "surface" => "mcp"}
           }

    refute inspect(decision) =~ "gmail_send_message"
    refute inspect(decision) =~ "RuntimeError"
    refute inspect(decision) =~ "token=secret"
    refute inspect(decision) =~ "Bearer"
  end

  test "safe custom policy messages are preserved" do
    decision =
      PolicyDecisionCopy.sanitize(%{
        "reason_code" => "custom_scope",
        "message" => "That action is outside this automation's scope.",
        "metadata" => %{"agent_policy_applied" => true}
      })

    assert decision["message"] == "That action is outside this automation's scope."
    assert decision["metadata"] == %{"agent_policy_applied" => true}
  end

  test "control protocol can use its stricter fallback" do
    decision =
      PolicyDecisionCopy.sanitize(
        %{"message" => "DBConnection stacktrace token=secret"},
        fallback_message: "Maraithon blocked this action.",
        fallback_reason_code: "policy_denied"
      )

    assert decision["reason_code"] == "policy_denied"
    assert decision["message"] == "Maraithon blocked this action."
  end
end
