defmodule Maraithon.KeyRetirementFenceAdversarialTest do
  use Maraithon.DataCase, async: false

  alias Ecto.Adapters.SQL
  alias Ecto.Adapters.SQL.Sandbox
  alias Maraithon.DurablePayloadBinding
  alias Maraithon.DurablePayloadRegistry
  alias Maraithon.Effects.ProtocolCutover
  alias Maraithon.KeyRetirementBootGuard
  alias Maraithon.Repo
  alias Maraithon.Runtime.Coordination.Protocol, as: CoordinationProtocol
  alias Maraithon.Vault
  alias Maraithon.VaultCiphertextRegistry

  @moduletag timeout: 180_000

  @evidence_id "test:key-fence:proof-authority"
  @evidence_digest :crypto.hash(:sha256, "key-fence proof authority")
  @evidence_operator "key-fence@example.test"
  @revision String.duplicate("d", 40)
  @activation_evidence [
    evidence_id: @evidence_id,
    evidence_digest: @evidence_digest,
    activated_by: @evidence_operator,
    revision: @revision
  ]

  # This is deliberately duplicated test-side. Any registry edit must update the
  # application registry, SQL proof registry, and trigger case statement together.
  @vault_targets [
    {"effects", "params_ciphertext"},
    {"effects", "result_ciphertext"},
    {"agent_directives", "payload_ciphertext"},
    {"events", "payload_ciphertext"},
    {"agent_run_steps", "request_payload_ciphertext"},
    {"agent_run_steps", "response_payload_ciphertext"},
    {"telegram_conversation_turns", "text_ciphertext"},
    {"telegram_conversation_turns", "structured_data_ciphertext"},
    {"telegram_conversations", "summary_ciphertext"},
    {"telegram_conversations", "historical_summary_ciphertext"},
    {"telegram_assistant_runs", "prompt_snapshot_ciphertext"},
    {"telegram_assistant_runs", "result_summary_ciphertext"},
    {"telegram_assistant_steps", "request_payload_ciphertext"},
    {"telegram_assistant_steps", "response_payload_ciphertext"},
    {"telegram_prepared_actions", "payload_ciphertext"},
    {"telegram_prepared_actions", "preview_text_ciphertext"},
    {"agent_runs", "trigger_ciphertext"},
    {"agent_runs", "metadata_ciphertext"},
    {"operator_events", "payload_ciphertext"},
    {"operator_events", "metadata_ciphertext"},
    {"user_memory_profiles", "summary_ciphertext"},
    {"user_memory_profiles", "profile_ciphertext"},
    {"operator_memory_summaries", "content_ciphertext"},
    {"background_jobs", "payload_ciphertext"},
    {"background_jobs", "result_ciphertext"},
    {"scheduled_jobs", "payload_ciphertext"},
    {"runtime_ingress_receipts", "payload_ciphertext"},
    {"snapshots", "state_data_ciphertext"},
    {"snapshots", "budget_ciphertext"},
    {"agent_work_results", "result_ciphertext"},
    {"connected_accounts", "access_token"},
    {"connected_accounts", "refresh_token"},
    {"oauth_tokens", "access_token"},
    {"oauth_tokens", "refresh_token"},
    {"local_browser_visits", "title"},
    {"local_calendar_events", "title"},
    {"local_calendar_events", "notes"},
    {"local_files", "filename"},
    {"local_files", "text_content"},
    {"memory_items", "content"},
    {"memory_items", "summary"},
    {"memory_items", "metadata"}
  ]

  @binding_targets [
    {"effects", "payload"},
    {"agent_directives", "payload"},
    {"events", "payload"},
    {"agent_run_steps", "payload"},
    {"telegram_conversation_turns", "payload"},
    {"telegram_conversations", "payload"},
    {"telegram_assistant_runs", "payload"},
    {"telegram_assistant_steps", "payload"},
    {"telegram_prepared_actions", "payload"},
    {"agent_runs", "payload"},
    {"operator_events", "payload"},
    {"user_memory_profiles", "payload"},
    {"operator_memory_summaries", "payload"},
    {"background_jobs", "payload"},
    {"scheduled_jobs", "payload"},
    {"runtime_ingress_receipts", "payload"},
    {"snapshots", "payload"},
    {"agent_work_results", "payload"},
    {"agent_work_results", "authority"}
  ]

  @trigger_tables @vault_targets |> Enum.map(&elem(&1, 0)) |> Enum.uniq() |> Enum.sort()

  test "the fixed proof registry and ALWAYS trigger coverage are exact" do
    assert length(@trigger_tables) == 24
    assert length(@vault_targets) == 42
    assert length(@binding_targets) == 19

    expected_vault_registry =
      Enum.map_join(@vault_targets, ",", fn {table, column} -> "#{table}.#{column}" end)

    expected_binding_registry =
      Enum.map_join(@binding_targets, ",", fn {table, binding} -> "#{table}:#{binding}" end)

    registry_rows =
      in_role!("maraithon_incident_operator", fn ->
        SQL.query!(
          Repo,
          """
          SELECT public.durable_payload_key_registry_definition('vault'),
                 public.durable_payload_key_registry_definition('binding')
          """,
          []
        ).rows
      end)

    assert [[^expected_vault_registry, ^expected_binding_registry]] = registry_rows

    assert Enum.map(VaultCiphertextRegistry.all(), &{&1.table, &1.column}) == @vault_targets

    assert Enum.map(DurablePayloadRegistry.binding_targets(), &{&1.table, &1.binding_name}) ==
             @binding_targets

    trigger_rows =
      SQL.query!(
        Repo,
        """
        SELECT relation.relname, trigger.tgenabled::text, trigger.tgtype::integer,
               function.proname
        FROM pg_catalog.pg_trigger AS trigger
        JOIN pg_catalog.pg_class AS relation ON relation.oid = trigger.tgrelid
        JOIN pg_catalog.pg_namespace AS namespace ON namespace.oid = relation.relnamespace
        JOIN pg_catalog.pg_proc AS function ON function.oid = trigger.tgfoid
        WHERE namespace.nspname = 'public'
          AND trigger.tgname = 'guard_durable_payload_retired_key_write_trigger'
          AND NOT trigger.tgisinternal
        ORDER BY relation.relname
        """,
        []
      ).rows

    assert trigger_rows ==
             Enum.map(@trigger_tables, fn table ->
               # ROW | BEFORE | INSERT | UPDATE = 1 + 2 + 4 + 16.
               [table, "A", 23, "guard_durable_payload_retired_key_write"]
             end)

    assert [
             [
               "finalize_retired_durable_payload_key_fence_trigger",
               "A",
               5,
               "guard_retired_durable_payload_key"
             ],
             [
               "guard_retired_durable_payload_key_trigger",
               "A",
               31,
               "guard_retired_durable_payload_key"
             ]
           ] =
             SQL.query!(
               Repo,
               """
               SELECT trigger.tgname, trigger.tgenabled::text, trigger.tgtype::integer,
                      function.proname
               FROM pg_catalog.pg_trigger AS trigger
               JOIN pg_catalog.pg_proc AS function ON function.oid = trigger.tgfoid
               WHERE trigger.tgrelid = 'public.retired_durable_payload_keys'::regclass
                 AND trigger.tgname IN (
                   'guard_retired_durable_payload_key_trigger',
                   'finalize_retired_durable_payload_key_fence_trigger'
                 )
               ORDER BY trigger.tgname
               """,
               []
             ).rows

    assert [[guard_source]] =
             SQL.query!(
               Repo,
               """
               SELECT function.prosrc
               FROM pg_catalog.pg_proc AS function
               JOIN pg_catalog.pg_namespace AS namespace
                 ON namespace.oid = function.pronamespace
               WHERE namespace.nspname = 'public'
                 AND function.proname = 'guard_durable_payload_retired_key_write'
                 AND function.pronargs = 0
               """,
               []
             ).rows

    assert [
             ["advance_durable_payload_key_fence_epoch", true, advance_source],
             ["guard_retired_durable_payload_key", true, retirement_source]
           ] =
             SQL.query!(
               Repo,
               """
               SELECT function.proname, function.prosecdef, function.prosrc
               FROM pg_catalog.pg_proc AS function
               JOIN pg_catalog.pg_namespace AS namespace
                 ON namespace.oid = function.pronamespace
               WHERE namespace.nspname = 'public'
                 AND function.proname IN (
                   'advance_durable_payload_key_fence_epoch',
                   'guard_retired_durable_payload_key'
                 )
               ORDER BY function.proname
               """,
               []
             ).rows

    assert_source_order!(
      advance_source,
      "FROM public.durable_payload_key_fence_state",
      "FROM public.retired_durable_payload_keys"
    )

    assert retirement_source =~ "TG_WHEN = 'AFTER'"
    assert retirement_source =~ "FINAL_REMOVAL_AUTHORIZATION_V1"
    assert retirement_source =~ "FROM public.durable_payload_key_fence_state"
    assert retirement_source =~ "FOR UPDATE"

    assert [[digest_source]] =
             SQL.query!(
               Repo,
               """
               SELECT function.prosrc
               FROM pg_catalog.pg_proc AS function
               JOIN pg_catalog.pg_namespace AS namespace
                 ON namespace.oid = function.pronamespace
               WHERE namespace.nspname = 'public'
                 AND function.proname = 'durable_payload_old_key_source_digest'
                 AND function.pronargs = 2
               """,
               []
             ).rows

    normalized_digest_source = Regex.replace(~r/\s+/, digest_source, " ")
    assert normalized_digest_source =~ "'vault_ciphertext_targets', 42"
    assert normalized_digest_source =~ "'binding_targets', 19"

    normalized_guard = Regex.replace(~r/\s+/, guard_source, " ")

    @vault_targets
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Enum.each(fn {table, columns} ->
      fragment =
        "WHEN '#{table}' THEN ARRAY[" <>
          Enum.map_join(columns, ", ", &"'#{&1}'") <> "]"

      assert normalized_guard =~ fragment,
             "retired-key trigger case is missing or reordered: #{fragment}"
    end)

    assert normalized_guard =~
             "TG_TABLE_NAME = 'agent_work_results' AND new_row -> 'result_digest_key_tag'"
  end

  test "ciphertext key-tag parsing is byte-bounded, UTF-8 safe, and independent of bytea_output" do
    tag64 = String.duplicate("Z", 64)

    accepted = [
      {tagged("A"), "A"},
      {tagged("A0._:-z"), "A0._:-z"},
      {tagged(tag64), tag64},
      {tagged("trail", <<0, 255, 1, 2, 3>>), "trail"}
    ]

    rejected = [
      <<>>,
      <<1>>,
      <<1, 1>>,
      <<0, 1, ?A>>,
      <<2, 1, ?A>>,
      <<1, 0, ?A>>,
      <<1, 65>> <> String.duplicate("A", 65),
      <<1, 3, ?a, ?b>>,
      <<1, 64>> <> String.duplicate("A", 63),
      <<1, 1, 0xFF>>,
      <<1, 2, 0xC3, 0x28>>,
      tagged("-bad"),
      tagged("a/b"),
      tagged("white space")
    ]

    Enum.each(accepted, fn {ciphertext, expected} ->
      assert parsed_tag(ciphertext) == expected
    end)

    Enum.each(rejected, fn ciphertext ->
      assert parsed_tag(ciphertext) == nil
    end)

    in_role!("maraithon_migrator", fn ->
      SQL.query!(Repo, "SET LOCAL bytea_output = 'escape'", [])

      assert [["escape.tag"]] =
               SQL.query!(
                 Repo,
                 "SELECT public.durable_payload_ciphertext_key_tag($1::bytea)",
                 [tagged("escape.tag", <<0, 92, 255>>)]
               ).rows
    end)
  end

  test "raw INSERT, UPDATE, and COPY cannot write a fenced Vault tag under escape bytea output" do
    fenced_tag = unique_tag("raw")
    unfenced_tag = unique_tag("raw-current")
    seed_fence_without_zero_scan!("vault", fenced_tag)
    SQL.query!(Repo, "SET LOCAL bytea_output = 'escape'", [])

    accepted_id = insert_visit!(tagged(unfenced_tag, <<0, 92, 255>>))
    assert [[^unfenced_tag]] = visit_tag(accepted_id)

    fenced_insert_id = Ecto.UUID.generate()

    assert_postgres_code("23514", fn ->
      insert_visit!(tagged(fenced_tag, <<0, 92, 255>>), fenced_insert_id)
    end)

    assert [[0]] = visit_count(fenced_insert_id)

    update_id = insert_visit!(nil)

    assert_postgres_code("23514", fn ->
      SQL.query!(
        Repo,
        "UPDATE public.local_browser_visits SET title = $2 WHERE id = $1::uuid",
        [uuid_param(update_id), tagged(fenced_tag)]
      )
    end)

    assert [[nil]] =
             SQL.query!(Repo, "SELECT title FROM local_browser_visits WHERE id = $1", [
               uuid_param(update_id)
             ]).rows

    copy_id = Ecto.UUID.generate()
    copy_device_id = Ecto.UUID.generate()
    copy_ciphertext = "\\x" <> Base.encode16(tagged(fenced_tag), case: :lower)

    copy_row =
      [
        copy_id,
        "key-fence-copy-user",
        copy_device_id,
        "copy-test",
        "https://example.test/key-fence-copy",
        copy_ciphertext,
        "2026-01-01 00:00:00",
        "2026-01-01 00:00:00"
      ]
      |> Enum.map_join(",", &csv_field/1)
      |> Kernel.<>("\n")

    assert_postgres_code("23514", fn ->
      copy_stream =
        SQL.stream(
          Repo,
          """
          COPY public.local_browser_visits (
            id, user_id, device_id, browser, url, title, inserted_at, updated_at
          ) FROM STDIN WITH (FORMAT csv)
          """,
          [],
          mode: :savepoint,
          log: false
        )

      Enum.into([copy_row], copy_stream)
    end)

    assert [[0]] = visit_count(copy_id)
  end

  test "proof refresh advances only the mapped proof and duplicate or rolled-back proofs do not advance" do
    activate_exact_pair!()
    tag = unique_tag("refresh")
    other_tag = unique_tag("other")
    rollback_tag = unique_tag("rollback")
    proof1 = Ecto.UUID.generate()
    proof2 = Ecto.UUID.generate()
    other_proof = Ecto.UUID.generate()
    rolled_back_proof = Ecto.UUID.generate()

    {generation0, fences0} = fence_state()
    insert_zero_proof!("vault", tag, proof1)
    {generation1, fences1} = fence_state()
    assert generation1 == generation0 + 1
    assert get_in(fences1, ["vault", tag]) == proof1
    assert map_size(fences1["vault"]) == map_size(fences0["vault"]) + 1

    insert_zero_proof!("binding", other_tag, other_proof)
    {generation2, fences2} = fence_state()
    assert generation2 == generation1 + 1
    assert get_in(fences2, ["vault", tag]) == proof1
    assert get_in(fences2, ["binding", other_tag]) == other_proof

    insert_zero_proof!("vault", tag, proof2)
    {generation3, fences3} = fence_state()
    assert generation3 == generation2 + 1
    assert get_in(fences3, ["vault", tag]) == proof2
    assert get_in(fences3, ["binding", other_tag]) == other_proof
    assert map_size(fences3["vault"]) == map_size(fences2["vault"])
    assert map_size(fences3["binding"]) == map_size(fences2["binding"])

    assert_postgres_code("23505", "maraithon_incident_operator", fn ->
      mark_zero_proof!()
      insert_zero_proof_sql!("vault", tag, proof2)
    end)

    assert fence_state() == {generation3, fences3}

    assert {:error, :rollback_probe} =
             Repo.transaction(
               fn ->
                 insert_zero_proof!("vault", rollback_tag, rolled_back_proof)
                 {inside_generation, inside_fences} = fence_state()
                 assert inside_generation == generation3 + 1
                 assert get_in(inside_fences, ["vault", rollback_tag]) == rolled_back_proof
                 Repo.rollback(:rollback_probe)
               end,
               mode: :savepoint
             )

    assert fence_state() == {generation3, fences3}

    proof_counts =
      in_role!("maraithon_incident_operator", fn ->
        rolled_back_count =
          SQL.query!(
            Repo,
            "SELECT count(*) FROM key_retirement_zero_proofs WHERE proof_id = $1::uuid",
            [uuid_param(rolled_back_proof)]
          ).rows

        tag_count =
          SQL.query!(
            Repo,
            """
            SELECT count(*) FROM key_retirement_zero_proofs
            WHERE key_kind = 'vault' AND old_tag = $1
            """,
            [tag]
          ).rows

        {rolled_back_count, tag_count}
      end)

    assert proof_counts == {[[0]], [[2]]}
  end

  test "final authorization binds the latest mapped proof and freezes further proof refresh" do
    activate_exact_pair!()
    tag = unique_tag("authorization")
    proof1 = Ecto.UUID.generate()
    proof2 = Ecto.UUID.generate()
    proof3 = Ecto.UUID.generate()

    proof1_row = insert_zero_proof!("vault", tag, proof1)
    await_database_clock_after!(proof1_row.proved_at)
    attest_backup!("vault", tag, proof1)

    proof2_row = insert_zero_proof!("vault", tag, proof2)
    await_database_clock_after!(proof2_row.proved_at)
    attest_backup!("vault", tag, proof2)

    assert_postgres_code("23514", "maraithon_incident_operator", fn ->
      mark_retirement_authorization!()
      insert_authorization_sql!("vault", tag, proof1)
    end)

    {generation_before_authorization, fences_before_authorization} = fence_state()
    assert get_in(fences_before_authorization, ["vault", tag]) == proof2

    assert {:error, :authorization_rollback_probe} =
             Repo.transaction(
               fn ->
                 rolled_back_authorization = authorize!("vault", tag, proof2)

                 assert rolled_back_authorization.fence_generation ==
                          generation_before_authorization

                 assert fence_state() ==
                          {generation_before_authorization + 1, fences_before_authorization}

                 Repo.rollback(:authorization_rollback_probe)
               end,
               mode: :savepoint
             )

    assert fence_state() == {generation_before_authorization, fences_before_authorization}

    assert [[0]] =
             in_role!("maraithon_incident_operator", fn ->
               SQL.query!(
                 Repo,
                 """
                 SELECT count(*) FROM retired_durable_payload_keys
                 WHERE key_kind = 'vault' AND old_tag = $1
                 """,
                 [tag]
               ).rows
             end)

    authorization = authorize!("vault", tag, proof2)
    {generation_after_authorization, fences_after_authorization} = fence_state()

    assert generation_after_authorization == generation_before_authorization + 1
    assert fences_after_authorization == fences_before_authorization
    assert authorization.zero_proof_id == proof2
    assert authorization.fence_generation == generation_before_authorization
    assert authorization.evidence_id == @evidence_id
    assert authorization.evidence_digest == @evidence_digest
    assert authorization.evidence_operator == @evidence_operator
    assert authorization.exact_revision == @revision
    assert byte_size(authorization.source_digest) == 32

    stored_source_digest =
      in_role!("maraithon_incident_operator", fn ->
        SQL.query!(
          Repo,
          "SELECT source_digest FROM key_retirement_zero_proofs WHERE proof_id = $1::uuid",
          [uuid_param(proof2)]
        ).rows
      end)

    assert stored_source_digest == [[authorization.source_digest]]

    assert_postgres_code("23505", "maraithon_incident_operator", fn ->
      mark_retirement_authorization!()
      insert_authorization_sql!("vault", tag, proof2)
    end)

    assert fence_state() == {generation_after_authorization, fences_after_authorization}

    assert_postgres_code("23514", "maraithon_incident_operator", fn ->
      mark_zero_proof!()
      insert_zero_proof_sql!("vault", tag, proof3)
    end)

    assert fence_state() == {generation_after_authorization, fences_after_authorization}

    assert [[0]] =
             in_role!("maraithon_incident_operator", fn ->
               SQL.query!(
                 Repo,
                 "SELECT count(*) FROM key_retirement_zero_proofs WHERE proof_id = $1::uuid",
                 [uuid_param(proof3)]
               ).rows
             end)
  end

  test "BootGuard checks only configured current write tags and reports each fenced kind" do
    assert {:ok, %{}} = KeyRetirementBootGuard.init(:ok)

    seed_fence_without_zero_scan!("vault", unique_tag("read-only-previous"))
    assert {:ok, %{}} = KeyRetirementBootGuard.init(:ok)

    seed_fence_without_zero_scan!("vault", Vault.current_key_tag())

    assert {:stop, {:current_durable_payload_key_tag_retired, [:vault]}} =
             KeyRetirementBootGuard.init(:ok)

    seed_fence_without_zero_scan!("binding", DurablePayloadBinding.current_key_tag())

    assert {:stop, {:current_durable_payload_key_tag_retired, fenced_kinds}} =
             KeyRetirementBootGuard.init(:ok)

    assert Enum.sort(fenced_kinds) == [:binding, :vault]
  end

  test "committed proof blocks READ COMMITTED writer and invalidates stale REPEATABLE READ snapshot" do
    rc_tag = unique_tag("read-committed")
    rr_tag = unique_tag("repeatable-read")
    rc_proof = Ecto.UUID.generate()
    rr_proof = Ecto.UUID.generate()
    rc_visit_id = Ecto.UUID.generate()
    rr_visit_id = Ecto.UUID.generate()
    parent = self()

    with_committed_fence_harness([rc_visit_id, rr_visit_id], fn ->
      unboxed(fn ->
        Repo.transaction(fn ->
          SQL.query!(Repo, "SET LOCAL ROLE maraithon_runtime", [])
          insert_visit!(nil, rc_visit_id)
          insert_visit!(nil, rr_visit_id)
        end)
      end)

      proof_task =
        Task.async(fn ->
          capture_postgres_error(fn ->
            Sandbox.unboxed_run(Repo, fn ->
              Repo.transaction(fn ->
                SQL.query!(Repo, "SET LOCAL ROLE maraithon_incident_operator", [])
                [[backend_pid]] = SQL.query!(Repo, "SELECT pg_backend_pid()", []).rows
                mark_zero_proof!()
                insert_zero_proof_sql!("vault", rc_tag, rc_proof)
                send(parent, {:proof_holds_source_locks, self(), backend_pid})

                receive do
                  {:commit_proof, token} when token == rc_proof -> :ok
                after
                  15_000 -> Repo.rollback(:proof_barrier_timeout)
                end
              end)
            end)
          end)
        end)

      try do
        assert_receive {:proof_holds_source_locks, proof_pid, proof_backend_pid}, 15_000
        assert proof_pid == proof_task.pid

        writer_task =
          Task.async(fn ->
            capture_postgres_error(fn ->
              Sandbox.unboxed_run(Repo, fn ->
                Repo.transaction(fn ->
                  SQL.query!(Repo, "SET LOCAL ROLE maraithon_runtime", [])
                  [[backend_pid]] = SQL.query!(Repo, "SELECT pg_backend_pid()", []).rows
                  send(parent, {:read_committed_writer_started, self(), backend_pid})

                  SQL.query!(
                    Repo,
                    "UPDATE local_browser_visits SET title = $2 WHERE id = $1::uuid",
                    [uuid_param(rc_visit_id), tagged(rc_tag)]
                  )
                end)
              end)
            end)
          end)

        try do
          assert_receive {:read_committed_writer_started, writer_pid, writer_backend_pid}, 15_000
          assert writer_pid == writer_task.pid
          assert_database_blocked_by!(writer_backend_pid, proof_backend_pid)
          send(proof_task.pid, {:commit_proof, rc_proof})
          assert {:ok, {:ok, _}} = Task.await(proof_task, 15_000)
          assert {:postgres_error, "23514", _message} = Task.await(writer_task, 15_000)
        after
          Task.shutdown(writer_task, :brutal_kill)
        end
      after
        send(proof_task.pid, {:commit_proof, rc_proof})
        Task.shutdown(proof_task, :brutal_kill)
      end

      assert [[nil]] =
               unboxed_runtime(fn ->
                 SQL.query!(Repo, "SELECT title FROM local_browser_visits WHERE id = $1::uuid", [
                   uuid_param(rc_visit_id)
                 ]).rows
               end)

      stale_writer =
        Task.async(fn ->
          capture_postgres_error(fn ->
            Sandbox.unboxed_run(Repo, fn ->
              Repo.transaction(fn ->
                SQL.query!(Repo, "SET TRANSACTION ISOLATION LEVEL REPEATABLE READ", [])
                SQL.query!(Repo, "SET LOCAL ROLE maraithon_runtime", [])

                assert [[false]] =
                         SQL.query!(
                           Repo,
                           "SELECT public.durable_payload_key_write_fenced('vault', $1)",
                           [rr_tag]
                         ).rows

                send(parent, {:repeatable_read_snapshot_established, self()})

                receive do
                  {:attempt_stale_write, token} when token == rr_tag -> :ok
                after
                  15_000 -> Repo.rollback(:repeatable_read_barrier_timeout)
                end

                SQL.query!(
                  Repo,
                  "UPDATE local_browser_visits SET title = $2 WHERE id = $1::uuid",
                  [uuid_param(rr_visit_id), tagged(rr_tag)]
                )
              end)
            end)
          end)
        end)

      try do
        assert_receive {:repeatable_read_snapshot_established, stale_writer_pid}, 15_000
        assert stale_writer_pid == stale_writer.pid

        unboxed(fn ->
          Repo.transaction(fn ->
            SQL.query!(Repo, "SET LOCAL ROLE maraithon_incident_operator", [])
            mark_zero_proof!()
            insert_zero_proof_sql!("vault", rr_tag, rr_proof)
          end)
        end)

        assert {:ok, [[true]]} =
                 unboxed(fn ->
                   Repo.transaction(fn ->
                     SQL.query!(Repo, "SET LOCAL ROLE maraithon_runtime", [])

                     SQL.query!(
                       Repo,
                       "SELECT public.durable_payload_key_write_fenced('vault', $1)",
                       [rr_tag]
                     ).rows
                   end)
                 end)

        send(stale_writer.pid, {:attempt_stale_write, rr_tag})
        assert {:postgres_error, "40001", _message} = Task.await(stale_writer, 15_000)
      after
        send(stale_writer.pid, {:attempt_stale_write, rr_tag})
        Task.shutdown(stale_writer, :brutal_kill)
      end

      assert [[nil]] =
               unboxed_runtime(fn ->
                 SQL.query!(Repo, "SELECT title FROM local_browser_visits WHERE id = $1::uuid", [
                   uuid_param(rr_visit_id)
                 ]).rows
               end)
    end)
  end

  defp activate_exact_pair! do
    assert {:ok, attestation} =
             CoordinationProtocol.attest_effect_activation_evidence(@activation_evidence)

    assert attestation in [:attested, :already_attested]

    assert {:ok, effect_status} =
             ProtocolCutover.activate(
               [confirmation: ProtocolCutover.activation_confirmation()] ++ @activation_evidence
             )

    assert effect_status in [:activated, :already_active]

    assert {:ok, runtime_status} =
             CoordinationProtocol.activate(
               [confirmation: CoordinationProtocol.activation_confirmation()] ++
                 @activation_evidence
             )

    assert runtime_status in [:activated, :already_active]
    SQL.query!(Repo, "SET LOCAL ROLE maraithon_runtime", [])
    :ok
  end

  defp insert_zero_proof!(kind, tag, proof_id) do
    in_role!("maraithon_incident_operator", fn ->
      mark_zero_proof!()
      proof = insert_zero_proof_sql!(kind, tag, proof_id)
      clear_local_setting!("maraithon.key_retirement_zero_proof")
      proof
    end)
  end

  defp insert_zero_proof_sql!(kind, tag, proof_id) do
    assert [[stored_proof_id, source_digest, proved_at]] =
             SQL.query!(
               Repo,
               """
               INSERT INTO public.key_retirement_zero_proofs (
                 key_kind, old_tag, proof_id, source_digest, evidence_id,
                 evidence_digest, evidence_operator, exact_revision, proved_at
               ) VALUES (
                 $1, $2, $3::uuid, $4, $5, $6, $7, $8,
                 timezone('UTC', clock_timestamp())
               )
               RETURNING proof_id::text, source_digest, proved_at
               """,
               [
                 kind,
                 tag,
                 uuid_param(proof_id),
                 :crypto.hash(:sha256, "caller-supplied-source-digest"),
                 @evidence_id,
                 @evidence_digest,
                 @evidence_operator,
                 @revision
               ],
               log: false
             ).rows

    assert stored_proof_id == proof_id
    %{proof_id: stored_proof_id, source_digest: source_digest, proved_at: proved_at}
  end

  defp mark_zero_proof! do
    SQL.query!(
      Repo,
      "SELECT set_config('maraithon.key_retirement_zero_proof', 'LIVE_ZERO_PROOF_V1', true)",
      [],
      log: false
    )

    :ok
  end

  defp clear_local_setting!(name) do
    SQL.query!(Repo, "SELECT set_config($1, '', true)", [name], log: false)
    :ok
  end

  # Used only where the proof/live-count gate is not what the test exercises.
  # The AFTER trigger and fence-state guard still execute; the DDL is rolled back
  # with the SQL sandbox and the trigger is restored before catalog checks run.
  defp seed_fence_without_zero_scan!(kind, tag) do
    proof_id = Ecto.UUID.generate()

    in_role!("maraithon_migrator", fn ->
      SQL.query!(
        Repo,
        """
        ALTER TABLE public.key_retirement_zero_proofs
          DISABLE TRIGGER guard_key_retirement_zero_proof_trigger
        """,
        []
      )
    end)

    try do
      in_role!("maraithon_incident_operator", fn ->
        mark_zero_proof!()
        proof = insert_zero_proof_sql!(kind, tag, proof_id)
        clear_local_setting!("maraithon.key_retirement_zero_proof")
        proof
      end)
    after
      in_role!("maraithon_migrator", fn ->
        SQL.query!(
          Repo,
          """
          ALTER TABLE public.key_retirement_zero_proofs
            ENABLE ALWAYS TRIGGER guard_key_retirement_zero_proof_trigger
          """,
          []
        )
      end)
    end
  end

  defp attest_backup!(kind, tag, proof_id) do
    in_role!("maraithon_incident_operator", fn ->
      SQL.query!(
        Repo,
        "SELECT set_config('maraithon.vault_backup_evidence', 'BACKUP_CATALOG_ATTESTED_V1', true)",
        [],
        log: false
      )

      SQL.query!(
        Repo,
        """
        WITH stamp AS (
          SELECT timezone('UTC', clock_timestamp()) AS observed_at
        )
        INSERT INTO public.vault_backup_retirement_evidence (
          key_kind, old_tag, zero_proof_id, evidence_id, evidence_digest,
          evidence_operator, exact_revision, oldest_recoverable_at,
          evidence_expires_at, attested_at,
          backup_catalog_digest, backup_catalog_captured_at,
          backup_oldest_recoverable_at,
          wal_catalog_digest, wal_catalog_captured_at,
          wal_oldest_recoverable_at,
          pitr_catalog_digest, pitr_catalog_captured_at,
          pitr_oldest_recoverable_at,
          restore_drill_digest, restore_drill_completed_at,
          restore_drill_recovered_through_at
        )
        SELECT $1, $2, $3::uuid, $4, $5, $6, $7,
               stamp.observed_at, stamp.observed_at + interval '1 hour',
               stamp.observed_at,
               $8, stamp.observed_at, stamp.observed_at,
               $9, stamp.observed_at, stamp.observed_at,
               $10, stamp.observed_at, stamp.observed_at,
               $11, stamp.observed_at, stamp.observed_at
        FROM stamp
        """,
        [
          kind,
          tag,
          uuid_param(proof_id),
          @evidence_id,
          @evidence_digest,
          @evidence_operator,
          @revision,
          :crypto.hash(:sha256, "backup-catalog:#{proof_id}"),
          :crypto.hash(:sha256, "wal-catalog:#{proof_id}"),
          :crypto.hash(:sha256, "pitr-catalog:#{proof_id}"),
          :crypto.hash(:sha256, "restore-drill:#{proof_id}")
        ],
        log: false
      )
    end)
  end

  defp authorize!(kind, tag, proof_id) do
    in_role!("maraithon_incident_operator", fn ->
      mark_retirement_authorization!()
      authorization = insert_authorization_sql!(kind, tag, proof_id)
      clear_local_setting!("maraithon.key_retirement_authorization")
      clear_local_setting!("maraithon.key_retirement_finalization")
      authorization
    end)
  end

  defp mark_retirement_authorization! do
    SQL.query!(
      Repo,
      "SELECT set_config('maraithon.key_retirement_authorization', 'RETIRE_KEY_AUTHORIZATION_V1', true)",
      [],
      log: false
    )

    :ok
  end

  defp insert_authorization_sql!(kind, tag, proof_id) do
    assert [row] =
             SQL.query!(
               Repo,
               """
               INSERT INTO public.retired_durable_payload_keys (
                 key_kind, old_tag, zero_proof_id, backup_evidence_id,
                 source_digest, fence_generation, evidence_id, evidence_digest,
                 evidence_operator, exact_revision, authorized_at
               ) VALUES (
                 $1, $2, $3::uuid, $4, $5, 999999, 'caller:evidence', $6,
                 'caller@example.test', $7, timezone('UTC', clock_timestamp())
               )
               RETURNING zero_proof_id::text, source_digest, fence_generation,
                         evidence_id, evidence_digest, evidence_operator, exact_revision
               """,
               [
                 kind,
                 tag,
                 uuid_param(proof_id),
                 @evidence_id,
                 :crypto.hash(:sha256, "caller-authorization-source"),
                 :crypto.hash(:sha256, "caller-authorization-evidence"),
                 String.duplicate("a", 40)
               ],
               log: false
             ).rows

    [
      zero_proof_id,
      source_digest,
      fence_generation,
      evidence_id,
      evidence_digest,
      evidence_operator,
      exact_revision
    ] = row

    %{
      zero_proof_id: zero_proof_id,
      source_digest: source_digest,
      fence_generation: fence_generation,
      evidence_id: evidence_id,
      evidence_digest: evidence_digest,
      evidence_operator: evidence_operator,
      exact_revision: exact_revision
    }
  end

  defp fence_state do
    in_role!("maraithon_migrator", fn ->
      assert [[generation, fences]] =
               SQL.query!(
                 Repo,
                 "SELECT generation, fences FROM durable_payload_key_fence_state WHERE singleton",
                 []
               ).rows

      {generation, fences}
    end)
  end

  defp parsed_tag(ciphertext) do
    in_role!("maraithon_migrator", fn ->
      assert [[tag]] =
               SQL.query!(
                 Repo,
                 "SELECT public.durable_payload_ciphertext_key_tag($1::bytea)",
                 [ciphertext]
               ).rows

      tag
    end)
  end

  defp visit_tag(id) do
    in_role!("maraithon_migrator", fn ->
      SQL.query!(
        Repo,
        """
        SELECT public.durable_payload_ciphertext_key_tag(title)
        FROM local_browser_visits WHERE id = $1::uuid
        """,
        [uuid_param(id)]
      ).rows
    end)
  end

  defp visit_count(id) do
    SQL.query!(
      Repo,
      "SELECT count(*) FROM local_browser_visits WHERE id = $1::uuid",
      [uuid_param(id)]
    ).rows
  end

  defp insert_visit!(ciphertext, id \\ Ecto.UUID.generate()) do
    SQL.query!(
      Repo,
      """
      INSERT INTO public.local_browser_visits (
        id, user_id, device_id, browser, url, title, inserted_at, updated_at
      ) VALUES (
        $1::uuid, $2, $3::uuid, 'key-fence-test', $4, $5,
        timezone('UTC', clock_timestamp()), timezone('UTC', clock_timestamp())
      )
      """,
      [
        uuid_param(id),
        "key-fence-user-#{id}",
        uuid_param(Ecto.UUID.generate()),
        "https://example.test/key-fence/#{id}",
        ciphertext
      ],
      log: false
    )

    id
  end

  defp assert_postgres_code(code, fun),
    do: assert_postgres_code(code, "maraithon_runtime", fun)

  defp assert_postgres_code(code, role, fun) do
    error =
      assert_raise Postgrex.Error, fn ->
        Repo.transaction(
          fn ->
            SQL.query!(Repo, "SET LOCAL ROLE #{role}", [])
            fun.()
          end,
          mode: :savepoint
        )
      end

    assert error.postgres.pg_code == code,
           "expected SQLSTATE #{code}, got #{inspect(error.postgres)}"

    error
  end

  defp in_role!(role, fun) do
    case Repo.transaction(
           fn ->
             SQL.query!(Repo, "SET LOCAL ROLE #{role}", [])
             value = fun.()
             SQL.query!(Repo, "SET LOCAL ROLE maraithon_runtime", [])
             value
           end,
           mode: :savepoint
         ) do
      {:ok, value} -> value
      {:error, reason} -> flunk("role-scoped transaction failed: #{inspect(reason)}")
    end
  end

  defp await_database_clock_after!(earlier) do
    assert [[later]] =
             SQL.query!(
               Repo,
               """
               SELECT observed_at
               FROM (
                 SELECT timezone('UTC', clock_timestamp()) AS observed_at
                 FROM pg_catalog.generate_series(1, 100000)
               ) AS samples
               WHERE observed_at > $1::timestamp
               LIMIT 1
               """,
               [earlier],
               log: false
             ).rows

    assert NaiveDateTime.compare(later, earlier) == :gt
    :ok
  end

  defp with_committed_fence_harness(visit_ids, fun) do
    snapshot = unboxed(&committed_harness_snapshot!/0)
    unboxed(&force_committed_exact_pair!/0)

    try do
      fun.()
    after
      unboxed(fn -> restore_committed_harness!(snapshot, visit_ids) end)
    end
  end

  defp committed_harness_snapshot! do
    assert {:ok, snapshot} =
             Repo.transaction(fn ->
               SQL.query!(Repo, "SET LOCAL ROLE maraithon_migrator", [])

               effect =
                 SQL.query!(
                   Repo,
                   """
                   SELECT mode, activated_at, activation_epoch, activation_evidence_id,
                          activation_evidence_digest, activated_by, exact_revision, updated_at
                   FROM effect_execution_protocols WHERE name = 'effects'
                   """,
                   []
                 ).rows
                 |> List.first()

               runtime =
                 SQL.query!(
                   Repo,
                   """
                   SELECT mode, activated_at, activation_epoch, activation_evidence_id,
                          activation_evidence_digest, activated_by, exact_revision, updated_at
                   FROM runtime_coordination_protocols WHERE name = 'runtime'
                   """,
                   []
                 ).rows
                 |> List.first()

               assert [[generation, fences, updated_at]] =
                        SQL.query!(
                          Repo,
                          """
                          SELECT generation, fences, updated_at
                          FROM durable_payload_key_fence_state WHERE singleton
                          """,
                          []
                        ).rows

               %{effect: effect, runtime: runtime, fence: [generation, fences, updated_at]}
             end)

    snapshot
  end

  defp force_committed_exact_pair! do
    Repo.transaction(fn ->
      SQL.query!(Repo, "SET LOCAL ROLE maraithon_migrator", [])
      disable_protocol_guards!()

      SQL.query!(
        Repo,
        """
        UPDATE effect_execution_protocols
        SET mode = 'generation_fenced_v1',
            activated_at = timezone('UTC', clock_timestamp()),
            activation_epoch = $1::uuid,
            activation_evidence_id = $2,
            activation_evidence_digest = $3,
            activated_by = $4,
            exact_revision = $5,
            updated_at = timezone('UTC', clock_timestamp())
        WHERE name = 'effects'
        """,
        [
          uuid_param(Ecto.UUID.generate()),
          @evidence_id,
          @evidence_digest,
          @evidence_operator,
          @revision
        ]
      )

      SQL.query!(
        Repo,
        """
        UPDATE runtime_coordination_protocols
        SET mode = 'partition_fenced_v1',
            activated_at = timezone('UTC', clock_timestamp()),
            activation_epoch = $1::uuid,
            activation_evidence_id = $2,
            activation_evidence_digest = $3,
            activated_by = $4,
            exact_revision = $5,
            updated_at = timezone('UTC', clock_timestamp())
        WHERE name = 'runtime'
        """,
        [
          uuid_param(Ecto.UUID.generate()),
          @evidence_id,
          @evidence_digest,
          @evidence_operator,
          @revision
        ]
      )

      enable_protocol_guards!()
    end)
  end

  defp restore_committed_harness!(snapshot, visit_ids) do
    Repo.transaction(fn ->
      SQL.query!(Repo, "SET LOCAL ROLE maraithon_migrator", [])

      SQL.query!(Repo, "DELETE FROM local_browser_visits WHERE id = ANY($1::uuid[])", [
        Enum.map(visit_ids, &uuid_param/1)
      ])

      SQL.query!(
        Repo,
        """
        ALTER TABLE key_retirement_zero_proofs
          DISABLE TRIGGER guard_key_retirement_zero_proof_trigger
        """,
        []
      )

      SQL.query!(
        Repo,
        """
        ALTER TABLE key_retirement_zero_proofs
          DISABLE TRIGGER sync_durable_payload_key_fence_from_zero_proof_trigger
        """,
        []
      )

      SQL.query!(
        Repo,
        "DELETE FROM key_retirement_zero_proofs WHERE evidence_id = $1",
        [@evidence_id]
      )

      SQL.query!(
        Repo,
        """
        ALTER TABLE durable_payload_key_fence_state
          DISABLE TRIGGER guard_durable_payload_key_fence_state_trigger
        """,
        []
      )

      [generation, fences, fence_updated_at] = snapshot.fence

      SQL.query!(
        Repo,
        """
        UPDATE durable_payload_key_fence_state
        SET generation = $1, fences = $2::jsonb, updated_at = $3
        WHERE singleton
        """,
        [generation, fences, fence_updated_at]
      )

      SQL.query!(
        Repo,
        """
        ALTER TABLE durable_payload_key_fence_state
          ENABLE ALWAYS TRIGGER guard_durable_payload_key_fence_state_trigger
        """,
        []
      )

      SQL.query!(
        Repo,
        """
        ALTER TABLE key_retirement_zero_proofs
          ENABLE ALWAYS TRIGGER guard_key_retirement_zero_proof_trigger
        """,
        []
      )

      SQL.query!(
        Repo,
        """
        ALTER TABLE key_retirement_zero_proofs
          ENABLE ALWAYS TRIGGER sync_durable_payload_key_fence_from_zero_proof_trigger
        """,
        []
      )

      disable_protocol_guards!()
      restore_protocol_row!("effect_execution_protocols", snapshot.effect)
      restore_protocol_row!("runtime_coordination_protocols", snapshot.runtime)
      enable_protocol_guards!()
    end)
  end

  defp restore_protocol_row!(table, row) do
    [mode, activated_at, epoch, evidence_id, evidence_digest, activated_by, revision, updated_at] =
      row

    name = if table == "effect_execution_protocols", do: "effects", else: "runtime"

    SQL.query!(
      Repo,
      """
      UPDATE #{table}
      SET mode = $1, activated_at = $2, activation_epoch = $3::uuid,
          activation_evidence_id = $4, activation_evidence_digest = $5,
          activated_by = $6, exact_revision = $7, updated_at = $8
      WHERE name = $9
      """,
      [
        mode,
        activated_at,
        epoch,
        evidence_id,
        evidence_digest,
        activated_by,
        revision,
        updated_at,
        name
      ]
    )
  end

  defp disable_protocol_guards! do
    Enum.each(
      [
        "ALTER TABLE effect_execution_protocols DISABLE TRIGGER enforce_effect_protocol_one_way_trigger",
        "ALTER TABLE effect_execution_protocols DISABLE TRIGGER enforce_effect_activation_evidence_trigger",
        "ALTER TABLE effect_execution_protocols DISABLE TRIGGER enforce_operational_privacy_activation_trigger",
        "ALTER TABLE runtime_coordination_protocols DISABLE TRIGGER enforce_runtime_coordination_protocol_trigger"
      ],
      &SQL.query!(Repo, &1, [])
    )
  end

  defp enable_protocol_guards! do
    Enum.each(
      [
        "ALTER TABLE effect_execution_protocols ENABLE TRIGGER enforce_effect_protocol_one_way_trigger",
        "ALTER TABLE effect_execution_protocols ENABLE TRIGGER enforce_effect_activation_evidence_trigger",
        "ALTER TABLE effect_execution_protocols ENABLE TRIGGER enforce_operational_privacy_activation_trigger",
        "ALTER TABLE runtime_coordination_protocols ENABLE TRIGGER enforce_runtime_coordination_protocol_trigger"
      ],
      &SQL.query!(Repo, &1, [])
    )
  end

  defp assert_source_order!(source, first_fragment, second_fragment) do
    {first_offset, _length} = :binary.match(source, first_fragment)
    {second_offset, _length} = :binary.match(source, second_fragment)

    assert first_offset < second_offset,
           "expected #{inspect(first_fragment)} before #{inspect(second_fragment)}"
  end

  defp assert_database_blocked_by!(blocked_pid, blocker_pid) do
    unboxed(fn ->
      deadline = System.monotonic_time(:millisecond) + 10_000
      await_database_blocker!(blocked_pid, blocker_pid, deadline)
    end)
  end

  defp await_database_blocker!(blocked_pid, blocker_pid, deadline) do
    assert [[blockers]] =
             SQL.query!(
               Repo,
               "SELECT pg_catalog.pg_blocking_pids($1)",
               [blocked_pid],
               log: false
             ).rows

    cond do
      blocker_pid in blockers ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        flunk(
          "backend #{blocked_pid} never blocked behind proof backend #{blocker_pid}; " <>
            "last blockers=#{inspect(blockers)}"
        )

      true ->
        # pg_blocking_pids is the barrier: no timing sleep is used to infer a race.
        await_database_blocker!(blocked_pid, blocker_pid, deadline)
    end
  end

  defp unboxed(fun) do
    Task.async(fn -> Sandbox.unboxed_run(Repo, fun) end)
    |> Task.await(180_000)
  end

  defp unboxed_runtime(fun) do
    unboxed(fn ->
      assert {:ok, value} =
               Repo.transaction(fn ->
                 SQL.query!(Repo, "SET LOCAL ROLE maraithon_runtime", [])
                 fun.()
               end)

      value
    end)
  end

  defp capture_postgres_error(fun) do
    {:ok, fun.()}
  rescue
    error in Postgrex.Error ->
      {:postgres_error, error.postgres.pg_code, error.postgres.message}
  catch
    :exit, reason -> {:exit, reason}
  end

  defp tagged(tag, trailer \\ <<>>) do
    <<1, byte_size(tag)>> <> tag <> trailer
  end

  defp unique_tag(prefix) do
    "#{prefix}.#{System.unique_integer([:positive, :monotonic])}"
  end

  defp uuid_param(uuid), do: Ecto.UUID.dump!(uuid)

  defp csv_field(value) do
    escaped = value |> to_string() |> String.replace("\"", "\"\"")
    "\"" <> escaped <> "\""
  end
end
