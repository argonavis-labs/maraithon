defmodule Maraithon.Delegations.Wakes do
  @moduledoc "Bounded, tenant-fair repair of lost coordinator wake-ups. No model or provider calls."
  import Ecto.Query
  alias Maraithon.Repo
  alias Maraithon.Delegations.{Delegation, Lifecycle}
  alias Maraithon.Runtime.{BackgroundJob, JobAuthority}

  def run_once(%BackgroundJob{} = job) do
    with {:ok, users} <-
           JobAuthority.transaction(job, fn ->
             current = Repo.get!(BackgroundJob, job.id) |> BackgroundJob.hydrate_payloads()
             cursor = current.payload["delegation_user_cursor"] || ""

             users =
               Repo.all(
                 from d in Delegation,
                   where: d.state not in ^Delegation.terminal_states(),
                   group_by: d.user_id,
                   order_by: [asc: fragment("? <= ?", d.user_id, ^cursor), asc: d.user_id],
                   select: d.user_id,
                   limit: 25
               )

             if users != [] do
               current
               |> BackgroundJob.changeset(%{
                 payload: Map.put(current.payload, "delegation_user_cursor", List.last(users))
               })
               |> Repo.update!()
             end

             users
           end) do
      results = Enum.map(users, &Lifecycle.ensure(&1, job: job))

      {:ok,
       %{
         users: length(users),
         repaired: Enum.count(results, &match?({:ok, _}, &1)),
         held: Enum.count(results, &match?({:error, _}, &1))
       }}
    end
  end
end
