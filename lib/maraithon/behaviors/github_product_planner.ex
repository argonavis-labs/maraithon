defmodule Maraithon.Behaviors.GitHubProductPlanner do
  @moduledoc """
  Compatibility wrapper for the installable PM Agent.

  The persisted behavior id remains `github_product_planner`, while the
  runtime implementation lives in `Maraithon.Behaviors.ProductManagerAgent`.
  """

  @behaviour Maraithon.Behaviors.Behavior

  defdelegate init(config), to: Maraithon.Behaviors.ProductManagerAgent
  defdelegate handle_wakeup(state, context), to: Maraithon.Behaviors.ProductManagerAgent

  defdelegate handle_effect_result(effect, state, context),
    to: Maraithon.Behaviors.ProductManagerAgent

  defdelegate next_wakeup(state), to: Maraithon.Behaviors.ProductManagerAgent
end
