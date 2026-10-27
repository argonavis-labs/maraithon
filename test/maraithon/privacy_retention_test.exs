defmodule Maraithon.PrivacyRetentionTest do
  use Maraithon.DataCase, async: false

  alias Maraithon.Accounts
  alias Maraithon.AgentIsolation
  alias Maraithon.Agents
  alias Maraithon.DurablePayloadContraction
  alias Maraithon.DurablePayloadVerification
  alias Maraithon.Effects
  alias Maraithon.Effects.ProtocolCutover
  alias Maraithon.Effects.TerminalEnvelope
  alias Maraithon.PrivacyRetention
  alias Maraithon.Repo
  alias Maraithon.Runtime.AgentDirectives
  alias Maraithon.Runtime.Coordination.Protocol, as: CoordinationProtocol
  alias Maraithon.Runtime.DatabaseClock

  @moduletag database_role: :session

  @evidence_id "test:stopped-fleet:privacy-retention"
  @evidence_digest :crypto.hash(:sha256, "test privacy retention stopped fleet")
  @evidence_operator "privacy-retention@example.test"
  @revision String.duplicate("e", 40)
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
    original = Application.get_env(:maraithon, PrivacyRetention)

    Application.put_env(:maraithon, PrivacyRetention,
      effects_days: 30,
      directives_days: 30,
      events_days: 90,
      run_steps_days: 30,
      agent_runs_days: 30,
      assistant_runs_days: 30,
      assistant_steps_days: 30,
      prepared_actions_days: 30,
      operator_events_days: 90,
      background_jobs_days: 30,
      scheduled_jobs_days: 30,
      ingress_receipts_days: 90,
      work_results_days: 30,
      conversation_days: 90,
      snapshot_quarantine_days: 30,
      erasure_receipts_days: 365,
      batch_size: 100,
      per_tenant: 5,
      alert_grace_hours: 24,
      critical_grace_hours: 168
    )

    on_exit(fn ->
      if is_nil(original) do
        Application.delete_env(:maraithon, PrivacyRetention)
      else
        Application.put_env(:maraithon, PrivacyRetention, original)
      end
    end)

    assert ProtocolCutover.mode() == :legacy

    assert {:ok, attestation} =
             CoordinationProtocol.attest_effect_activation_evidence(@activation_evidence)

    assert attestation in [:attested, :already_attested]
    set_runtime_role!()
    :ok
  end

  test "encrypted-source registry exhaustively covers all 18 fixed tables" do
    assert PrivacyRetention.encrypted_source_registry()
           |> Enum.map(& &1.table)
           |> Enum.sort() ==
             Enum.sort(~w(
               effects agent_directives events agent_run_steps snapshots
               telegram_conversation_turns telegram_conversations
               telegram_assistant_runs telegram_assistant_steps
               telegram_prepared_actions agent_runs operator_events
               user_memory_profiles operator_memory_summaries background_jobs
               scheduled_jobs runtime_ingress_receipts agent_work_results
             ))

    assert Enum.all?(PrivacyRetention.encrypted_source_registry(), fn source ->
             Map.has_key?(source, :tenant) and Map.has_key?(source, :retention_handler) and
               Map.has_key?(source, :marker)
           end)
  end

  test "exact retention clears corrupt terminal ciphertext fairly without decoding it" do
    now = DatabaseClock.now!()
    old = DateTime.add(now, -40 * 86_400, :second)

    rows =
      for suffix <- ["one", "two"] do
        user_id = "privacy-retention-#{suffix}-#{System.unique_integer([:positive])}@example.com"
        {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

        {:ok, agent} =
          Agents.create_agent(%{
            user_id: user_id,
            behavior: "prompt_agent",
            status: "running",
            config: %{}
          })

        {:ok, _binding} =
          AgentIsolation.grant_binding_consent(
            agent,
            Maraithon.DataCase.binding_consent(agent)
          )

        {:ok, effect_id} =
          Effects.request(agent.id, :tool_call, "privacy_probe", %{"secret" => suffix})

        Repo.query!(
          """
          UPDATE effects
          SET status = 'completed', result = $2::jsonb,
              result_envelope = $3::jsonb, result_acknowledged_at = $4,
              updated_at = $4
          WHERE id = $1
          """,
          [
            Ecto.UUID.dump!(effect_id),
            %{"secret" => "terminal-#{suffix}"},
            TerminalEnvelope.success(),
            DateTime.to_naive(old)
          ]
        )

        {:ok, directive} =
          AgentDirectives.enqueue(
            agent.id,
            user_id,
            "manual_wake",
            %{"secret" => suffix},
            "privacy-#{suffix}"
          )

        Repo.query!(
          """
          UPDATE agent_directives
          SET status = 'completed', terminal_at = $2,
              terminal_acknowledged_at = $2, terminal_claim_token = $3,
              terminal_by_generation = $4, updated_at = $2
          WHERE id = $1
          """,
          [
            Ecto.UUID.dump!(directive.id),
            DateTime.to_naive(old),
            Ecto.UUID.dump!(Ecto.UUID.generate()),
            Ecto.UUID.dump!(Ecto.UUID.generate())
          ]
        )

        %{agent: agent, effect_id: effect_id, directive_id: directive.id}
      end

    assert {:ok, %{effects: 2, directives: 2}} =
             contract_effect_and_directive_payloads!(10)

    assert {:ok, verification} =
             DurablePayloadVerification.verify(
               tables: ["effects", "agent_directives"],
               limit: 10,
               max_batches: 10
             )

    assert verification.failures == []
    assert {:ok, %{failures: 0}} = DurablePayloadVerification.preflight()

    # The sandbox keeps deferred events from the valid legacy setup rows in the
    # outer transaction; discharge them while the protocol pair is still canonical.
    Repo.query!("SET CONSTRAINTS ALL IMMEDIATE", [], log: false)

    assert {:ok, effect_status} =
             ProtocolCutover.activate(
               [
                 confirmation: ProtocolCutover.activation_confirmation(),
                 lock_timeout_ms: 5_000
               ] ++ @activation_evidence
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

    # The rows are valid at activation. This tightly scoped bypass models
    # corruption that predates this retention cycle, then restores every
    # production writer fence before retention runs.
    seed_preexisting_ciphertext!("effects", fn ->
      Enum.each(rows, fn row ->
        Repo.query!(
          """
          UPDATE effects
          SET params_ciphertext = $2, result_ciphertext = $2
          WHERE id = $1
          """,
          [Ecto.UUID.dump!(row.effect_id), <<0, 1, 2, 3, 4>>]
        )
      end)
    end)

    seed_preexisting_ciphertext!("agent_directives", fn ->
      Enum.each(rows, fn row ->
        Repo.query!(
          "UPDATE agent_directives SET payload_ciphertext = $2 WHERE id = $1",
          [Ecto.UUID.dump!(row.directive_id), <<0, 1, 2, 3, 4>>]
        )
      end)
    end)

    # A global batch of two with a per-tenant cap of one must service both users.
    assert {:ok, %{purged: 2, backlog_count: 0}} =
             PrivacyRetention.run_handler(:effects, batch_size: 2, per_tenant: 1)

    assert {:ok, %{purged: 2, backlog_count: 0}} =
             PrivacyRetention.run_handler(:directives, batch_size: 2, per_tenant: 1)

    Enum.each(rows, fn row ->
      assert %{rows: [[nil, nil, %{"redacted" => true}, nil, purged_at]]} =
               Repo.query!(
                 """
                 SELECT params_ciphertext, result_ciphertext, params, result,
                        payload_purged_at
                 FROM effects WHERE id = $1
                 """,
                 [Ecto.UUID.dump!(row.effect_id)]
               )

      assert purged_at

      assert %{rows: [[nil, %{"redacted" => true}, directive_purged_at]]} =
               Repo.query!(
                 """
                 SELECT payload_ciphertext, payload, payload_purged_at
                 FROM agent_directives WHERE id = $1
                 """,
                 [Ecto.UUID.dump!(row.directive_id)]
               )

      assert directive_purged_at
    end)
  end

  test "legacy mode refuses retention and leaves requested or unacknowledged authority untouched" do
    now = DatabaseClock.now!()
    old = DateTime.add(now, -400 * 86_400, :second)
    user_id = "privacy-blocked-#{System.unique_integer([:positive])}@example.com"
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

    {:ok, agent} =
      Agents.create_agent(%{
        user_id: user_id,
        behavior: "prompt_agent",
        status: "running",
        config: %{}
      })

    {:ok, _binding} =
      AgentIsolation.grant_binding_consent(
        agent,
        Maraithon.DataCase.binding_consent(agent)
      )

    {:ok, pending_effect} =
      Effects.request(agent.id, :tool_call, "pending", %{"secret" => "pending"})

    {:ok, unacked_effect} =
      Effects.request(agent.id, :tool_call, "unacked", %{"secret" => "unacked"})

    Repo.query!(
      """
      UPDATE effects
      SET status = 'completed', result_envelope = $2::jsonb,
          result = '{"secret":"unacked"}'::jsonb, updated_at = $3
      WHERE id = $1
      """,
      [Ecto.UUID.dump!(unacked_effect), TerminalEnvelope.success(), DateTime.to_naive(old)]
    )

    {:ok, requested} =
      AgentDirectives.enqueue(
        agent.id,
        user_id,
        "manual_wake",
        %{"secret" => "requested"},
        "requested"
      )

    {:ok, unacked} =
      AgentDirectives.enqueue(
        agent.id,
        user_id,
        "manual_wake",
        %{"secret" => "unacked"},
        "unacked"
      )

    {:ok, ambiguous} =
      AgentDirectives.enqueue(
        agent.id,
        user_id,
        "manual_wake",
        %{"secret" => "ambiguous"},
        "ambiguous"
      )

    Repo.query!(
      """
      UPDATE agent_directives
      SET status = 'completed', terminal_at = $2, terminal_claim_token = $3,
          terminal_by_generation = $4, updated_at = $2
      WHERE id = $1
      """,
      [
        Ecto.UUID.dump!(unacked.id),
        DateTime.to_naive(old),
        Ecto.UUID.dump!(Ecto.UUID.generate()),
        Ecto.UUID.dump!(Ecto.UUID.generate())
      ]
    )

    Repo.query!(
      """
      UPDATE agent_directives
      SET status = 'completed', terminal_at = $2,
          terminal_acknowledged_at = $2, ambiguity_code = 'effect_outcome_ambiguous',
          terminal_claim_token = $3, terminal_by_generation = $4, updated_at = $2
      WHERE id = $1
      """,
      [
        Ecto.UUID.dump!(ambiguous.id),
        DateTime.to_naive(old),
        Ecto.UUID.dump!(Ecto.UUID.generate()),
        Ecto.UUID.dump!(Ecto.UUID.generate())
      ]
    )

    seed_preexisting_ciphertext!("effects", fn ->
      for id <- [pending_effect, unacked_effect] do
        Repo.query!("UPDATE effects SET params_ciphertext = $2 WHERE id = $1", [
          Ecto.UUID.dump!(id),
          <<0, 1, 2, 3, 4>>
        ])
      end
    end)

    seed_preexisting_ciphertext!("agent_directives", fn ->
      for directive <- [requested, unacked, ambiguous] do
        Repo.query!("UPDATE agent_directives SET payload_ciphertext = $2 WHERE id = $1", [
          Ecto.UUID.dump!(directive.id),
          <<0, 1, 2, 3, 4>>
        ])
      end
    end)

    assert {:error, {:effect_protocol_mismatch, :legacy}} =
             PrivacyRetention.run_handler(:effects, batch_size: 10)

    assert {:error, {:effect_protocol_mismatch, :legacy}} =
             PrivacyRetention.run_handler(:directives, batch_size: 10)

    assert %{rows: [[nil], [nil]]} =
             Repo.query!(
               "SELECT payload_purged_at FROM effects WHERE id = ANY($1) ORDER BY id",
               [[Ecto.UUID.dump!(pending_effect), Ecto.UUID.dump!(unacked_effect)]]
             )

    directive_ids = Enum.map([requested, unacked, ambiguous], &Ecto.UUID.dump!(&1.id))

    assert %{rows: [[nil], [nil], [nil]]} =
             Repo.query!(
               "SELECT payload_purged_at FROM agent_directives WHERE id = ANY($1) ORDER BY id",
               [directive_ids]
             )
  end

  test "supplied future or policy-newer cutoffs fail closed and persist status" do
    database_now = DatabaseClock.now!()
    future = DateTime.add(database_now, 60, :second)

    assert {:error, :future_privacy_retention_cutoff} =
             PrivacyRetention.run_handler(:events, cutoff: future)

    aggressive = DateTime.add(database_now, -1, :second)

    assert {:error, :aggressive_privacy_retention_cutoff} =
             PrivacyRetention.run_handler(:events, cutoff: aggressive)

    assert %{rows: [[failures, "warning", error_code]]} =
             Repo.query!("""
             SELECT consecutive_failures, alert_state, last_error_code
             FROM privacy_retention_statuses
             WHERE handler = 'events'
             """)

    assert failures >= 1

    assert error_code in [
             "future_privacy_retention_cutoff",
             "aggressive_privacy_retention_cutoff"
           ]
  end

  defp contract_effect_and_directive_payloads!(limit) do
    try do
      DurablePayloadContraction.transaction(@contraction_evidence, fn ->
        assert {:ok, effects} = Effects.backfill_legacy_payload_encryption(limit)
        assert {:ok, directives} = AgentDirectives.backfill_legacy_payload_encryption(limit)
        %{effects: effects, directives: directives}
      end)
    after
      set_runtime_role!()
    end
  end

  defp seed_preexisting_ciphertext!(table, fun)
       when table in ["effects", "agent_directives"] and is_function(fun, 0) do
    protocol_mode = ProtocolCutover.mode()

    error =
      assert_raise Postgrex.Error, fn ->
        Repo.transaction(fun, mode: :savepoint)
      end

    assert error.postgres.code == :check_violation
    assert error.postgres.message in writer_fence_rejections(table, protocol_mode)

    # Deferred integrity triggers from the valid setup rows must fire before
    # PostgreSQL will permit the narrowly scoped ALTER TABLE below.
    Repo.query!("SET CONSTRAINTS ALL IMMEDIATE", [], log: false)
    Repo.query!("SET LOCAL ROLE maraithon_migrator", [], log: false)
    triggers = writer_fence_triggers(table, protocol_mode)

    try do
      Enum.each(triggers, fn {trigger, _restore} ->
        Repo.query!("ALTER TABLE public.#{table} DISABLE TRIGGER #{trigger}", [], log: false)
      end)

      # Keep all remaining exact coordination fences live: only the executor
      # role may perform the deliberately malformed row update.
      set_runtime_role!()
      fun.()
    after
      Repo.query!("SET LOCAL ROLE maraithon_migrator", [], log: false)

      Enum.each(Enum.reverse(triggers), fn {trigger, restore} ->
        Repo.query!("ALTER TABLE public.#{table} #{restore} TRIGGER #{trigger}", [], log: false)
      end)

      set_runtime_role!()
    end
  end

  defp writer_fence_rejections(_table, :legacy) do
    ["Changed durable ciphertext has an invalid key tag envelope"]
  end

  defp writer_fence_rejections("effects", :exact) do
    [
      "Legacy Effect rows are read-only after exact activation",
      "Changed durable ciphertext has an invalid key tag envelope"
    ]
  end

  defp writer_fence_rejections("agent_directives", :exact) do
    [
      "Exact Agent Directive mutation requires generation-fenced writer marker",
      "Changed durable ciphertext has an invalid key tag envelope"
    ]
  end

  defp writer_fence_triggers(_table, :legacy) do
    [{@retired_key_guard, "ENABLE ALWAYS"}]
  end

  defp writer_fence_triggers("effects", :exact) do
    [
      {@retired_key_guard, "ENABLE ALWAYS"},
      {"enforce_effect_execution_protocol_trigger", "ENABLE"}
    ]
  end

  defp writer_fence_triggers("agent_directives", :exact) do
    [
      {@retired_key_guard, "ENABLE ALWAYS"},
      {"enforce_agent_directive_protocol_trigger", "ENABLE"}
    ]
  end

  defp set_runtime_role! do
    Repo.query!("SET LOCAL ROLE maraithon_runtime", [], log: false)
    :ok
  end
end
