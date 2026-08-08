defmodule Maraithon.Runtime.Effects.ToolCallCommandTest do
  use Maraithon.DataCase, async: true

  alias Maraithon.Accounts
  alias Maraithon.ActionLedger
  alias Maraithon.Agents
  alias Maraithon.Effects
  alias Maraithon.Effects.Effect
  alias Maraithon.Repo
  alias Maraithon.Runtime.Effects.ToolCallCommand
  alias Maraithon.Todos.Todo

  test "executes allowed runtime read tools" do
    effect = %Effect{params: %{"tool" => "time", "args" => %{}}}

    assert {:ok, result} = ToolCallCommand.execute(effect)
    assert is_binary(result.utc)
  end

  test "binds tenant tool arguments to the persisted agent user" do
    agent_user_id = "runtime-owner-#{System.unique_integer([:positive])}@example.com"
    other_user_id = "runtime-other-#{System.unique_integer([:positive])}@example.com"

    for user_id <- [agent_user_id, other_user_id] do
      {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)
    end

    {:ok, agent} =
      Agents.create_agent(%{
        user_id: agent_user_id,
        behavior: "prompt_agent",
        status: "running",
        config: %{"name" => "Tenant binding test", "prompt" => "List my work."}
      })

    agent_todo = insert_todo(agent_user_id, "Agent tenant work")
    other_todo = insert_todo(other_user_id, "Other tenant private work")

    effect = %Effect{
      agent_id: agent.id,
      owner_user_id: agent_user_id,
      params: %{
        "tool" => "list_todos",
        "args" => %{"user_id" => other_user_id, "statuses" => ["open"]}
      }
    }

    assert {:ok, %{count: 1, todos: [todo]}} = ToolCallCommand.execute(effect)
    assert todo.id == agent_todo.id
    refute todo.id == other_todo.id
  end

  test "enforces the persisted package tool allowlist at execution time" do
    user_id = "runtime-package-#{System.unique_integer([:positive])}@example.com"
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

    {:ok, package} =
      Agents.create_agent_package(%{
        slug: "runtime-package-#{System.unique_integer([:positive])}",
        name: "Runtime package policy"
      })

    {:ok, package} =
      Agents.publish_agent_package_version(package, %{
        version: "1.0.0",
        behavior: "prompt_agent",
        tool_allowlist: ["time"]
      })

    {:ok, agent} =
      Agents.create_agent(%{
        user_id: user_id,
        behavior: "prompt_agent",
        status: "running",
        agent_package_id: package.id,
        agent_package_version_id: package.latest_version.id,
        config: %{}
      })

    effect = %Effect{
      agent_id: agent.id,
      owner_user_id: user_id,
      params: %{"tool" => "list_todos", "args" => %{}}
    }

    assert {:error, :tool_not_allowed} = ToolCallCommand.execute(effect)
  end

  test "does not accept tenant context from args without a persisted agent" do
    other_user_id = "runtime-unbound-#{System.unique_integer([:positive])}@example.com"
    {:ok, _user} = Accounts.get_or_create_user_by_email(other_user_id)

    effect = %Effect{
      agent_id: Ecto.UUID.generate(),
      params: %{
        "tool" => "list_todos",
        "args" => %{"user_id" => other_user_id}
      }
    }

    assert {:error, {:tool_policy_denied, decision}} = ToolCallCommand.execute(effect)
    assert decision["reason_code"] == "invalid_user_context"
  end

  test "denies a queued tenant tool whose immutable owner does not match the agent" do
    original_user_id = "runtime-original-#{System.unique_integer([:positive])}@example.com"
    replacement_user_id = "runtime-replacement-#{System.unique_integer([:positive])}@example.com"

    for user_id <- [original_user_id, replacement_user_id] do
      {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)
    end

    {:ok, agent} =
      Agents.create_agent(%{
        user_id: original_user_id,
        behavior: "prompt_agent",
        status: "running",
        config: %{"name" => "Owner transfer test", "prompt" => "List my work."}
      })

    {:ok, effect_id} = Effects.request(agent.id, "tool_call", "list_todos", %{})

    effect =
      effect_id
      |> then(&Repo.get!(Effect, &1))
      |> Ecto.Changeset.change(owner_user_id: replacement_user_id)
      |> Repo.update!()

    assert effect.owner_user_id == replacement_user_id
    assert {:error, {:tool_policy_denied, decision}} = ToolCallCommand.execute(effect)
    assert decision["reason_code"] == "invalid_user_context"
  end

  test "denies tenant tools for stopped agents" do
    user_id = "runtime-stopped-#{System.unique_integer([:positive])}@example.com"
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

    {:ok, agent} =
      Agents.create_agent(%{
        user_id: user_id,
        behavior: "prompt_agent",
        status: "stopped",
        config: %{"name" => "Stopped agent test", "prompt" => "List my work."}
      })

    effect = %Effect{
      agent_id: agent.id,
      owner_user_id: user_id,
      params: %{"tool" => "list_todos", "args" => %{}}
    }

    assert {:error, {:tool_policy_denied, decision}} = ToolCallCommand.execute(effect)
    assert decision["reason_code"] == "invalid_user_context"
  end

  test "blocks confirmation-required runtime tool calls with the agent's tenant context" do
    user_id = "runtime-policy-#{System.unique_integer([:positive])}@example.com"
    other_user_id = "runtime-policy-other-#{System.unique_integer([:positive])}@example.com"

    for account_user_id <- [user_id, other_user_id] do
      {:ok, _user} = Accounts.get_or_create_user_by_email(account_user_id)
    end

    {:ok, agent} =
      Agents.create_agent(%{
        user_id: user_id,
        behavior: "prompt_agent",
        status: "running",
        config: %{"name" => "Runtime policy test", "prompt" => "Send mail."}
      })

    effect = %Effect{
      agent_id: agent.id,
      owner_user_id: user_id,
      params: %{
        "tool" => "gmail_send_message",
        "args" => %{
          "user_id" => other_user_id,
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
    assert ActionLedger.list_recent(other_user_id, limit: 1) == []
  end

  defp insert_todo(user_id, title) do
    %Todo{}
    |> Todo.changeset(%{
      user_id: user_id,
      owner_user_id: user_id,
      source: "runtime_test",
      kind: "general",
      title: title,
      summary: "Tenant-isolated runtime tool regression fixture.",
      next_action: "Keep this work visible only to its owner.",
      dedupe_key: "runtime-test:#{Ecto.UUID.generate()}"
    })
    |> Repo.insert!()
  end
end
