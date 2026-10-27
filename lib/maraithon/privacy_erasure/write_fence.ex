defmodule Maraithon.PrivacyErasure.WriteFence do
  @moduledoc """
  Storage-backed ingress fence for subjects with durable erasure intent.

  Mutating callers use the locking variants in the same transaction as their
  write. The row lock makes the write linearize with an erasure request, which
  takes the identical `users` lock before publishing the irreversible fence.
  Database triggers mirror this contract for raw/legacy writers.
  """

  import Ecto.Query

  alias Maraithon.Accounts.User
  alias Maraithon.Agents.Agent
  alias Maraithon.Privacy.ErasureAgentTarget
  alias Maraithon.Privacy.ErasureRequest
  alias Maraithon.Repo

  @doc "Returns `:ok` only while a user has no durable erasure fence."
  def check_user(user_id) when is_binary(user_id) do
    case Repo.one(
           from(user in User,
             where: user.id == ^user_id,
             select: user.privacy_erasure_requested_at
           )
         ) do
      nil ->
        if Repo.exists?(from(user in User, where: user.id == ^user_id)),
          do: :ok,
          else: {:error, :user_not_found}

      _requested_at ->
        {:error, :privacy_erasure_requested}
    end
  end

  def check_user(_user_id), do: {:error, :invalid_user}

  @doc "Locks the user and raises a transaction rollback once erasure is fenced."
  def lock_user_writable!(user_id) when is_binary(user_id) do
    require_transaction!()

    case Repo.one(from(user in User, where: user.id == ^user_id, lock: "FOR UPDATE")) do
      nil ->
        Repo.rollback(:user_not_found)

      %User{privacy_erasure_requested_at: nil} = user ->
        user

      %User{} ->
        Repo.rollback(:privacy_erasure_requested)
    end
  end

  def lock_user_writable!(_user_id), do: Repo.rollback(:invalid_user)

  @doc "Locks the Agent and fails closed after durable erasure intent."
  def ensure_agent_writable!(agent_id) when is_binary(agent_id) do
    require_transaction!()

    case Repo.one(from(agent in Agent, where: agent.id == ^agent_id, lock: "FOR UPDATE")) do
      nil -> Repo.rollback(:agent_not_found)
      %Agent{} -> ensure_no_active_agent_request!(agent_id)
    end
  end

  def ensure_agent_writable!(_agent_id), do: Repo.rollback(:invalid_agent_id)

  defp ensure_no_active_agent_request!(agent_id) do
    target_exists? =
      Repo.exists?(
        from(target in ErasureAgentTarget,
          join: request in ErasureRequest,
          on: request.id == target.request_id,
          where: target.agent_id == ^agent_id,
          where: request.state != "completed"
        )
      )

    request_exists? =
      Repo.exists?(
        from(request in ErasureRequest,
          where: request.scope == "agent",
          where: request.subject_agent_id == ^agent_id,
          where: request.state != "completed"
        )
      )

    if target_exists? or request_exists?,
      do: Repo.rollback(:privacy_erasure_requested),
      else: :ok
  end

  defp require_transaction! do
    unless Repo.in_transaction?(), do: raise("privacy write fence requires a transaction")
  end
end
