defmodule Maraithon.AgentSubscriptions do
  @moduledoc """
  Persistence and synchronization for agent pub/sub subscriptions.
  """

  import Ecto.Query

  alias Maraithon.Agents.Agent
  alias Maraithon.AgentSubscriptions.AgentSubscription
  alias Maraithon.Repo

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

  def sync_for_agent(%Agent{} = agent) do
    desired_topics = normalized_topics(get_in(agent.config || %{}, ["subscribe"]))
    now = DateTime.utc_now()
    metadata = %{"source" => "agent_config", "synced_from" => "config.subscribe"}

    Repo.transaction(fn ->
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
    end)
    |> case do
      {:ok, subscriptions} -> {:ok, subscriptions}
      {:error, reason} -> {:error, reason}
    end
  end

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
