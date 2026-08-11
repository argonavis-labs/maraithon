defmodule Maraithon.DurablePayloadPrivacyTest do
  use Maraithon.DataCase, async: false

  alias Maraithon.Agents
  alias Maraithon.Agents.Agent
  alias Maraithon.Agents.AgentRun
  alias Maraithon.Agents.AgentRunStep
  alias Maraithon.DurablePayloadPrivacy
  alias Maraithon.DurablePayloadVerification
  alias Maraithon.Effects.ProtocolCutover
  alias Maraithon.Events
  alias Maraithon.Events.Event
  alias Maraithon.PrivacyRetention
  alias Maraithon.Runtime.Coordination.Protocol, as: CoordinationProtocol
  alias Maraithon.Spend

  @moduletag database_role: :session

  @evidence_id "test:stopped-fleet:durable-payload-privacy"
  @evidence_digest :crypto.hash(:sha256, "test durable payload privacy stopped fleet")
  @evidence_operator "durable-payload-privacy@example.test"
  @revision String.duplicate("c", 40)
  @activation_evidence [
    evidence_id: @evidence_id,
    evidence_digest: @evidence_digest,
    activated_by: @evidence_operator,
    revision: @revision
  ]
  @contraction_evidence [
    confirmation: "NON_ROLLING_FLEET_DRAINED",
    evidence_id: @evidence_id,
    evidence_digest: @evidence_digest,
    operator: @evidence_operator,
    revision: @revision
  ]

  @retired_key_guard "guard_durable_payload_retired_key_write_trigger"

  setup do
    assert ProtocolCutover.mode() == :legacy

    assert {:ok, attestation} =
             CoordinationProtocol.attest_effect_activation_evidence(@activation_evidence)

    assert attestation in [:attested, :already_attested]
    set_runtime_role!()

    {:ok, agent} =
      Agents.create_agent(%{behavior: "prompt_agent", config: %{}, status: "running"})

    %{agent: agent}
  end

  test "legacy mode dual-writes ciphertext before bounded backfill clears plaintext", %{
    agent: agent
  } do
    event_secret = "event-secret-that-must-not-be-plaintext"

    assert {:ok, event} =
             Events.append(agent.id, "effect_completed", %{
               result: %{
                 secret: event_secret,
                 usage: %{total_cost: 0.25, input_tokens: 11, output_tokens: 7}
               }
             })

    assert %{rows: [[legacy_event_payload, event_ciphertext, 0.25, 11, 7, 1]]} =
             Repo.query!(
               """
               SELECT payload, payload_ciphertext, spend_total_cost,
                      spend_input_tokens, spend_output_tokens, spend_llm_calls
               FROM events
               WHERE id = $1
               """,
               [event.id]
             )

    assert legacy_event_payload["result"]["secret"] == event_secret
    assert is_binary(event_ciphertext)
    assert :binary.match(event_ciphertext, event_secret) == :nomatch

    assert {:ok, %{migrated_events: 1, blocked_events: []}} =
             contract_payload_batch!(batch_size: 1)

    assert %{rows: [[%{}, promoted_event_ciphertext]]} =
             Repo.query!("SELECT payload, payload_ciphertext FROM events WHERE id = $1", [
               event.id
             ])

    assert is_binary(promoted_event_ciphertext)

    stored_event = Repo.get!(Event, event.id)
    assert stored_event.payload["result"]["secret"] == event_secret

    {:ok, run} = Agents.start_agent_run(agent)
    request_secret = "request-secret-that-must-not-be-plaintext"
    response_secret = "response-secret-that-must-not-be-plaintext"

    assert {:ok, step} =
             Agents.record_agent_run_step(run.id, agent.id, %{
               step_type: "tool_call",
               request_payload: %{token: request_secret}
             })

    assert {:ok, _step} =
             Agents.update_agent_run_step(step.id, %{
               status: "completed",
               response_payload: %{token: response_secret}
             })

    assert %{rows: [[legacy_request, request_ciphertext, legacy_response, response_ciphertext]]} =
             Repo.query!(
               """
               SELECT request_payload, request_payload_ciphertext,
                      response_payload, response_payload_ciphertext
               FROM agent_run_steps
               WHERE id = $1
               """,
               [Ecto.UUID.dump!(step.id)]
             )

    assert legacy_request == %{"token" => request_secret}
    assert legacy_response == %{"token" => response_secret}
    assert is_binary(request_ciphertext)
    assert is_binary(response_ciphertext)
    assert :binary.match(request_ciphertext, request_secret) == :nomatch
    assert :binary.match(response_ciphertext, response_secret) == :nomatch
    assert Agents.legacy_run_step_payload_encryption_backlogs().deferred == 1

    assert {:ok, _run} = Agents.complete_agent_run(run.id)

    assert {:ok, %{migrated_run_steps: 1, blocked_run_steps: []}} =
             contract_payload_batch!(batch_size: 1)

    assert %{rows: [[%{}, promoted_request, %{}, promoted_response]]} =
             Repo.query!(
               """
               SELECT request_payload, request_payload_ciphertext,
                      response_payload, response_payload_ciphertext
               FROM agent_run_steps
               WHERE id = $1
               """,
               [Ecto.UUID.dump!(step.id)]
             )

    assert is_binary(promoted_request)
    assert is_binary(promoted_response)

    stored_step = Repo.get!(AgentRunStep, step.id)
    assert stored_step.request_payload == %{"token" => request_secret}
    assert stored_step.response_payload == %{"token" => response_secret}
  end

  test "payload changesets reject non-JSON, oversized, and key-colliding bodies", %{agent: agent} do
    assert {:error, event_changeset} =
             Events.append(agent.id, "invalid", %{
               "body" => String.duplicate("x", 512_001)
             })

    assert "must be a bounded JSON object" in errors_on(event_changeset).payload

    assert {:error, event_changeset} =
             Events.append(agent.id, "invalid", %{"callback" => fn -> :ok end})

    assert "must be a bounded JSON object" in errors_on(event_changeset).payload

    assert {:error, event_changeset} =
             Events.append(agent.id, "invalid", %{:status => "ok", "status" => "failed"})

    assert "must be a bounded JSON object" in errors_on(event_changeset).payload

    {:ok, run} = Agents.start_agent_run(agent)

    assert {:error, request_changeset} =
             Agents.record_agent_run_step(run.id, agent.id, %{
               step_type: "tool_call",
               request_payload: %{"body" => String.duplicate("x", 192_001)}
             })

    assert "must be a bounded JSON object" in errors_on(request_changeset).request_payload

    {:ok, step} =
      Agents.record_agent_run_step(run.id, agent.id, %{
        step_type: "tool_call",
        request_payload: %{"safe" => true}
      })

    assert {:error, response_changeset} =
             Agents.update_agent_run_step(step.id, %{
               status: "completed",
               response_payload: %{"body" => String.duplicate("x", 512_001)}
             })

    assert "must be a bounded JSON object" in errors_on(response_changeset).response_payload
    assert Repo.get!(AgentRunStep, step.id).status == "requested"
  end

  test "legacy JSONB rows remain readable only when ciphertext is absent", %{agent: agent} do
    now = DateTime.utc_now()

    {1, [%{id: event_id}]} =
      Repo.insert_all(
        "events",
        [
          %{
            agent_id: Ecto.UUID.dump!(agent.id),
            sequence_num: 77,
            event_type: "effect_completed",
            payload: %{
              "source" => "legacy",
              "result" => %{
                "usage" => %{"total_cost" => 2.0, "input_tokens" => 20, "output_tokens" => 9}
              }
            },
            inserted_at: now
          }
        ],
        returning: [:id]
      )

    assert [%{id: ^event_id, payload: %{"source" => "legacy"} = legacy_payload}] =
             Events.list_events(agent.id, after_seq: 76)

    assert legacy_payload["result"]["usage"]["total_cost"] == 2.0
    assert Spend.get_agent_spend(agent.id).total_cost == 0.0

    {:ok, run} = Agents.start_agent_run(agent)
    step_id = Ecto.UUID.generate()

    {1, _rows} =
      Repo.insert_all("agent_run_steps", [
        %{
          id: Ecto.UUID.dump!(step_id),
          agent_run_id: Ecto.UUID.dump!(run.id),
          agent_id: Ecto.UUID.dump!(agent.id),
          sequence: 1,
          step_type: "legacy_tool",
          status: "requested",
          request_payload: %{"source" => "legacy_request"},
          response_payload: %{"source" => "legacy_response"},
          started_at: now,
          inserted_at: now,
          updated_at: now
        }
      ])

    assert [%AgentRun{steps: [listed_step]}] =
             Agents.list_agent_runs(agent.id, preload: [:steps])

    assert listed_step.request_payload == %{"source" => "legacy_request"}
    assert listed_step.response_payload == %{"source" => "legacy_response"}

    assert %{legacy_events: 1, legacy_run_steps: 0, deferred_run_steps: 1} =
             DurablePayloadPrivacy.preflight()

    assert {:ok, _step} =
             Agents.update_agent_run_step(step_id, %{status: "completed"})

    assert {:ok, _run} = Agents.complete_agent_run(run.id)

    assert {:ok, result} =
             contract_payloads!(batch_size: 1, max_batches: 5)

    assert result.migrated_events == 1
    assert result.migrated_run_steps == 1
    assert result.blocked_events == []
    assert result.blocked_run_steps == []

    assert %{
             legacy_events: 0,
             legacy_run_steps: 0,
             deferred_run_steps: 0,
             legacy_snapshots: 0,
             in_flight: %{total: 0}
           } = result.remaining

    assert Spend.get_agent_spend(agent.id) == %{
             total_cost: 2.0,
             input_tokens: 20,
             output_tokens: 9,
             llm_calls: 1
           }
  end

  test "operator backfill reports blocked legacy rows without returning payload content", %{
    agent: agent
  } do
    secret = "blocked-secret-that-must-not-be-returned"

    {1, [%{id: event_id}]} =
      Repo.insert_all(
        "events",
        [
          %{
            agent_id: Ecto.UUID.dump!(agent.id),
            sequence_num: 88,
            event_type: "legacy_oversized",
            payload: %{"body" => secret <> String.duplicate("x", 512_001)},
            inserted_at: DateTime.utc_now()
          }
        ],
        returning: [:id]
      )

    assert {:ok, result} =
             contract_payloads!(batch_size: 1, max_batches: 3)

    assert result.migrated_events == 0
    assert result.blocked_events == [%{id: event_id, errors: [:payload_out_of_bounds]}]
    assert result.remaining.legacy_events == 1
    refute inspect(result) =~ secret

    assert %{rows: [[nil, legacy_payload]]} =
             Repo.query!("SELECT payload_ciphertext, payload FROM events WHERE id = $1", [
               event_id
             ])

    assert legacy_payload["body"] =~ secret
  end

  test "corrupt Event ciphertext fails closed instead of falling back to legacy JSONB", %{
    agent: agent
  } do
    {:ok, event} = Events.append(agent.id, "sensitive", %{"secret" => "encrypted"})

    corrupt = <<0, 1, 2, 3, 4>>

    assert_raise Postgrex.Error, ~r/invalid key tag envelope/, fn ->
      Repo.transaction(
        fn ->
          Repo.query!("UPDATE events SET payload_ciphertext = $1 WHERE id = $2", [
            corrupt,
            event.id
          ])
        end,
        mode: :savepoint
      )
    end

    seed_preexisting_ciphertext!("events", fn ->
      Repo.query!("UPDATE events SET payload_ciphertext = $1 WHERE id = $2", [
        corrupt,
        event.id
      ])
    end)

    assert_raise ArgumentError, fn -> Repo.get!(Event, event.id) end
    assert_raise ArgumentError, fn -> Events.list_events(agent.id) end
  end

  test "corrupt AgentRunStep ciphertext fails closed", %{agent: agent} do
    {:ok, run} = Agents.start_agent_run(agent)

    {:ok, step} =
      Agents.record_agent_run_step(run.id, agent.id, %{
        step_type: "tool_call",
        request_payload: %{"secret" => "encrypted"}
      })

    corrupt = <<0, 1, 2, 3, 4>>

    assert_raise Postgrex.Error, ~r/invalid key tag envelope/, fn ->
      Repo.transaction(
        fn ->
          Repo.query!(
            "UPDATE agent_run_steps SET request_payload_ciphertext = $1 WHERE id = $2",
            [corrupt, Ecto.UUID.dump!(step.id)]
          )
        end,
        mode: :savepoint
      )
    end

    seed_preexisting_ciphertext!("agent_run_steps", fn ->
      Repo.query!(
        "UPDATE agent_run_steps SET request_payload_ciphertext = $1 WHERE id = $2",
        [corrupt, Ecto.UUID.dump!(step.id)]
      )
    end)

    assert_raise ArgumentError, fn -> Repo.get!(AgentRunStep, step.id) end
    assert_raise ArgumentError, fn -> Agents.list_agent_runs(agent.id, preload: [:steps]) end
  end

  test "Event retention is batch-bounded and preserves headers and spend facts", %{agent: agent} do
    old = ~U[2026-01-01 00:00:00.000000Z]
    cutoff = ~U[2026-02-01 00:00:00.000000Z]

    {:ok, first} =
      Events.append(agent.id, "effect_completed", %{
        "result" => %{
          "usage" => %{"total_cost" => 1.5, "input_tokens" => 10, "output_tokens" => 5}
        }
      })

    {:ok, second} = Events.append(agent.id, "old_event", %{"secret" => "second"})

    {2, _rows} =
      Repo.update_all(
        from(event in Event, where: event.id in ^[first.id, second.id]),
        set: [inserted_at: old]
      )

    prepare_exact_retention!()

    before = Repo.get!(Event, first.id)
    assert Spend.get_agent_spend(agent.id).total_cost == 1.5

    assert {:ok, %{purged: 1}} =
             PrivacyRetention.run_handler(:events,
               cutoff: cutoff,
               batch_size: 1,
               per_tenant: 1
             )

    assert Repo.aggregate(
             from(event in Event, where: not is_nil(event.payload_purged_at)),
             :count
           ) == 1

    assert {:ok, %{purged: 1}} =
             PrivacyRetention.run_handler(:events,
               cutoff: cutoff,
               batch_size: 1,
               per_tenant: 1
             )

    assert {:ok, %{purged: 0}} =
             PrivacyRetention.run_handler(:events,
               cutoff: cutoff,
               batch_size: 1,
               per_tenant: 1
             )

    purged = Repo.get!(Event, first.id)
    assert purged.agent_id == before.agent_id
    assert purged.sequence_num == before.sequence_num
    assert purged.event_type == before.event_type
    assert purged.idempotency_key == before.idempotency_key
    assert purged.inserted_at == old
    assert purged.payload_purged_at
    assert purged.payload == nil
    assert purged.legacy_payload == %{}
    assert purged.spend_total_cost == 1.5
    assert purged.spend_input_tokens == 10
    assert purged.spend_output_tokens == 5
    assert purged.spend_llm_calls == 1
    assert Spend.get_agent_spend(agent.id).total_cost == 1.5

    assert Enum.find(Events.list_events(agent.id), &(&1.id == first.id)).payload == %{}

    assert {:error, :invalid_privacy_retention_options} =
             PrivacyRetention.run_handler(:events, cutoff: cutoff, batch_size: 501)
  end

  test "run-step retention never purges a running or actively pointed run", %{agent: agent} do
    old = ~U[2026-01-01 00:00:00.000000Z]
    cutoff = ~U[2026-02-01 00:00:00.000000Z]
    {:ok, run} = Agents.start_agent_run(agent)

    {:ok, step} =
      Agents.record_agent_run_step(run.id, agent.id, %{
        step_type: "tool_call",
        request_payload: %{"secret" => "request"}
      })

    {:ok, completed_step} =
      Agents.update_agent_run_step(step.id, %{
        status: "completed",
        response_payload: %{"secret" => "response"}
      })

    {1, _rows} =
      Repo.update_all(
        from(stored_step in AgentRunStep, where: stored_step.id == ^step.id),
        set: [completed_at: old]
      )

    assert {:error, {:durable_agent_work_requires_drain, 0, 1, 0}} =
             ProtocolCutover.activation_preconditions()

    assert {:error, {:effect_protocol_mismatch, :legacy}} =
             PrivacyRetention.run_handler(:run_steps, cutoff: cutoff, batch_size: 1)

    {:ok, _completed_run} = Agents.complete_agent_run(run.id)

    {1, _rows} =
      Repo.update_all(
        from(stored_run in AgentRun, where: stored_run.id == ^run.id),
        set: [completed_at: old]
      )

    {1, _rows} =
      Repo.update_all(
        from(stored_agent in Agent, where: stored_agent.id == ^agent.id),
        set: [active_run_id: run.id]
      )

    assert {:error, {:effect_protocol_mismatch, :legacy}} =
             PrivacyRetention.run_handler(:run_steps, cutoff: cutoff, batch_size: 1)

    {1, _rows} =
      Repo.update_all(
        from(stored_agent in Agent, where: stored_agent.id == ^agent.id),
        set: [active_run_id: nil]
      )

    prepare_exact_retention!()

    before = Repo.get!(AgentRunStep, step.id)

    {1, _rows} =
      Repo.update_all(
        from(stored_agent in Agent, where: stored_agent.id == ^agent.id),
        set: [active_run_id: run.id]
      )

    assert {:ok, %{purged: 0}} =
             PrivacyRetention.run_handler(:run_steps,
               cutoff: cutoff,
               batch_size: 1,
               per_tenant: 1
             )

    {1, _rows} =
      Repo.update_all(
        from(stored_agent in Agent, where: stored_agent.id == ^agent.id),
        set: [active_run_id: nil]
      )

    assert {:ok, %{purged: 1}} =
             PrivacyRetention.run_handler(:run_steps,
               cutoff: cutoff,
               batch_size: 1,
               per_tenant: 1
             )

    assert {:ok, %{purged: 0}} =
             PrivacyRetention.run_handler(:run_steps,
               cutoff: cutoff,
               batch_size: 1,
               per_tenant: 1
             )

    purged = Repo.get!(AgentRunStep, step.id)
    assert purged.agent_run_id == before.agent_run_id
    assert purged.agent_id == before.agent_id
    assert purged.sequence == before.sequence
    assert purged.step_type == before.step_type
    assert purged.status == completed_step.status
    assert purged.started_at == before.started_at
    assert purged.completed_at == old
    assert purged.payload_purged_at
    assert purged.request_payload == nil
    assert purged.response_payload == nil
    assert purged.legacy_request_payload == %{}
    assert purged.legacy_response_payload == %{}
    assert AgentRunStep.hydrate_payloads!(purged).request_payload == %{}
    assert AgentRunStep.hydrate_payloads!(purged).response_payload == %{}

    assert {:error, :invalid_privacy_retention_options} =
             PrivacyRetention.run_handler(:run_steps, cutoff: cutoff, batch_size: 501)
  end

  defp contract_payload_batch!(opts) do
    try do
      DurablePayloadPrivacy.backfill_batch(Keyword.merge(@contraction_evidence, opts))
    after
      set_runtime_role!()
    end
  end

  defp contract_payloads!(opts) do
    try do
      DurablePayloadPrivacy.backfill(Keyword.merge(@contraction_evidence, opts))
    after
      set_runtime_role!()
    end
  end

  defp prepare_exact_retention! do
    assert {:ok, contraction} = contract_payloads!(batch_size: 100, max_batches: 10)
    assert contraction.blocked_events == []
    assert contraction.blocked_run_steps == []
    assert contraction.blocked_snapshots == []

    assert {:ok, verification} =
             DurablePayloadVerification.verify(limit: 100, max_batches: 20)

    assert verification.failures == []
    assert {:ok, %{failures: 0}} = DurablePayloadVerification.preflight()

    assert {:ok, effect_status} =
             ProtocolCutover.activate(
               [confirmation: ProtocolCutover.activation_confirmation()] ++ @activation_evidence
             )

    assert effect_status in [:activated, :already_active]

    Repo.query!("SET LOCAL ROLE maraithon_activation_operator", [], log: false)

    assert {:ok, runtime_status} =
             CoordinationProtocol.activate(
               [confirmation: CoordinationProtocol.activation_confirmation()] ++
                 @activation_evidence
             )

    assert runtime_status in [:activated, :already_active]
    set_runtime_role!()
  end

  # This bypass models corruption that predates the database writer fence. It is
  # restricted to the two reader-fail-closed cases and always restores the
  # ENABLE ALWAYS fence before any read assertion runs.
  defp seed_preexisting_ciphertext!(table, fun)
       when table in ["events", "agent_run_steps"] and is_function(fun, 0) do
    Repo.query!("SET CONSTRAINTS ALL IMMEDIATE", [], log: false)
    Repo.query!("SET LOCAL ROLE maraithon_migrator", [], log: false)

    try do
      Repo.query!(
        "ALTER TABLE public.#{table} DISABLE TRIGGER #{@retired_key_guard}",
        [],
        log: false
      )

      fun.()
    after
      Repo.query!(
        "ALTER TABLE public.#{table} ENABLE ALWAYS TRIGGER #{@retired_key_guard}",
        [],
        log: false
      )

      set_runtime_role!()
    end
  end

  defp set_runtime_role! do
    Repo.query!("SET LOCAL ROLE maraithon_runtime", [], log: false)
    :ok
  end
end
