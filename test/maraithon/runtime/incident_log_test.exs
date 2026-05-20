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

    occurred_at = future_time(1)
    since = DateTime.add(occurred_at, -3_600, :second)

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

    assert Enum.any?(IncidentLog.since(since), &(&1.id == incident.id))

    assert [kind_incident] = IncidentLog.by_kind(:agent_crash, since: since)
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
    first_boot = future_time(1)
    first_shutdown = future_time(2)
    second_boot = future_time(3)
    since = DateTime.add(first_boot, -3_600, :second)
    now = future_time(4)

    assert {:ok, _} =
             IncidentLog.record(%{
               kind: :node_boot,
               occurred_at: first_boot
             })

    assert {:ok, _} =
             IncidentLog.record(%{
               kind: :node_shutdown,
               occurred_at: first_shutdown
             })

    assert {:ok, _} =
             IncidentLog.record(%{
               kind: :node_boot,
               occurred_at: second_boot
             })

    assert [clean_segment, open_segment] = IncidentLog.uptime_segments(since, now: now)

    assert clean_segment.clean_shutdown?
    assert same_second?(clean_segment.started_at, first_boot)
    assert same_second?(clean_segment.ended_at, first_shutdown)

    assert is_nil(open_segment.clean_shutdown?)
    assert same_second?(open_segment.started_at, second_boot)
    assert same_second?(open_segment.ended_at, now)
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

  defp future_time(hours_from_now) do
    DateTime.utc_now()
    |> DateTime.add(24 * 3_600 + hours_from_now * 3_600, :second)
    |> DateTime.truncate(:second)
  end
end
