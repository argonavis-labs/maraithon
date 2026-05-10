defmodule Maraithon.Runtime.Effects.ToolCallCommandTest do
  use Maraithon.DataCase, async: true

  alias Maraithon.Accounts
  alias Maraithon.ActionLedger
  alias Maraithon.Agents
  alias Maraithon.Effects.Effect
  alias Maraithon.Runtime.Effects.ToolCallCommand

  test "executes allowed runtime read tools" do
    effect = %Effect{params: %{"tool" => "time", "args" => %{}}}

    assert {:ok, result} = ToolCallCommand.execute(effect)
    assert is_binary(result.utc)
  end

  test "blocks confirmation-required runtime tool calls before execution" do
    user_id = "runtime-policy-#{System.unique_integer([:positive])}@example.com"
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

    {:ok, agent} =
      Agents.create_agent(%{
        user_id: user_id,
        behavior: "prompt_agent",
        config: %{"name" => "Runtime policy test", "prompt" => "Send mail."}
      })

    effect = %Effect{
      agent_id: agent.id,
      params: %{
        "tool" => "gmail_send_message",
        "args" => %{
          "user_id" => user_id,
          "to" => "someone@example.com",
          "subject" => "Runtime policy",
          "body" => "This must not send."
        }
      }
    }

    assert {:error, {:tool_policy_needs_confirmation, decision}} =
             ToolCallCommand.execute(effect)

    assert decision["reason_code"] == "confirmation_required"

    assert [entry] = ActionLedger.list_recent(user_id, limit: 1)
    assert entry.surface == "runtime"
    assert entry.event_type == "tool.needs_confirmation"
  end
end
