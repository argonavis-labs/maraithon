defmodule Mix.Tasks.Maraithon.Effects.Activate do
  use Mix.Task

  @shortdoc "Alias for maraithon.effects.activate_generation_fenced"

  @moduledoc """
  Backwards-compatible short alias for the canonical stopped-fleet cutover:

      mix maraithon.effects.activate --confirm NON_ROLLING_FLEET_DRAINED
  """

  @impl Mix.Task
  def run(args), do: Mix.Tasks.Maraithon.Effects.ActivateGenerationFenced.run(args)
end
