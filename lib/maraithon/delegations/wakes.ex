defmodule Maraithon.Delegations.Wakes do
  @moduledoc "Bounded, tenant-fair repair of lost coordinator wake-ups. No model or provider calls."
  import Ecto.Query
  alias Maraithon.Repo
  alias Maraithon.Delegations.{Delegation, Lifecycle}
  alias Maraithon.Runtime.{BackgroundJob, DatabaseClock, JobAuthority}

  def run_once(%BackgroundJob{} = job) do
    with {:ok, users} <-
           JobAuthority.transaction(job, fn ->
             current = Repo.get!(BackgroundJob, job.id) |> BackgroundJob.hydrate_payloads()
             cursor = current.payload["delegation_user_cursor"] || ""

             idle = from a in Lifecycle.idle_coordinators(DatabaseClock.now!()), select: a.user_id

             candidates =
               from d in Delegation,
                 where: d.state not in ^Delegation.terminal_states(),
                 select: d.user_id,
                 union: ^idle

             users =
               Repo.all(
                 from u in subquery(candidates),
                   order_by: [asc: fragment("? <= ?", u.user_id, ^cursor), asc: u.user_id],
                   select: u.user_id,
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
         repaired: Enum.count(results, &match?({:ok, %Maraithon.Agents.Agent{}}, &1)),
         retired: Enum.count(results, &match?({:ok, :retired}, &1)),
         retiring: Enum.count(results, &match?({:ok, :retiring}, &1)),
         held: Enum.count(results, &match?({:error, _}, &1))
       }}
    end
  end
end
