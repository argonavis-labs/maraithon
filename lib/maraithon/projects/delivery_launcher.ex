defmodule Maraithon.Projects.DeliveryLauncher do
  @moduledoc """
  Runtime handoff for project implementation runs.
  """

  alias Maraithon.Runtime

  def launch(project, recommendation, decision, agent) do
    launch(project, recommendation, decision, agent, nil)
  end

  def launch(project, recommendation, decision, agent, run) do
    with {:ok, _agent} <- ensure_agent_running(agent),
         {:ok, %{message_id: message_id}} <-
           Runtime.send_message(agent.id, build_message(project, recommendation, decision), %{
             "project_id" => project.id,
             "project_name" => project.name,
             "delivery_loop" => "project_implementation_run",
             "implementation_run_id" => run && run.id,
             "recommendation_decision_id" => decision.id,
             "source_insight_id" => recommendation.id
           }) do
      {:ok,
       %{
         status: launcher_status(agent.behavior),
         result_summary: launcher_summary(project, recommendation, agent),
         metadata: %{
           "delivery_agent_id" => agent.id,
           "delivery_agent_behavior" => agent.behavior,
           "runtime_message_id" => message_id
         }
       }}
    end
  end

  defp ensure_agent_running(%{status: status} = agent) when status in ["running", "degraded"],
    do: {:ok, agent}

  defp ensure_agent_running(agent), do: Runtime.start_existing_agent(agent.id)

  defp launcher_status("repo_planner"), do: "pending_plan"
  defp launcher_status(_behavior), do: "running"

  defp launcher_summary(project, recommendation, agent) do
    agent_name = get_in(agent.config || %{}, ["name"]) || agent.behavior

    case agent.behavior do
      "repo_planner" ->
        "Queued #{recommendation.title} with #{agent_name} for #{project.name}. Maraithon asked it to turn the accepted recommendation into an implementation plan."

      _ ->
        "Queued #{recommendation.title} with #{agent_name} for #{project.name}."
    end
  end

  defp build_message(project, recommendation, decision) do
    plan = Jason.encode!(decision.accepted_plan || %{})

    """
    Project: #{project.name}
    Recommendation: #{recommendation.title}

    Accepted plan JSON:
    #{plan}

    Execute the next step for this accepted project recommendation. Ground your work in the accepted plan and project context, and report concrete progress or blockers.
    """
  end
end
