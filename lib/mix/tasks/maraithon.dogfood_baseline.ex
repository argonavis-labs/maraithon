defmodule Mix.Tasks.Maraithon.DogfoodBaseline do
  @moduledoc """
  Records a day-0 dogfood baseline as a node_boot runtime incident.
  """

  use Mix.Task

  alias Maraithon.Runtime.IncidentLog

  @shortdoc "Record a dogfood runtime baseline"

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("app.start")

    case IncidentLog.record(%{
           kind: :node_boot,
           metadata: %{
             "source" => "mix_task",
             "baseline" => IncidentLog.backlog_snapshot()
           }
         }) do
      {:ok, incident} ->
        Mix.shell().info("Recorded dogfood baseline incident #{incident.id}")

      {:error, reason} ->
        Mix.shell().error("Failed to record dogfood baseline: #{inspect(reason)}")
    end
  end
end
