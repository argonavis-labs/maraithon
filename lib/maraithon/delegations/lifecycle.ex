defmodule Maraithon.Delegations.Lifecycle do
  @moduledoc "One supervised coordinator per user, only while conversations need it."
  import Ecto.Query
  alias Maraithon.{Repo, Runtime, DurablePayload}
  alias Maraithon.Delegations.{Delegation, Outbox}
  alias Maraithon.PrivacyErasure.WriteFence

  def ensure(user_id, opts \\ []) do
    if Repo.exists?(
         from d in Delegation,
           where: d.user_id == ^user_id and d.state not in ^Delegation.terminal_states()
       ) do
      with {:ok, agent} <- Runtime.ensure_delegation_coordinator(user_id, consent(user_id), opts),
           {:ok, _} <-
             Repo.transaction(fn ->
               if job = Keyword.get(opts, :job), do: Maraithon.Runtime.JobAuthority.fence!(job)
               DurablePayload.require_current_mutation!()
               WriteFence.lock_user_writable!(user_id)

               Repo.all(
                 from d in Delegation,
                   where:
                     d.user_id == ^user_id and d.state not in ^Delegation.terminal_states() and
                       (is_nil(d.agent_id) or d.agent_id != ^agent.id),
                   lock: "FOR UPDATE",
                   limit: 100
               )
               |> Enum.each(fn row ->
                 row
                 |> Delegation.hydrate()
                 |> Delegation.changeset(%{agent_id: agent.id})
                 |> Repo.update!()
               end)
             end) do
        Outbox.publish_pending(user_id)
        {:ok, agent}
      end
    else
      {:ok, :no_live_conversations}
    end
  end

  defp consent(user_id) do
    %{
      "actor_id" => user_id,
      "user_id" => user_id,
      "identity_key" => "delegations:#{user_id}",
      "credential_refs" => %{},
      "connector_scope" => %{},
      "memory_scope" => %{},
      "tool_policy" => %{"allowed_tools" => []},
      "routing_bindings" => %{},
      "metadata" => %{"authority" => "versioned_delegation_grants"}
    }
  end
end
