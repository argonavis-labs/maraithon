defmodule Maraithon.Runtime.AgentWorkResultsTest do
  use Maraithon.DataCase, async: false

  alias Maraithon.Agents
  alias Maraithon.Agents.AgentRun
  alias Maraithon.ChiefLineageFixtures
  alias Maraithon.ChiefOfStaff.AcquisitionStore
  alias Maraithon.ChiefOfStaff.Projections
  alias Maraithon.ChiefOfStaff.Semantics
  alias Maraithon.Connectors.SourceCursorAdvancement
  alias Maraithon.Connectors.SourceCursorAdvancements
  alias Maraithon.Connectors.SourceCursors
  alias Maraithon.Repo
  alias Maraithon.Runtime.AgentDirectives
  alias Maraithon.Runtime.AgentLeases
  alias Maraithon.Runtime.AgentWorkResults
  alias Maraithon.Runtime.DatabaseClock

  test "one terminal transaction binds exact claim, run, acquisition, projection, and cursor" do
    fixture = complete_decision_fixture("work-result")

    assert {:ok, lease} = AgentLeases.claim(fixture.agent.id)
    assert {:ok, _ready} = AgentLeases.mark_ready(fixture.agent.id, lease.owner_token)

    assert {:ok, claimed} =
             AgentDirectives.claim_next(fixture.agent.id, fixture.user_id, lease.owner_token)

    assert {:ok, run} = Agents.start_agent_run(fixture.agent, %{trigger_type: "connector_sync"})
    assert {:ok, _draining} = AgentLeases.begin_draining(fixture.agent.id, lease.owner_token)

    proof = %{
      agent_directive_id: claimed.id,
      agent_id: fixture.agent.id,
      user_id: fixture.user_id,
      agent_run_id: run.id,
      claim_generation: lease.owner_token,
      claim_token: claimed.claim_token,
      outcome: "completed",
      terminal_event: "chief_cycle_completed",
      result: %{"projection_count" => 1}
    }

    assert {:error, :lineage_transaction_required} =
             AgentWorkResults.insert_provisional_in_transaction(proof, [fixture.complete])

    assert {:ok,
            %{result: result, receipt: receipt, advancement: advancement, directive: terminal}} =
             Repo.transaction(fn ->
               {:ok, provisional} =
                 AgentWorkResults.insert_provisional_in_transaction(proof, [fixture.complete])

               {:ok, receipt, :inserted} =
                 Projections.record_receipt_in_transaction(
                   provisional,
                   fixture.effect,
                   {:decision, fixture.decision},
                   %{"decision_key" => fixture.decision.decision_identity}
                 )

               {:ok, [advancement]} =
                 SourceCursorAdvancements.advance_in_transaction(provisional, [fixture.complete])

               now = DatabaseClock.now!()

               completed_run =
                 run
                 |> AgentRun.changeset(%{status: "completed", completed_at: now})
                 |> Repo.update!()

               assert completed_run.status == "completed"

               {:ok, terminal} =
                 AgentDirectives.complete(
                   fixture.agent.id,
                   claimed.id,
                   lease.owner_token,
                   claimed.claim_token
                 )

               {:ok, result} = AgentWorkResults.finalize_in_transaction(provisional)

               %{
                 result: result,
                 receipt: receipt,
                 advancement: advancement,
                 directive: terminal
               }
             end)

    assert result.status == "committed"
    assert result.agent_run_id == run.id
    assert result.claim_generation == lease.owner_token
    assert result.claim_token == claimed.claim_token
    assert byte_size(result.result_key) == 32
    assert terminal.status == "completed"
    assert receipt.decision_id == fixture.decision.id
    assert receipt.todo_id == nil
    assert receipt.projection_kind == "decision"

    assert %{value: "cursor-1"} = SourceCursors.get(fixture.account.id, fixture.cursor.kind)

    assert %SourceCursorAdvancement{expected_value: "cursor-0", advanced_value: "cursor-1"} =
             Repo.get_by!(SourceCursorAdvancement, agent_work_result_id: result.id)

    assert {:error, :acquisition_semantics_closed} =
             Semantics.put_effect(
               %{
                 acquisition_run_id: fixture.complete.id,
                 kind: "todo",
                 subject_key: "post-terminal:#{fixture.unique}",
                 contract_version: 1,
                 extractor_version: "fixture-v1",
                 payload: %{"title" => "Too late"}
               },
               [fixture.envelope.id]
             )

    assert_raw_check_violation(
      """
      INSERT INTO chief_semantic_effect_sources
      SELECT *
      FROM chief_semantic_effect_sources
      WHERE semantic_effect_id = $1::uuid
      LIMIT 1
      """,
      [Ecto.UUID.dump!(fixture.effect.id)],
      "chief semantic source proof set is closed by work-result linkage"
    )

    assert_raw_check_violation(
      """
      INSERT INTO chief_projection_receipts
      SELECT *
      FROM chief_projection_receipts
      WHERE id = $1::uuid
      """,
      [Ecto.UUID.dump!(receipt.id)],
      "committed agent work result cannot accept projection receipts"
    )

    assert_raw_check_violation(
      """
      INSERT INTO source_cursor_advancements
      SELECT *
      FROM source_cursor_advancements
      WHERE id = $1::uuid
      """,
      [Ecto.UUID.dump!(advancement.id)],
      "committed agent work result cannot accept cursor receipts"
    )

    assert {:ok, :released} = AgentLeases.release(fixture.agent.id, lease.owner_token)
  end

  test "stationary cursor proof locks exact state and persists an immutable no-op receipt" do
    fixture = complete_decision_fixture("work-result-no-op", "cursor-0")
    %{lease: lease, claimed: claimed, run: run, proof: proof} = claimed_work(fixture)

    assert {:ok, %{result: result, advancement: advancement}} =
             Repo.transaction(fn ->
               {:ok, provisional} =
                 AgentWorkResults.insert_provisional_in_transaction(proof, [fixture.complete])

               {:ok, _receipt, :inserted} =
                 Projections.record_receipt_in_transaction(
                   provisional,
                   fixture.effect,
                   {:decision, fixture.decision},
                   %{}
                 )

               {:ok, [advancement]} =
                 SourceCursorAdvancements.advance_in_transaction(provisional, [fixture.complete])

               now = DatabaseClock.now!()

               run
               |> AgentRun.changeset(%{status: "completed", completed_at: now})
               |> Repo.update!()

               {:ok, _terminal} =
                 AgentDirectives.complete(
                   fixture.agent.id,
                   claimed.id,
                   lease.owner_token,
                   claimed.claim_token
                 )

               {:ok, result} = AgentWorkResults.finalize_in_transaction(provisional)
               %{result: result, advancement: advancement}
             end)

    assert result.status == "committed"
    assert advancement.expected_value == "cursor-0"
    assert advancement.advanced_value == "cursor-0"
    assert advancement.acquisition_run_id == fixture.complete.id
    assert SourceCursors.get(fixture.account.id, fixture.cursor.kind).value == "cursor-0"
    assert {:ok, :released} = AgentLeases.release(fixture.agent.id, lease.owner_token)
  end

  test "cursor proof context rejects an omitted linked acquisition set" do
    fixture = complete_decision_fixture("work-result-omitted-acquisition")

    assert {:ok, cursorless, :inserted} =
             AcquisitionStore.begin_run(%{
               user_id: fixture.user_id,
               agent_id: fixture.agent.id,
               agent_directive_id: fixture.directive.id,
               runtime_ingress_receipt_id: fixture.receipt.id,
               connected_account_id: fixture.account.id,
               provider: fixture.provider,
               source: fixture.acquisition.source,
               scope_key: "cursorless-scope-#{fixture.unique}",
               request_key: "cursorless-request-#{fixture.unique}",
               contract_version: 1
             })

    assert {:ok, _page, [], :inserted} =
             ChiefLineageFixtures.terminal_page(%{fixture | acquisition: cursorless}, [])

    assert {:ok, cursorless_complete} = AcquisitionStore.seal_complete(cursorless, nil)
    %{proof: proof} = claimed_work(fixture)

    assert {:error, :omission_verified} =
             Repo.transaction(fn ->
               {:ok, provisional} =
                 AgentWorkResults.insert_provisional_in_transaction(proof, [
                   fixture.complete,
                   cursorless_complete
                 ])

               assert {:error, :cursor_acquisition_set_mismatch} =
                        SourceCursorAdvancements.advance_in_transaction(provisional, [
                          fixture.complete
                        ])

               Repo.rollback(:omission_verified)
             end)
  end

  test "database rejects a work-result acquisition directive mismatch" do
    fixture = complete_decision_fixture("work-result-directive-mismatch")
    %{proof: proof} = claimed_work(fixture)

    assert {:ok, other_directive} =
             AgentDirectives.enqueue(
               fixture.agent.id,
               fixture.user_id,
               "connector_sync",
               %{"source" => "fixture"},
               "chief-other-directive-#{fixture.unique}"
             )

    assert {:ok, other_acquisition, :inserted} =
             AcquisitionStore.begin_run(%{
               user_id: fixture.user_id,
               agent_id: fixture.agent.id,
               agent_directive_id: other_directive.id,
               runtime_ingress_receipt_id: fixture.receipt.id,
               connected_account_id: fixture.account.id,
               source_cursor_id: fixture.cursor.id,
               cursor_kind: fixture.cursor.kind,
               provider: fixture.provider,
               source: fixture.acquisition.source,
               scope_key: "other-directive-scope-#{fixture.unique}",
               request_key: "other-directive-request-#{fixture.unique}",
               contract_version: 1
             })

    assert {:ok, _page, [], :inserted} =
             ChiefLineageFixtures.terminal_page(%{fixture | acquisition: other_acquisition}, [])

    assert {:ok, other_complete} =
             AcquisitionStore.seal_complete(other_acquisition, "cursor-0")

    assert {:error, :directive_mismatch_verified} =
             Repo.transaction(fn ->
               {:ok, provisional} =
                 AgentWorkResults.insert_provisional_in_transaction(proof, [fixture.complete])

               assert {:error,
                       %Postgrex.Error{
                         postgres: %{
                           constraint: "agent_work_result_acquisitions_acquisition_owner_fkey"
                         }
                       }} =
                        Repo.query(
                          """
                          INSERT INTO agent_work_result_acquisitions (
                            agent_work_result_id, acquisition_run_id, user_id, agent_id,
                            agent_directive_id
                          )
                          VALUES ($1::uuid, $2::uuid, $3, $4::uuid, $5::uuid)
                          """,
                          [
                            Ecto.UUID.dump!(provisional.id),
                            Ecto.UUID.dump!(other_complete.id),
                            fixture.user_id,
                            Ecto.UUID.dump!(fixture.agent.id),
                            Ecto.UUID.dump!(fixture.directive.id)
                          ]
                        )

               Repo.rollback(:directive_mismatch_verified)
             end)
  end

  test "wrong and expired lease generations cannot create terminal proof" do
    fixture = complete_decision_fixture("work-result-fence")

    assert {:ok, lease} = AgentLeases.claim(fixture.agent.id)
    assert {:ok, _ready} = AgentLeases.mark_ready(fixture.agent.id, lease.owner_token)

    assert {:ok, claimed} =
             AgentDirectives.claim_next(fixture.agent.id, fixture.user_id, lease.owner_token)

    assert {:ok, run} = Agents.start_agent_run(fixture.agent, %{trigger_type: "connector_sync"})

    proof = %{
      agent_directive_id: claimed.id,
      agent_id: fixture.agent.id,
      user_id: fixture.user_id,
      agent_run_id: run.id,
      claim_generation: Ecto.UUID.generate(),
      claim_token: claimed.claim_token,
      outcome: "completed",
      terminal_event: "chief_cycle_completed",
      result: %{}
    }

    assert {:error, :runtime_lease_lost} =
             Repo.transaction(fn ->
               AgentWorkResults.insert_provisional_in_transaction(proof, [fixture.complete])
             end)

    Repo.query!(
      """
      UPDATE agent_runtime_leases
      SET claimed_at = timezone('UTC', clock_timestamp()) - interval '3 minutes',
          renewed_at = timezone('UTC', clock_timestamp()) - interval '2 minutes',
          lease_until = timezone('UTC', clock_timestamp()) - interval '1 minute',
          ready_at = NULL,
          updated_at = timezone('UTC', clock_timestamp())
      WHERE agent_id = $1::uuid
      """,
      [Ecto.UUID.dump!(fixture.agent.id)]
    )

    assert {:error, :runtime_lease_expired} =
             Repo.transaction(fn ->
               AgentWorkResults.insert_provisional_in_transaction(
                 %{proof | claim_generation: lease.owner_token},
                 [fixture.complete]
               )
             end)

    assert AgentWorkResults.get_for_directive(claimed.id) == nil
  end

  test "a lost runtime lease cannot create terminal proof" do
    fixture = complete_decision_fixture("work-result-lost-lease")

    assert {:ok, lease} = AgentLeases.claim(fixture.agent.id)
    assert {:ok, _ready} = AgentLeases.mark_ready(fixture.agent.id, lease.owner_token)

    assert {:ok, claimed} =
             AgentDirectives.claim_next(fixture.agent.id, fixture.user_id, lease.owner_token)

    assert {:ok, run} = Agents.start_agent_run(fixture.agent, %{trigger_type: "connector_sync"})

    Repo.query!(
      "DELETE FROM agent_runtime_leases WHERE agent_id = $1::uuid",
      [Ecto.UUID.dump!(fixture.agent.id)]
    )

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

    assert {:error, :runtime_lease_lost} =
             Repo.transaction(fn ->
               AgentWorkResults.insert_provisional_in_transaction(proof, [fixture.complete])
             end)

    assert AgentWorkResults.get_for_directive(claimed.id) == nil
  end

  test "a stale cursor rolls back provisional result and every terminal receipt" do
    fixture = complete_decision_fixture("work-result-conflict")

    assert {:ok, lease} = AgentLeases.claim(fixture.agent.id)
    assert {:ok, _ready} = AgentLeases.mark_ready(fixture.agent.id, lease.owner_token)

    assert {:ok, claimed} =
             AgentDirectives.claim_next(fixture.agent.id, fixture.user_id, lease.owner_token)

    assert {:ok, run} = Agents.start_agent_run(fixture.agent, %{trigger_type: "connector_sync"})

    assert {:ok, _changed} =
             SourceCursors.put(fixture.account, fixture.cursor.kind, %{"value" => "cursor-other"})

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

    assert {:error, {:cursor_conflict, cursor_id}} =
             Repo.transaction(fn ->
               {:ok, provisional} =
                 AgentWorkResults.insert_provisional_in_transaction(proof, [fixture.complete])

               {:ok, _receipt, :inserted} =
                 Projections.record_receipt_in_transaction(
                   provisional,
                   fixture.effect,
                   {:decision, fixture.decision},
                   %{}
                 )

               case SourceCursorAdvancements.advance_in_transaction(provisional, [
                      fixture.complete
                    ]) do
                 {:error, reason} -> Repo.rollback(reason)
                 {:ok, _advancements} -> flunk("stale cursor unexpectedly advanced")
               end
             end)

    assert cursor_id == fixture.cursor.id
    assert AgentWorkResults.get_for_directive(claimed.id) == nil
    assert Repo.aggregate(Maraithon.ChiefOfStaff.ProjectionReceipt, :count) == 0
    assert Repo.aggregate(SourceCursorAdvancement, :count) == 0
  end

  defp assert_raw_check_violation(sql, params, expected_message) do
    error =
      assert_raise Postgrex.Error, fn ->
        Repo.transaction(fn -> Repo.query!(sql, params) end, mode: :savepoint)
      end

    assert error.postgres.code == :check_violation
    assert error.postgres.message =~ expected_message
    assert %{rows: [[1]]} = Repo.query!("SELECT 1")
  end

  defp claimed_work(fixture) do
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

    %{lease: lease, claimed: claimed, run: run, proof: proof}
  end

  defp complete_decision_fixture(prefix, proposed_cursor \\ "cursor-1") do
    fixture = ChiefLineageFixtures.base(prefix)

    {:ok, _page, [envelope], :inserted} =
      ChiefLineageFixtures.terminal_page(fixture, [
        ChiefLineageFixtures.source_envelope(fixture)
      ])

    {:ok, complete} = AcquisitionStore.seal_complete(fixture.acquisition, proposed_cursor)

    {:ok, effect, :inserted} =
      Semantics.put_effect(
        %{
          acquisition_run_id: complete.id,
          kind: "decision",
          subject_key: "subject:#{fixture.unique}",
          contract_version: 1,
          extractor_version: "fixture-v1",
          payload: %{"question" => "Proceed?"}
        },
        [envelope.id]
      )

    {:ok, decision, :inserted} =
      Projections.put_decision(effect, %{
        decision_identity: "decision:#{fixture.unique}",
        kind: "approval",
        payload: %{"question" => "Proceed?"}
      })

    Map.merge(fixture, %{
      complete: complete,
      envelope: envelope,
      effect: effect,
      decision: decision
    })
  end
end
