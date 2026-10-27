defmodule Maraithon.ChiefOfStaff.SemanticClosureRaceTest do
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Maraithon.Agents
  alias Maraithon.Agents.AgentRun
  alias Maraithon.ChiefLineageFixtures
  alias Maraithon.ChiefOfStaff.AcquisitionStore
  alias Maraithon.ChiefOfStaff.Projections
  alias Maraithon.ChiefOfStaff.Semantics
  alias Maraithon.Connectors.SourceCursorAdvancements
  alias Maraithon.Repo
  alias Maraithon.Runtime.AgentDirectives
  alias Maraithon.Runtime.AgentLeases
  alias Maraithon.Runtime.AgentWorkResults
  alias Maraithon.Runtime.DatabaseClock

  test "semantic insertion physically racing terminal linkage serializes and loses after linkage" do
    fixture = Sandbox.unboxed_run(Repo, fn -> race_fixture() end)

    on_exit(fn ->
      Sandbox.unboxed_run(Repo, fn ->
        _ = AgentLeases.release(fixture.agent.id, fixture.lease.owner_token)

        Repo.query!(
          "DELETE FROM chief_projection_receipts WHERE agent_id = $1::uuid",
          [Ecto.UUID.dump!(fixture.agent.id)]
        )

        Repo.query!(
          "DELETE FROM source_cursor_advancements WHERE acquisition_run_id = $1::uuid",
          [Ecto.UUID.dump!(fixture.complete.id)]
        )

        Repo.query!(
          "DELETE FROM agent_work_result_acquisitions WHERE acquisition_run_id = $1::uuid",
          [Ecto.UUID.dump!(fixture.complete.id)]
        )

        Repo.query!("DELETE FROM agents WHERE id = $1::uuid", [Ecto.UUID.dump!(fixture.agent.id)])
        Repo.query!("DELETE FROM users WHERE id = $1", [fixture.user_id])
      end)
    end)

    parent = self()

    terminal_task =
      Task.async(fn ->
        Sandbox.unboxed_run(Repo, fn ->
          Repo.transaction(fn ->
            {:ok, provisional} =
              AgentWorkResults.insert_provisional_in_transaction(fixture.proof, [
                fixture.complete
              ])

            send(parent, {:acquisition_linked, self()})

            receive do
              :finish_terminal_transaction -> :ok
            after
              5_000 -> Repo.rollback(:terminal_race_timeout)
            end

            {:ok, _receipt, :inserted} =
              Projections.record_receipt_in_transaction(
                provisional,
                fixture.effect,
                {:decision, fixture.decision},
                %{"race" => true}
              )

            {:ok, [_advancement]} =
              SourceCursorAdvancements.advance_in_transaction(provisional, [fixture.complete])

            now = DatabaseClock.now!()

            fixture.run
            |> AgentRun.changeset(%{status: "completed", completed_at: now})
            |> Repo.update!()

            {:ok, _terminal} =
              AgentDirectives.complete(
                fixture.agent.id,
                fixture.claimed.id,
                fixture.lease.owner_token,
                fixture.claimed.claim_token
              )

            AgentWorkResults.finalize_in_transaction(provisional)
          end)
        end)
      end)

    assert_receive {:acquisition_linked, terminal_pid}, 5_000

    semantic_task =
      Task.async(fn ->
        Sandbox.unboxed_run(Repo, fn ->
          Semantics.put_effect(
            %{
              acquisition_run_id: fixture.complete.id,
              kind: "todo",
              subject_key: "racing-semantic:#{fixture.unique}",
              contract_version: 1,
              extractor_version: "fixture-v1",
              payload: %{"title" => "Must lose the race"}
            },
            [fixture.envelope.id]
          )
        end)
      end)

    assert Task.yield(semantic_task, 150) == nil
    send(terminal_pid, :finish_terminal_transaction)

    assert {:ok, {:ok, committed}} = Task.await(terminal_task, 10_000)
    assert committed.status == "committed"
    assert {:error, :acquisition_semantics_closed} = Task.await(semantic_task, 10_000)
  end

  defp race_fixture do
    fixture = ChiefLineageFixtures.base("semantic-physical-race")

    {:ok, _page, [envelope], :inserted} =
      ChiefLineageFixtures.terminal_page(fixture, [
        ChiefLineageFixtures.source_envelope(fixture)
      ])

    {:ok, complete} = AcquisitionStore.seal_complete(fixture.acquisition, "cursor-1")

    {:ok, effect, :inserted} =
      Semantics.put_effect(
        %{
          acquisition_run_id: complete.id,
          kind: "decision",
          subject_key: "race-subject:#{fixture.unique}",
          contract_version: 1,
          extractor_version: "fixture-v1",
          payload: %{"question" => "Proceed?"}
        },
        [envelope.id]
      )

    {:ok, decision, :inserted} =
      Projections.put_decision(effect, %{
        decision_identity: "race-decision:#{fixture.unique}",
        kind: "approval",
        payload: %{"question" => "Proceed?"}
      })

    {:ok, lease} = AgentLeases.claim(fixture.agent.id)
    {:ok, _ready} = AgentLeases.mark_ready(fixture.agent.id, lease.owner_token)

    {:ok, claimed} =
      AgentDirectives.claim_next(fixture.agent.id, fixture.user_id, lease.owner_token)

    {:ok, run} = Agents.start_agent_run(fixture.agent, %{trigger_type: "connector_sync"})
    {:ok, _draining} = AgentLeases.begin_draining(fixture.agent.id, lease.owner_token)

    proof = %{
      agent_directive_id: claimed.id,
      agent_id: fixture.agent.id,
      user_id: fixture.user_id,
      agent_run_id: run.id,
      claim_generation: lease.owner_token,
      claim_token: claimed.claim_token,
      outcome: "completed",
      terminal_event: "chief_cycle_completed",
      result: %{}
    }

    Map.merge(fixture, %{
      complete: complete,
      envelope: envelope,
      effect: effect,
      decision: decision,
      lease: lease,
      claimed: claimed,
      run: run,
      proof: proof
    })
  end
end
