defmodule Maraithon.PrivacyErasureRaceTest do
  use ExUnit.Case, async: false

  import Ecto.Query

  alias Ecto.Adapters.SQL.Sandbox
  alias Maraithon.Accounts
  alias Maraithon.Accounts.User
  alias Maraithon.Agents
  alias Maraithon.Agents.Agent
  alias Maraithon.Privacy.ErasureAgentTarget
  alias Maraithon.Privacy.ErasureRequest
  alias Maraithon.PrivacyErasure
  alias Maraithon.Repo
  alias Maraithon.Runtime.BackgroundJob

  test "Agent creation and erasure request linearize on the locked user row" do
    user = unboxed(fn -> user_fixture("creation-first") end)
    on_exit(fn -> cleanup_user(user.id) end)
    parent = self()

    creator =
      Task.async(fn ->
        unboxed(fn ->
          Repo.transaction(fn ->
            _locked =
              Repo.one!(
                from(candidate in User, where: candidate.id == ^user.id, lock: "FOR UPDATE")
              )

            send(parent, {:creator_holds_user, self()})
            assert_receive :release_creator, 5_000

            {:ok, agent} =
              Agents.create_agent(%{
                user_id: user.id,
                behavior: "prompt_agent",
                status: "stopped"
              })

            agent
          end)
        end)
      end)

    assert_receive {:creator_holds_user, creator_pid}, 5_000

    requestor =
      Task.async(fn ->
        send(parent, :request_started)
        unboxed(fn -> PrivacyErasure.request_user(user.id) end)
      end)

    assert_receive :request_started, 5_000
    send(creator_pid, :release_creator)

    assert {:ok, %Agent{} = agent} = Task.await(creator, 5_000)
    assert {:ok, %ErasureRequest{} = request} = Task.await(requestor, 5_000)

    assert unboxed(fn ->
             Repo.exists?(
               from(target in ErasureAgentTarget,
                 where: target.request_id == ^request.id,
                 where: target.agent_id == ^agent.id
               )
             )
           end)
  end

  test "a committed request fence rejects a creation that was waiting on the user" do
    user = unboxed(fn -> user_fixture("request-first") end)
    on_exit(fn -> cleanup_user(user.id) end)
    parent = self()

    requestor =
      Task.async(fn ->
        unboxed(fn ->
          Repo.transaction(fn ->
            _locked =
              Repo.one!(
                from(candidate in User, where: candidate.id == ^user.id, lock: "FOR UPDATE")
              )

            {:ok, request} = PrivacyErasure.request_user(user.id)
            send(parent, {:request_fenced, self()})
            assert_receive :release_request, 5_000
            request
          end)
        end)
      end)

    assert_receive {:request_fenced, request_pid}, 5_000

    creator =
      Task.async(fn ->
        send(parent, :creator_started)

        unboxed(fn ->
          Agents.create_agent(%{
            user_id: user.id,
            behavior: "prompt_agent",
            status: "stopped"
          })
        end)
      end)

    assert_receive :creator_started, 5_000
    send(request_pid, :release_request)

    assert {:ok, %ErasureRequest{}} = Task.await(requestor, 5_000)
    assert {:error, :privacy_erasure_requested} = Task.await(creator, 5_000)
  end

  defp cleanup_user(nil), do: :ok

  defp cleanup_user(user_id) do
    unboxed(fn ->
      request_ids =
        Repo.all(
          from(request in ErasureRequest,
            where: request.subject_user_id == ^user_id,
            select: request.id
          )
        )

      Repo.delete_all(
        from(job in BackgroundJob,
          where: job.dedupe_key in ^Enum.map(request_ids, &("privacy-erasure:" <> &1))
        )
      )

      Repo.delete_all(from(request in ErasureRequest, where: request.id in ^request_ids))
      Repo.delete_all(from(agent in Agent, where: agent.user_id == ^user_id))
      Repo.delete_all(from(user in User, where: user.id == ^user_id))
    end)

    :ok
  end

  defp user_fixture(prefix) do
    email = "privacy-race-#{prefix}-#{System.unique_integer([:positive])}@example.com"
    {:ok, user} = Accounts.get_or_create_user_by_email(email)
    user
  end

  defp unboxed(fun), do: Sandbox.unboxed_run(Repo, fun)
end
