defmodule Maraithon.ToolPolicyTest do
  use Maraithon.DataCase, async: true

  alias Maraithon.ActionLedger
  alias Maraithon.ToolPolicy

  describe "authorize/1" do
    test "allows read-only tools with valid user context" do
      decision =
        ToolPolicy.authorize(%{
          surface: "mcp",
          tool_name: "list_todos",
          user_id: "policy-reader@example.com"
        })

      assert decision.status == :allow
      assert decision.reason_code == "policy_allowed"
    end

    test "denies unknown tools by default" do
      decision =
        ToolPolicy.authorize(%{
          surface: "mcp",
          tool_name: "not_a_real_tool",
          user_id: "policy-reader@example.com"
        })

      assert decision.status == :deny
      assert decision.reason_code == "unknown_tool"
    end

    test "denies user-scoped writes without a valid user context" do
      decision =
        ToolPolicy.authorize(%{
          surface: "telegram",
          tool_name: "write_memory",
          arguments: %{}
        })

      assert decision.status == :deny
      assert decision.reason_code == "invalid_user_context"
    end

    test "requires confirmation for external sends on model-controlled surfaces" do
      decision =
        ToolPolicy.authorize(%{
          surface: "mcp",
          tool_name: "gmail_send_message",
          user_id: "policy-sender@example.com"
        })

      assert decision.status == :needs_confirmation
      assert decision.reason_code == "confirmation_required"
    end

    test "allows confirmed external sends" do
      decision =
        ToolPolicy.authorize(%{
          surface: "mcp",
          tool_name: "gmail_send_message",
          user_id: "policy-sender@example.com",
          confirmed?: true
        })

      assert decision.status == :allow
    end
  end

  describe "enforce/2" do
    test "does not execute denied calls and records the decision" do
      user_id = "policy-denied-#{System.unique_integer([:positive])}@example.com"

      assert {:error, {:tool_policy_needs_confirmation, decision}} =
               ToolPolicy.enforce(
                 %{
                   surface: "mcp",
                   tool_name: "gmail_send_message",
                   user_id: user_id,
                   arguments: %{"user_id" => user_id},
                   tool_metadata: Maraithon.Tools.policy_metadata_for("gmail_send_message")
                 },
                 fn -> flunk("denied policy calls must not execute") end
               )

      assert decision["reason_code"] == "confirmation_required"

      [entry] = ActionLedger.list_recent(user_id, limit: 1)
      assert entry.event_type == "tool.needs_confirmation"
      assert entry.status == "needs_confirmation"
      assert get_in(entry.policy_decision, ["reason_code"]) == "confirmation_required"
    end
  end
end
