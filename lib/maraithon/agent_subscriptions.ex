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
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    metadata = %{"source" => "agent_config", "synced_from" => "config.subscribe"}

    Repo.transaction(fn ->
      Enum.each(desired_topics, fn topic ->
        %AgentSubscription{}
        |> AgentSubscription.changeset(%{
          agent_id: agent.id,
          user_id: agent.user_id,
          project_id: agent.project_id,
          topic: topic,
          status: "active",
          metadata: metadata
        })
        |> Repo.insert!(
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
      end)

      stale_query =
        AgentSubscription
        |> where([subscription], subscription.agent_id == ^agent.id)
        |> exclude_desired_topics(desired_topics)

      Repo.update_all(stale_query, set: [status: "inactive", updated_at: now])

      list_for_agent(agent.id, status: nil)
    end)
    |> case do
      {:ok, subscriptions} -> {:ok, subscriptions}
      {:error, reason} -> {:error, reason}
    end
  end

  defp maybe_filter_status(query, nil), do: query
  defp maybe_filter_status(query, ""), do: query
  defp maybe_filter_status(query, "all"), do: query

  defp maybe_filter_status(query, status) when is_binary(status) do
    where(query, [subscription], subscription.status == ^status)
  end

  defp exclude_desired_topics(query, []), do: query

  defp exclude_desired_topics(query, desired_topics) when is_list(desired_topics) do
    where(query, [subscription], subscription.topic not in ^desired_topics)
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
