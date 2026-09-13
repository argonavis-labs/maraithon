defmodule Maraithon.PeopleNetwork.Builder do
  @moduledoc "Builds unpublished projections and publishes only with a live task lease."
  import Ecto.Query
  alias Maraithon.Accounts.User

  alias Maraithon.PeopleNetwork.{
    Aggregate,
    Generation,
    Graph,
    Identity,
    Profile,
    ReadRepo,
    Snapshot,
    Sources
  }

  alias Maraithon.Repo
  alias Maraithon.Runtime.BackgroundJob
  alias Maraithon.Runtime.Coordination.{Scope, TaskAssignment, TaskClaims}

  def run(%BackgroundJob{user_id: user_id} = job) when is_binary(user_id) do
    previous_priority = Process.flag(:priority, :low)
    started = System.monotonic_time(:millisecond)
    now = DateTime.utc_now()

    try do
      cleanup(user_id)
      # Exists before any source read so a concurrent source purge revokes it.
      generation = ReadRepo.insert!(%Generation{user_id: user_id, as_of: now})
      identity = Identity.load(user_id)
      aggregate = Sources.reduce(user_id, now, Aggregate.new(identity, now), &Aggregate.add/2)
      aggregate = Maraithon.PeopleNetwork.Calendar.add_upcoming(user_id, now, aggregate)

      counts =
        Map.new(Aggregate.windows(), fn days ->
          profiles = Graph.profiles(aggregate, days)

          profiles
          |> Enum.map(fn profile ->
            %{
              generation_id: generation.id,
              window_days: days,
              node_id: profile.id,
              user_id: user_id,
              display_name: profile.name,
              rank: profile.rank_mass,
              profile: profile
            }
          end)
          |> Enum.chunk_every(250)
          |> Enum.each(&ReadRepo.insert_all(Profile, &1))

          {Integer.to_string(days),
           Enum.count(profiles, &(&1.message_count > 0 or &1.calendar_count > 0))}
        end)

      duration = System.monotonic_time(:millisecond) - started

      summary = %{
        sources: aggregate.sources,
        people: map_size(aggregate.nodes),
        active_people: counts,
        duration_ms: duration,
        warnings: aggregate.warnings
      }

      with {:ok, _} <- publish(job, generation, summary) do
        {:ok,
         %{source: "people_network", people: map_size(aggregate.nodes), duration_ms: duration}}
      end
    after
      Process.flag(:priority, previous_priority)
    end
  catch
    :people_network_budget_exceeded -> {:error, :people_network_budget_exceeded}
  end

  def run(_job), do: {:error, :missing_user_id}

  defp publish(job, generation, summary) do
    Repo.transaction(fn ->
      Repo.query!("SET LOCAL statement_timeout = '4000'", [])
      Repo.query!("SET LOCAL lock_timeout = '500'", [])
      fence_job!(job)

      user =
        Repo.one(
          from u in User,
            where: u.id == ^job.user_id and is_nil(u.privacy_erasure_requested_at),
            lock: "FOR SHARE"
        )

      if is_nil(user), do: Repo.rollback(:user_unavailable)

      now = DateTime.utc_now()

      {updated, _} =
        Repo.update_all(
          from(g in Generation, where: g.id == ^generation.id and is_nil(g.invalidated_at)),
          set: [completed_at: now, summary: summary]
        )

      if updated != 1, do: Repo.rollback(:sources_changed_during_build)

      # A late generation cannot replace one built from a newer source boundary.
      update =
        from s in Snapshot,
          where: s.refreshed_at < ^generation.as_of,
          update: [set: [generation_id: ^generation.id, refreshed_at: ^now]]

      Repo.insert_all(
        Snapshot,
        [%{user_id: job.user_id, generation_id: generation.id, refreshed_at: now}],
        conflict_target: [:user_id],
        on_conflict: update
      )

      Maraithon.PeopleNetwork.Compatibility.publish!(job.user_id, generation.id)
    end)
  end

  defp fence_job!(%BackgroundJob{coordination_task_assignment_id: id} = job) when is_binary(id) do
    case Repo.get(TaskAssignment, id) do
      %TaskAssignment{work_kind: "background_job", work_id: work_id, claim_token: token} =
          assignment
      when work_id == job.id and token == job.claim_token ->
        TaskClaims.fence_running!(assignment)

      _ ->
        Repo.rollback(:task_authority_lost)
    end
  end

  defp fence_job!(job) do
    if Scope.enabled?(), do: Repo.rollback(:task_authority_required)

    owned =
      Repo.one(
        from j in BackgroundJob,
          where: j.id == ^job.id and j.claim_token == ^job.claim_token and j.status == "running",
          lock: "FOR UPDATE",
          select: j.id
      )

    if is_nil(owned), do: Repo.rollback(:claim_lost)
  end

  defp cleanup(user_id) do
    cutoff = DateTime.add(DateTime.utc_now(), -1, :hour)

    ReadRepo.delete_all(
      from g in Generation,
        where: g.user_id == ^user_id and g.inserted_at < ^cutoff,
        where: g.id not in subquery(from s in Snapshot, select: s.generation_id)
    )
  end
end
