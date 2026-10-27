defmodule MaraithonAgentLab.MeetingSpecialist do
  @moduledoc """
  Jido boundary experiment. The host retains run ownership and performs model
  calls. This specialist accepts fenced observations and returns proposals only.
  No AgentServer, scheduler, external action, or second persistence authority.
  """
  use Jido.Agent,
    name: "meeting_preparation",
    schema: [
      owner: [type: :string, required: true],
      generation: [type: :integer, required: true],
      observations: [type: :list, default: []],
      proposal: [type: :any, default: %{}],
      status: [type: :atom, default: :preparing]
    ]

  defmodule Observe do
    use Jido.Action,
      name: "meeting_observation",
      schema: [
        owner: [type: :string, required: true],
        generation: [type: :integer, required: true],
        observation: [type: :any, required: true]
      ]

    def run(params, context) do
      state = context.state

      if params.owner == state.owner and params.generation == state.generation do
        {:ok, %{observations: state.observations ++ [params.observation]}}
      else
        {:error, :stale_owner}
      end
    end
  end

  defmodule Propose do
    use Jido.Action,
      name: "meeting_proposal",
      schema: [
        owner: [type: :string, required: true],
        generation: [type: :integer, required: true],
        proposal: [type: :any, required: true]
      ]

    def run(params, context) do
      state = context.state

      if params.owner == state.owner and params.generation == state.generation do
        {:ok, %{proposal: params.proposal, status: :awaiting_review}}
      else
        {:error, :stale_owner}
      end
    end
  end
end
