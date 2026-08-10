defmodule Maraithon.Runtime.AgentLeaseConcurrencyTest do
  use ExUnit.Case, async: false

  import Ecto.Query

  alias Ecto.Adapters.SQL.Sandbox
  alias Maraithon.Accounts
  alias Maraithon.Accounts.User
  alias Maraithon.AgentIsolation
  alias Maraithon.Agents
  alias Maraithon.Agents.Agent
  alias Maraithon.Repo
  alias Maraithon.Runtime.AgentDirective
  alias Maraithon.Runtime.AgentDirectives
  alias Maraithon.Runtime.AgentLeases
  alias Maraithon.Runtime.AgentRestartGuards
  alias Maraithon.Runtime.AgentRuntimeLease

  setup do
    {agent, binding} =
      unboxed(fn ->
        user_id = "lease-concurrency-#{System.unique_integer([:positive])}@example.com"
        {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

        {:ok, agent} =
          Agents.create_agent(%{
            user_id: user_id,
            behavior: "prompt_agent",
            config: %{},
            install_status: "enabled",
            status: "running"
          })

        {:ok, binding} =
          AgentIsolation.grant_binding_consent(agent, Maraithon.DataCase.binding_consent(agent))

        {agent, binding}
      end)

    on_exit(fn ->
      unboxed(fn ->
        Repo.delete_all(from(lease in AgentRuntimeLease, where: lease.agent_id == ^agent.id))
        Repo.delete_all(from(agent_row in Agent, where: agent_row.id == ^agent.id))
        Repo.delete_all(from(user in User, where: user.id == ^agent.user_id))
      end)
    end)

    %{agent: agent, binding: binding}
  end

  test "two physical connections admit only one initial claim", %{agent: agent} do
    parent = self()

    claim = fn ->
      send(parent, {:ready, self()})
      receive do: (:go -> unboxed(fn -> AgentLeases.claim(agent.id) end))
    end

    first = Task.async(claim)
    second = Task.async(claim)
    assert_receive {:ready, first_pid}
    assert_receive {:ready, second_pid}
    send(first_pid, :go)
    send(second_pid, :go)

    results = [Task.await(first), Task.await(second)]
    assert Enum.count(results, &match?({:ok, %AgentRuntimeLease{}}, &1)) == 1
    assert Enum.count(results, &(&1 == {:error, :runtime_lease_owned})) == 1
  end

  test "two physical connections coalesce one enqueue dedupe key", %{agent: agent} do
    parent = self()

    enqueue = fn ->
      send(parent, {:enqueue_ready, self()})

      receive do
        :go ->
          unboxed(fn ->
            AgentDirectives.enqueue(
              agent.id,
              agent.user_id,
              "message",
              %{"body" => "same"},
              "concurrent-dedupe"
            )
          end)
      end
    end

    first = Task.async(enqueue)
    second = Task.async(enqueue)
    assert_receive {:enqueue_ready, first_pid}
    assert_receive {:enqueue_ready, second_pid}
    send(first_pid, :go)
    send(second_pid, :go)

    assert [{:ok, %AgentDirective{} = one}, {:ok, %AgentDirective{} = two}] =
             [Task.await(first), Task.await(second)]

    assert one.id == two.id
  end

  test "two physical connections claim at most one processing directive", %{agent: agent} do
    lease =
      unboxed(fn ->
        {:ok, _directive} =
          AgentDirectives.enqueue(
            agent.id,
            agent.user_id,
            "message",
            %{"body" => "once"},
            "concurrent-claim"
          )

        {:ok, lease} = AgentLeases.claim(agent.id)
        {:ok, _ready} = AgentLeases.mark_ready(agent.id, lease.owner_token)
        lease
      end)

    parent = self()

    claim = fn ->
      send(parent, {:directive_claim_ready, self()})

      receive do
        :go ->
          unboxed(fn ->
            AgentDirectives.claim_next(agent.id, agent.user_id, lease.owner_token)
          end)
      end
    end

    first = Task.async(claim)
    second = Task.async(claim)
    assert_receive {:directive_claim_ready, first_pid}
    assert_receive {:directive_claim_ready, second_pid}
    send(first_pid, :go)
    send(second_pid, :go)

    results = [Task.await(first), Task.await(second)]
    assert Enum.count(results, &match?({:ok, %AgentDirective{}}, &1)) == 1
    assert Enum.count(results, &(&1 == {:ok, nil})) == 1
  end

  test "a transactional ready fence holds ownership locks until caller commit", %{agent: agent} do
    lease =
      unboxed(fn ->
        {:ok, lease} = AgentLeases.claim(agent.id)
        {:ok, _ready} = AgentLeases.mark_ready(agent.id, lease.owner_token)
        lease
      end)

    parent = self()

    fenced =
      Task.async(fn ->
        unboxed(fn ->
          Repo.transaction(fn ->
            :ok = AgentLeases.fence_ready!(agent.id, lease.owner_token)
            send(parent, {:fenced, self()})
            receive do: (:release_fence -> :committed)
          end)
        end)
      end)

    assert_receive {:fenced, fenced_pid}

    blocked_crash =
      Task.async(fn ->
        unboxed(fn ->
          with_lock_timeout(fn ->
            AgentRestartGuards.record_crash(agent.id, lease.owner_token, :concurrent_crash,
              backoffs_ms: [0]
            )
          end)
        end)
      end)

    assert {:lock_timeout, %Postgrex.Error{} = lock_error} = Task.await(blocked_crash)
    assert lock_error.postgres.code == :lock_not_available
    assert unboxed(fn -> AgentLeases.ready?(agent.id, lease.owner_token) end)

    send(fenced_pid, :release_fence)
    assert {:ok, :committed} = Task.await(fenced)

    assert {:recorded, _guard} =
             unboxed(fn ->
               AgentRestartGuards.record_crash(
                 agent.id,
                 lease.owner_token,
                 :post_commit_crash,
                 backoffs_ms: [0]
               )
             end)
  end

  test "a transactional ready fence also holds the exact Binding lock", %{
    agent: agent,
    binding: binding
  } do
    lease =
      unboxed(fn ->
        {:ok, lease} = AgentLeases.claim(agent.id)
        {:ok, _ready} = AgentLeases.mark_ready(agent.id, lease.owner_token)
        lease
      end)

    parent = self()

    fenced =
      Task.async(fn ->
        unboxed(fn ->
          Repo.transaction(fn ->
            :ok = AgentLeases.fence_ready!(agent.id, lease.owner_token)
            send(parent, {:binding_fenced, self()})
            receive do: (:release_fence -> :committed)
          end)
        end)
      end)

    assert_receive {:binding_fenced, fenced_pid}

    blocked_revoke =
      Task.async(fn ->
        unboxed(fn ->
          with_lock_timeout(fn ->
            binding
            |> Repo.reload!()
            |> Ecto.Changeset.change(status: "revoked")
            |> Repo.update!()
          end)
        end)
      end)

    assert {:lock_timeout, %Postgrex.Error{} = lock_error} = Task.await(blocked_revoke)
    assert lock_error.postgres.code == :lock_not_available
    send(fenced_pid, :release_fence)
    assert {:ok, :committed} = Task.await(fenced)

    unboxed(fn ->
      binding
      |> Repo.reload!()
      |> Ecto.Changeset.change(status: "revoked")
      |> Repo.update!()
    end)

    refute unboxed(fn -> AgentLeases.ready?(agent.id, lease.owner_token) end)
  end

  defp with_lock_timeout(fun) do
    Repo.query!("SET lock_timeout TO '100ms'")

    try do
      fun.()
    rescue
      error in Postgrex.Error -> {:lock_timeout, error}
    after
      Repo.query!("SET lock_timeout TO 0")
    end
  end

  defp unboxed(fun), do: Sandbox.unboxed_run(Repo, fun)
end
