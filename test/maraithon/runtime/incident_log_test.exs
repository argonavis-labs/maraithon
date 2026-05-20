defmodule Maraithon.Runtime.IncidentLogTest do
  use Maraithon.DataCase, async: true

  alias Maraithon.Agents
  alias Maraithon.Runtime.IncidentLog
  alias Maraithon.Runtime.RuntimeIncident

  defmodule FailingRepo do
    def insert(_changeset), do: raise("database unavailable")
  end

  test "records runtime incidents and queries by time and kind" do
    {:ok, agent} =
      Agents.create_agent(%{
        behavior: "prompt_agent",
        status: "running",
        config: %{}
      })

    occurred_at = ~U[2026-05-20 09:00:00Z]

    assert {:ok, incident} =
             IncidentLog.record(%{
               kind: :agent_crash,
               agent_id: agent.id,
               reason: {:shutdown, :boom},
               metadata: %{"sequence" => 12},
               occurred_at: occurred_at
             })

    assert incident.kind == "agent_crash"
    assert incident.reason =~ ":boom"
    assert incident.metadata["sequence"] == 12
    assert incident.node == Atom.to_string(node())

    assert [since_incident] = IncidentLog.since(~U[2026-05-20 08:00:00Z])
    assert since_incident.id == incident.id

    assert [kind_incident] = IncidentLog.by_kind(:agent_crash, since: ~U[2026-05-20 08:00:00Z])
    assert kind_incident.id == incident.id

    assert %{"agent_crash" => 1} = IncidentLog.count_by_kind([incident])
  end

  test "supports every planned incident kind" do
    for kind <- RuntimeIncident.kinds() do
      assert {:ok, incident} = IncidentLog.record(%{kind: kind})
      assert incident.kind == kind
    end
  end

  test "uptime segments close clean and unclean node windows" do
    assert {:ok, _} =
             IncidentLog.record(%{
               kind: :node_boot,
               occurred_at: ~U[2026-05-20 08:00:00Z]
             })

    assert {:ok, _} =
             IncidentLog.record(%{
               kind: :node_shutdown,
               occurred_at: ~U[2026-05-20 09:00:00Z]
             })

    assert {:ok, _} =
             IncidentLog.record(%{
               kind: :node_boot,
               occurred_at: ~U[2026-05-20 10:00:00Z]
             })

    assert [clean_segment, open_segment] =
             IncidentLog.uptime_segments(~U[2026-05-20 07:00:00Z],
               now: ~U[2026-05-20 11:00:00Z]
             )

    assert clean_segment.clean_shutdown?
    assert same_second?(clean_segment.started_at, ~U[2026-05-20 08:00:00Z])
    assert same_second?(clean_segment.ended_at, ~U[2026-05-20 09:00:00Z])

    assert is_nil(open_segment.clean_shutdown?)
    assert same_second?(open_segment.started_at, ~U[2026-05-20 10:00:00Z])
    assert same_second?(open_segment.ended_at, ~U[2026-05-20 11:00:00Z])
  end

  test "record is best-effort when the repo raises" do
    assert {:error, %RuntimeError{message: "database unavailable"}} =
             IncidentLog.record(%{kind: :node_boot}, repo: FailingRepo)
  end

  defp same_second?(left, right) do
    left
    |> DateTime.truncate(:second)
    |> DateTime.compare(DateTime.truncate(right, :second))
    |> Kernel.==(:eq)
  end
end
