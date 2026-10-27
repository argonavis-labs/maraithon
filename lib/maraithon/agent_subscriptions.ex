defmodule Maraithon.AgentSubscriptions do
  @moduledoc """
  Persistence and synchronization for agent pub/sub subscriptions.
  """

  import Ecto.Query

  alias Maraithon.AgentIsolation.Binding
  alias Maraithon.Agents.Agent
  alias Maraithon.AgentSubscriptions.AgentSubscription
  alias Maraithon.Repo
  alias Maraithon.Runtime.AgentLifecycleOperation
  alias Maraithon.Runtime.AgentRestartGuard
  alias Maraithon.Runtime.AgentRuntimeLease
  alias Maraithon.Runtime.DatabaseClock

  def list_for_agent(agent_id, opts \\ [])

  def list_for_agent(agent_id, opts) when is_binary(agent_id) do
    status = Keyword.get(opts, :status, "active")

    AgentSubscription
    |> where([subscription], subscription.agent_id == ^agent_id)
    |> maybe_filter_status(status)
    |> order_by([subscription], asc: subscription.topic, desc: subscription.updated_at)
    |> Repo.all()
  end

  def list_for_agent(_agent_id, _opts), do: []

  def list_topics_for_agent(agent_id) when is_binary(agent_id) do
    agent_id
    |> list_for_agent(status: "active")
    |> Enum.map(& &1.topic)
  end

  def list_topics_for_agent(_agent_id), do: []

  def list_active_topic_summaries(opts \\ []) do
    user_id = Keyword.get(opts, :user_id)
    project_id = Keyword.get(opts, :project_id)

    AgentSubscription
    |> where([subscription], subscription.status == "active")
    |> maybe_filter_user(user_id)
    |> maybe_filter_project(project_id)
    |> select([subscription], %{
      topic: subscription.topic,
      agent_id: subscription.agent_id,
      user_id: subscription.user_id,
      project_id: subscription.project_id,
      updated_at: subscription.updated_at
    })
    |> order_by([subscription], asc: subscription.topic)
    |> Repo.all()
    |> Enum.group_by(& &1.topic)
    |> Enum.map(fn {topic, subscriptions} ->
      %{
        topic: topic,
        subscriber_count: length(subscriptions),
        agent_ids: subscriptions |> Enum.map(& &1.agent_id) |> Enum.uniq(),
        user_ids:
          subscriptions |> Enum.map(& &1.user_id) |> Enum.reject(&is_nil/1) |> Enum.uniq(),
        project_ids:
          subscriptions |> Enum.map(& &1.project_id) |> Enum.reject(&is_nil/1) |> Enum.uniq(),
        updated_at:
          subscriptions
          |> Enum.map(& &1.updated_at)
          |> Enum.reject(&is_nil/1)
          |> Enum.max_by(&DateTime.to_unix(&1, :microsecond), fn -> nil end)
      }
    end)
    |> Enum.sort_by(& &1.topic)
  end

  def deactivate_for_agent(agent_id) when is_binary(agent_id) do
    now = DateTime.utc_now()

    AgentSubscription
    |> where([subscription], subscription.agent_id == ^agent_id)
    |> where([subscription], subscription.status == "active")
    |> Repo.update_all(set: [status: "inactive", updated_at: now])
  end

  def deactivate_for_agent(_agent_id), do: {0, nil}

  def sync_for_agent(%Agent{id: agent_id}) when is_binary(agent_id) do
    Repo.transaction(fn -> lock_and_sync!(agent_id) end)
    |> case do
      {:ok, subscriptions} -> {:ok, subscriptions}
      {:error, reason} -> {:error, reason}
    end
  end

  def sync_for_agent(_agent), do: {:error, :invalid_agent}

  @doc false
  def sync_for_agent_locked(%Agent{id: agent_id}) when is_binary(agent_id) do
    if Repo.in_transaction?() do
      {:ok, lock_and_sync!(agent_id)}
    else
      {:error, :transaction_required}
    end
  end

  defp lock_and_sync!(agent_id) do
    agent =
      Repo.one(from(agent in Agent, where: agent.id == ^agent_id, lock: "FOR UPDATE")) ||
        Repo.rollback(:agent_not_found)

    binding = lock_same_user_binding(agent)
    _guard = lock_guard(agent_id)
    _lease = lock_lease(agent_id)
    operation = lock_operation(agent_id)
    sync_locked!(agent, binding, operation)
  end

  defp sync_locked!(agent, binding, operation) do
    now = DatabaseClock.now!()
    metadata = %{"source" => "agent_config", "synced_from" => "config.subscribe"}

    desired_topics =
      if delivery_authorized?(agent, binding, operation),
        do: normalized_topics(get_in(agent.config || %{}, ["subscribe"])),
        else: []

    case upsert_desired_topics(agent, desired_topics, metadata, now) do
      :ok ->
        agent.id
        |> list_for_agent(status: nil)
        |> Enum.each(fn subscription ->
          if subscription.topic in desired_topics do
            :ok
          else
            subscription
            |> Ecto.Changeset.change(status: "inactive", updated_at: now)
            |> Repo.update!()
          end
        end)

        list_for_agent(agent.id, status: nil)

      {:error, reason} ->
        Repo.rollback(reason)
    end
  end

  defp lock_same_user_binding(%Agent{id: agent_id, user_id: user_id})
       when is_binary(user_id) do
    Repo.one(
      from(binding in Binding,
        where: binding.agent_id == ^agent_id,
        where: binding.user_id == ^user_id,
        lock: "FOR UPDATE"
      )
    )
  end

  defp lock_same_user_binding(_agent), do: nil

  defp lock_guard(agent_id) do
    Repo.one(
      from(guard in AgentRestartGuard,
        where: guard.agent_id == ^agent_id,
        lock: "FOR UPDATE"
      )
    )
  end

  defp lock_lease(agent_id) do
    Repo.one(
      from(lease in AgentRuntimeLease,
        where: lease.agent_id == ^agent_id,
        lock: "FOR UPDATE"
      )
    )
  end

  defp lock_operation(agent_id) do
    Repo.one(
      from(operation in AgentLifecycleOperation,
        where: operation.agent_id == ^agent_id,
        lock: "FOR UPDATE"
      )
    )
  end

  defp delivery_authorized?(
         %Agent{
           id: agent_id,
           user_id: user_id,
           status: status,
           install_status: "enabled"
         },
         %Binding{
           agent_id: binding_agent_id,
           user_id: binding_user_id,
           status: "active"
         },
         nil
       )
       when is_binary(user_id) and status in ["running", "degraded"] and
              binding_agent_id == agent_id and binding_user_id == user_id,
       do: true

  defp delivery_authorized?(_agent, _binding, _operation), do: false

  defp upsert_desired_topics(agent, desired_topics, metadata, now) do
    Enum.reduce_while(desired_topics, :ok, fn topic, :ok ->
      result =
        %AgentSubscription{}
        |> AgentSubscription.changeset(%{
          agent_id: agent.id,
          user_id: agent.user_id,
          project_id: agent.project_id,
          topic: topic,
          status: "active",
          metadata: metadata
        })
        |> Repo.insert(
          on_conflict: [
            set: [
              user_id: agent.user_id,
              project_id: agent.project_id,
              status: "active",
              metadata: metadata,
              updated_at: now
            ]
          ],
          conflict_target: [:agent_id, :topic]
        )

      case result do
        {:ok, _subscription} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp maybe_filter_status(query, nil), do: query
  defp maybe_filter_status(query, ""), do: query
  defp maybe_filter_status(query, "all"), do: query

  defp maybe_filter_status(query, status) when is_binary(status) do
    where(query, [subscription], subscription.status == ^status)
  end

  defp maybe_filter_user(query, nil), do: query
  defp maybe_filter_user(query, ""), do: query

  defp maybe_filter_user(query, user_id) when is_binary(user_id) do
    where(query, [subscription], subscription.user_id == ^user_id)
  end

  defp maybe_filter_project(query, nil), do: query
  defp maybe_filter_project(query, ""), do: query

  defp maybe_filter_project(query, project_id) when is_binary(project_id) do
    where(query, [subscription], subscription.project_id == ^project_id)
  end

  defp normalized_topics(topics) when is_list(topics) do
    topics
    |> Enum.map(&normalize_topic/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp normalized_topics(_topics), do: []

  defp normalize_topic(topic) when is_binary(topic) do
    case String.trim(topic) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_topic(_topic), do: nil
end
