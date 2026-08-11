defmodule Maraithon.PrivacyErasureJobDeferralReceiptTest do
  use Maraithon.DataCase, async: false

  alias Ecto.Adapters.SQL
  alias Ecto.Adapters.SQL.Sandbox
  alias Maraithon.DurablePayloadContraction
  alias Maraithon.Privacy.ErasureRequest
  alias Maraithon.Repo
  alias Maraithon.Runtime.BackgroundJob
  alias Maraithon.Runtime.Coordination.Protocol, as: CoordinationProtocol

  @moduletag database_role: :session
  @moduletag timeout: 180_000

  @evidence_id "test:privacy-erasure-job-deferral"
  @evidence_digest :crypto.hash(:sha256, "privacy erasure job deferral stopped fleet")
  @evidence_operator "privacy-deferral-test@example.test"
  @revision String.duplicate("e", 40)

  @contraction_opts [
    confirmation: "NON_ROLLING_FLEET_DRAINED",
    evidence_id: @evidence_id,
    evidence_digest: @evidence_digest,
    operator: @evidence_operator,
    revision: @revision
  ]

  @attestation_opts [
    evidence_id: @evidence_id,
    evidence_digest: @evidence_digest,
    activated_by: @evidence_operator,
    exact_revision: @revision
  ]

  @coordination_identity_variants [
    {:claim_token, "claim_token = $2::uuid"},
    {:claimed_by, "claimed_by = 'legacy-worker'"},
    {:claimed_at, "claimed_at = timezone('UTC', clock_timestamp())"},
    {:partition, "tenant_key = 'system:privacy', partition_id = 0"},
    {:coordination_activation_epoch, "coordination_activation_epoch = $2::uuid"},
    {:coordination_partition_epoch, "coordination_partition_epoch = 1"},
    {:coordination_node_incarnation_id, "coordination_node_incarnation_id = $2::uuid"},
    {:coordination_task_assignment_id, "coordination_task_assignment_id = $2::uuid"},
    {:coordination_task_supervisor_id, "coordination_task_supervisor_id = $2::uuid"},
    {:coordination_local_task_id, "coordination_local_task_id = $2::uuid"}
  ]

  setup_all do
    protocol_snapshot = unboxed(&effect_protocol_snapshot!/0)

    assert ["legacy", nil, nil] = Enum.take(protocol_snapshot, 3)

    assert {:ok, {:ok, status}} =
             unboxed(fn ->
               login_transaction("maraithon_activation_operator", fn ->
                 CoordinationProtocol.attest_effect_activation_evidence(@attestation_opts)
               end)
             end)

    assert status in [:attested, :already_attested]

    on_exit(fn -> unboxed(fn -> restore_effect_protocol!(protocol_snapshot) end) end)
    :ok
  end

  test "an exact legacy privacy job contracts atomically and its durable receipt exempts the next transaction" do
    fixture = fixture!()
    on_exit(fn -> cleanup_fixtures!([fixture]) end)

    assert %{background_jobs: 0, total: 0} = preflight!()

    parent = self()
    token = make_ref()

    contractor =
      Task.async(fn ->
        Sandbox.unboxed_run(Repo, fn ->
          assert {:ok, :contracted} =
                   login_transaction("maraithon_activation_operator", fn ->
                     assert {:ok, :contracted} =
                              DurablePayloadContraction.transaction(@contraction_opts, fn ->
                                assert %{rows: [[%{}, %{}]]} =
                                         SQL.query!(
                                           Repo,
                                           """
                                           UPDATE public.background_jobs
                                           SET payload = '{}'::jsonb,
                                               result = '{}'::jsonb,
                                               updated_at = timezone('UTC', clock_timestamp())
                                           WHERE id = $1::uuid
                                           RETURNING payload, result
                                           """,
                                           [uuid_param(fixture.job_id)]
                                         )

                                assert [[1]] =
                                         SQL.query!(
                                           Repo,
                                           """
                                           SELECT COUNT(*)
                                           FROM public.privacy_erasure_job_deferral_receipts
                                           WHERE job_id = $1::uuid
                                           """,
                                           [uuid_param(fixture.job_id)]
                                         ).rows

                                [[backend_pid]] =
                                  SQL.query!(Repo, "SELECT pg_backend_pid()", []).rows

                                send(
                                  parent,
                                  {:contraction_ready_to_commit, self(), token, backend_pid}
                                )

                                receive do
                                  {:commit_contraction, ^token} -> :contracted
                                after
                                  15_000 -> Repo.rollback(:contraction_commit_barrier_timeout)
                                end
                              end)

                     :contracted
                   end)

          :contracted
        end)
      end)

    try do
      assert_receive {:contraction_ready_to_commit, contractor_pid, ^token, backend_pid}, 15_000
      assert contractor_pid == contractor.pid
      assert is_integer(backend_pid)

      # A genuinely separate connection observes neither half before commit.
      assert [[%{"request_id" => request_id}, %{}, 0]] =
               unboxed(fn ->
                 SQL.query!(
                   Repo,
                   """
                   SELECT job.payload, job.result,
                          (SELECT COUNT(*)
                           FROM public.privacy_erasure_job_deferral_receipts AS receipt
                           WHERE receipt.job_id = job.id)
                   FROM public.background_jobs AS job
                   WHERE job.id = $1::uuid
                   """,
                   [uuid_param(fixture.job_id)]
                 ).rows
               end)

      assert request_id == fixture.request_id
      send(contractor.pid, {:commit_contraction, token})
      assert :contracted = Task.await(contractor, 15_000)
    after
      send(contractor.pid, {:commit_contraction, token})
      Task.shutdown(contractor, :brutal_kill)
    end

    assert [[%{}, %{}, true, true, receipt]] =
             unboxed(fn ->
               SQL.query!(
                 Repo,
                 """
                 SELECT job.payload, job.result,
                        job.payload_ciphertext IS NOT NULL,
                        job.result_ciphertext IS NOT NULL,
                        to_jsonb(receipt)
                 FROM public.background_jobs AS job
                 JOIN public.privacy_erasure_job_deferral_receipts AS receipt
                   ON receipt.job_id = job.id
                 WHERE job.id = $1::uuid
                 """,
                 [uuid_param(fixture.job_id)]
               ).rows
             end)

    assert Map.keys(receipt) |> Enum.sort() ==
             ~w(classification dedupe_key established_at job_id job_type queue request_id)

    assert receipt["job_id"] == fixture.job_id
    assert receipt["request_id"] == fixture.request_id
    assert receipt["classification"] == "privacy_erasure_job_deferral_v1"
    assert receipt["queue"] == "privacy"
    assert receipt["job_type"] == "privacy_erasure"
    assert receipt["dedupe_key"] == "privacy-erasure:#{fixture.request_id}"

    # This is a new top-level PostgreSQL contraction transaction, not a nested
    # sandbox savepoint. The durable receipt, rather than a transaction-local
    # marker, must still exempt the same job.
    assert {:ok, counts} =
             contraction(fn -> DurablePayloadContraction.work_preflight() end)

    assert counts.background_jobs == 0
    assert counts.total == 0
  end

  test "completed requests and an exact protocol pair cannot enter the exemption" do
    completed = fixture!(request_state: "completed")
    on_exit(fn -> cleanup_fixtures!([completed]) end)

    assert %{background_jobs: 1, total: 1} = preflight!()

    assert {:error, {:durable_payload_contraction_requires_drain, 1}} =
             contraction(fn -> flunk("completed request reached the contraction callback") end)

    assert {"23514", message} =
             authorized_projection_error(completed,
               marker?: true,
               source_lock?: true
             )

    assert message =~ "Privacy erasure job deferral authority is missing"
    assert_projection_and_receipt!(completed, %{"request_id" => completed.request_id}, 0)

    active = fixture!()
    on_exit(fn -> cleanup_fixtures!([active]) end)

    assert {:error, exact_counts} =
             unboxed(fn ->
               Repo.transaction(fn ->
                 force_exact_pair!()
                 set_session_authorization!("maraithon_activation_operator")
                 Repo.rollback(DurablePayloadContraction.work_preflight())
               end)
             end)

    assert exact_counts.background_jobs == 2
    assert exact_counts.total == 2

    assert {"23514", exact_message} = exact_projection_error(active)
    assert exact_message =~ "requires dark legacy evidence"
    assert_projection_and_receipt!(active, %{"request_id" => active.request_id}, 0)
  end

  test "a receipt cannot be laundered onto a different request identity" do
    source = fixture!()
    target_request = request!()
    on_exit(fn -> cleanup_fixtures!([source, %{request_id: target_request.id}]) end)

    assert {:ok, :contracted} =
             contraction(fn ->
               clear_projection!(source.job_id)
               :contracted
             end)

    assert {:ok, :laundered_job_identity} =
             runtime_transaction(fn ->
               assert %{num_rows: 1} =
                        SQL.query!(
                          Repo,
                          """
                          UPDATE public.background_jobs
                          SET dedupe_key = 'privacy-erasure:' || $2::uuid::text,
                              updated_at = timezone('UTC', clock_timestamp())
                          WHERE id = $1::uuid
                          """,
                          [uuid_param(source.job_id), uuid_param(target_request.id)]
                        )

               :laundered_job_identity
             end)

    assert %{background_jobs: 1, total: 1} = preflight!()

    assert {:error, {:durable_payload_contraction_requires_drain, 1}} =
             contraction(fn -> flunk("mismatched receipt bypassed the drain") end)

    assert [[source_request_id, source_dedupe, 0]] =
             unboxed(fn ->
               SQL.query!(
                 Repo,
                 """
                 SELECT receipt.request_id::text, receipt.dedupe_key,
                        (SELECT COUNT(*)
                         FROM public.privacy_erasure_job_deferral_receipts AS other
                         WHERE other.request_id = $2::uuid)
                 FROM public.privacy_erasure_job_deferral_receipts AS receipt
                 WHERE receipt.job_id = $1::uuid
                 """,
                 [uuid_param(source.job_id), uuid_param(target_request.id)]
               ).rows
             end)

    assert source_request_id == source.request_id
    assert source_dedupe == "privacy-erasure:#{source.request_id}"
  end

  test "every claim, assignment, partition, or coordination identity blocks exemption" do
    fixtures = Enum.map(@coordination_identity_variants, fn _variant -> fixture!() end)
    on_exit(fn -> cleanup_fixtures!(fixtures) end)

    assert {:ok, :poisoned} =
             runtime_transaction(fn ->
               Enum.zip(fixtures, @coordination_identity_variants)
               |> Enum.each(fn {fixture, variant} ->
                 poison_identity!(fixture.job_id, variant)
               end)

               :poisoned
             end)

    expected = length(@coordination_identity_variants)
    counts = preflight!()
    assert counts.background_jobs == expected
    assert counts.total == expected

    assert {:error, {:durable_payload_contraction_requires_drain, ^expected}} =
             contraction(fn -> flunk("identified work bypassed the contraction drain") end)
  end

  test "receipts reject UPDATE, DELETE, and TRUNCATE even from the migrator owner member" do
    fixture = fixture!()
    on_exit(fn -> cleanup_fixtures!([fixture]) end)

    assert {:ok, :contracted} =
             contraction(fn ->
               clear_projection!(fixture.job_id)
               :contracted
             end)

    mutations = [
      """
      UPDATE public.privacy_erasure_job_deferral_receipts
      SET established_at = established_at
      WHERE job_id = '#{fixture.job_id}'::uuid
      """,
      """
      DELETE FROM public.privacy_erasure_job_deferral_receipts
      WHERE job_id = '#{fixture.job_id}'::uuid
      """,
      "TRUNCATE TABLE public.privacy_erasure_job_deferral_receipts"
    ]

    Enum.each(mutations, fn statement ->
      assert {"42501", message} =
               unboxed_postgres_error(fn ->
                 login_transaction("maraithon_migrator", fn ->
                   SQL.query!(Repo, statement, [])
                 end)
               end)

      assert message =~ "Privacy erasure job deferral receipts are append-only"
    end)

    assert [[1]] = receipt_count(fixture.job_id)
  end

  test "marker, source lock, and session authority are all required to mint a receipt" do
    fixture = fixture!()
    on_exit(fn -> cleanup_fixtures!([fixture]) end)

    assert {"42501", runtime_message} =
             raw_projection_error(fixture, "maraithon_runtime",
               marker?: false,
               source_lock?: false
             )

    assert runtime_message =~ "requires contraction authority"
    assert_projection_and_receipt!(fixture, %{"request_id" => fixture.request_id}, 0)

    assert {"42501", marker_message} =
             authorized_projection_error(fixture,
               marker?: false,
               source_lock?: true
             )

    assert marker_message =~ "requires contraction authority"
    assert_projection_and_receipt!(fixture, %{"request_id" => fixture.request_id}, 0)

    assert {"55000", lock_message} =
             authorized_projection_error(fixture,
               marker?: true,
               source_lock?: false
             )

    assert lock_message =~ "requires the contraction source lock"
    assert_projection_and_receipt!(fixture, %{"request_id" => fixture.request_id}, 0)

    # The activation login has no INSERT authority; only the SECURITY DEFINER
    # projection trigger may append this receipt class.
    assert {"42501", direct_insert_message} =
             unboxed_postgres_error(fn ->
               login_transaction("maraithon_activation_operator", fn ->
                 SQL.query!(
                   Repo,
                   """
                   INSERT INTO public.privacy_erasure_job_deferral_receipts (
                     job_id, request_id, classification, queue, job_type,
                     dedupe_key, established_at
                   ) VALUES (
                     $1::uuid, $2::uuid, 'privacy_erasure_job_deferral_v1',
                     'privacy', 'privacy_erasure',
                     'privacy-erasure:' || $2::uuid::text,
                     timezone('UTC', clock_timestamp())
                   )
                   """,
                   [uuid_param(fixture.job_id), uuid_param(fixture.request_id)]
                 )
               end)
             end)

    assert direct_insert_message =~ "permission denied"
    assert_projection_and_receipt!(fixture, %{"request_id" => fixture.request_id}, 0)
  end

  defp fixture!(opts \\ []) do
    assert {:ok, fixture} =
             runtime_transaction(fn ->
               request = request!(Keyword.get(opts, :request_state, "requested"))

               job =
                 %BackgroundJob{}
                 |> BackgroundJob.changeset(%{
                   queue: "privacy",
                   job_type: "privacy_erasure",
                   payload: %{"request_id" => request.id},
                   result: %{},
                   dedupe_key: "privacy-erasure:#{request.id}",
                   scheduled_at: DateTime.utc_now()
                 })
                 |> Repo.insert!()

               %{request_id: request.id, job_id: job.id}
             end)

    # 140004 intentionally leaves pre-expansion rows nullable while runtime is
    # dark. Reconstruct that historical shape after the current INSERT trigger
    # assigns all newly-created work a partition.
    assert {:ok, :legacy_partition_cleared} =
             unboxed(fn ->
               Repo.transaction(fn ->
                 SQL.query!(Repo, "SET LOCAL session_replication_role = replica", [])

                 assert %{num_rows: 1} =
                          SQL.query!(
                            Repo,
                            """
                            UPDATE public.background_jobs
                            SET tenant_key = NULL, partition_id = NULL
                            WHERE id = $1::uuid
                            """,
                            [uuid_param(fixture.job_id)]
                          )

                 :legacy_partition_cleared
               end)
             end)

    fixture
  end

  defp request!(state \\ "requested") do
    now = DateTime.utc_now()

    attrs = %{
      scope: "user",
      state: state,
      requested_at: now,
      target_agent_count: 0
    }

    attrs =
      if state == "completed" do
        attrs
        |> Map.put(:completed_at, now)
        |> Map.put(:expires_at, DateTime.add(now, 86_400, :second))
      else
        attrs
      end

    %ErasureRequest{}
    |> ErasureRequest.changeset(attrs)
    |> Repo.insert!()
  end

  defp clear_projection!(job_id) do
    assert %{rows: [[%{}, %{}]]} =
             SQL.query!(
               Repo,
               """
               UPDATE public.background_jobs
               SET payload = '{}'::jsonb,
                   result = '{}'::jsonb,
                   updated_at = timezone('UTC', clock_timestamp())
               WHERE id = $1::uuid
               RETURNING payload, result
               """,
               [uuid_param(job_id)]
             )

    :ok
  end

  defp poison_identity!(job_id, {_name, assignment}) do
    params =
      if String.contains?(assignment, "$2::uuid") do
        [uuid_param(job_id), uuid_param(Ecto.UUID.generate())]
      else
        [uuid_param(job_id)]
      end

    assert %{num_rows: 1} =
             SQL.query!(
               Repo,
               "UPDATE public.background_jobs SET #{assignment} WHERE id = $1::uuid",
               params
             )
  end

  defp preflight! do
    assert {:ok, counts} =
             activation_transaction(fn -> DurablePayloadContraction.work_preflight() end)

    counts
  end

  defp contraction(fun) when is_function(fun, 0) do
    # The production entry point establishes maraithon_activation_operator with
    # SET LOCAL ROLE inside its own top-level transaction.
    unboxed(fn -> DurablePayloadContraction.transaction(@contraction_opts, fun) end)
  end

  defp activation_transaction(fun),
    do:
      unboxed(fn ->
        login_transaction("maraithon_activation_operator", fun)
      end)

  defp runtime_transaction(fun),
    do:
      unboxed(fn ->
        login_transaction("maraithon_runtime", fun)
      end)

  defp login_transaction(role, fun)
       when role in [
              "maraithon_runtime",
              "maraithon_activation_operator",
              "maraithon_migrator"
            ] and is_function(fun, 0) do
    Repo.transaction(fn ->
      set_session_authorization!(role)
      fun.()
    end)
  end

  defp set_session_authorization!(role)
       when role in [
              "maraithon_runtime",
              "maraithon_activation_operator",
              "maraithon_migrator"
            ] do
    SQL.query!(Repo, "SET LOCAL SESSION AUTHORIZATION " <> role, [])

    assert [[^role, ^role]] =
             SQL.query!(Repo, "SELECT session_user, current_user", []).rows

    :ok
  end

  defp authorized_projection_error(fixture, opts),
    do:
      raw_projection_error(
        fixture,
        "maraithon_activation_operator",
        opts
      )

  defp exact_projection_error(fixture) do
    unboxed_postgres_error(fn ->
      Repo.transaction(fn ->
        force_exact_pair!()
        set_session_authorization!("maraithon_activation_operator")
        SQL.query!(Repo, "SELECT public.lock_durable_payload_contraction_sources()", [])

        SQL.query!(
          Repo,
          "SELECT set_config('maraithon.payload_contraction', 'STOPPED_FLEET_EVIDENCE_V1', true)",
          []
        )

        clear_projection!(fixture.job_id)
      end)
    end)
  end

  defp raw_projection_error(fixture, role, opts) do
    unboxed_postgres_error(fn ->
      login_transaction(role, fn ->
        if Keyword.fetch!(opts, :source_lock?) do
          SQL.query!(
            Repo,
            "SELECT public.lock_durable_payload_contraction_sources()",
            []
          )
        end

        if Keyword.fetch!(opts, :marker?) do
          SQL.query!(
            Repo,
            "SELECT set_config('maraithon.payload_contraction', 'STOPPED_FLEET_EVIDENCE_V1', true)",
            []
          )
        end

        clear_projection!(fixture.job_id)
      end)
    end)
  end

  defp assert_projection_and_receipt!(fixture, expected_payload, expected_receipts) do
    assert [[^expected_payload, ^expected_receipts]] =
             unboxed(fn ->
               SQL.query!(
                 Repo,
                 """
                 SELECT job.payload,
                        (SELECT COUNT(*)
                         FROM public.privacy_erasure_job_deferral_receipts AS receipt
                         WHERE receipt.job_id = job.id)
                 FROM public.background_jobs AS job
                 WHERE job.id = $1::uuid
                 """,
                 [uuid_param(fixture.job_id)]
               ).rows
             end)
  end

  defp receipt_count(job_id) do
    unboxed(fn ->
      SQL.query!(
        Repo,
        """
        SELECT COUNT(*)
        FROM public.privacy_erasure_job_deferral_receipts
        WHERE job_id = $1::uuid
        """,
        [uuid_param(job_id)]
      ).rows
    end)
  end

  defp force_exact_pair! do
    epoch = uuid_param(Ecto.UUID.generate())

    SQL.query!(Repo, "SET LOCAL session_replication_role = replica", [])

    SQL.query!(
      Repo,
      """
      UPDATE public.runtime_coordination_protocols
      SET mode = 'partition_fenced_v1',
          activation_epoch = $1::uuid,
          activated_at = timezone('UTC', clock_timestamp()),
          activation_evidence_id = $2,
          activation_evidence_digest = $3,
          activated_by = $4,
          exact_revision = $5,
          updated_at = timezone('UTC', clock_timestamp())
      WHERE name = 'runtime'
      """,
      [epoch, @evidence_id, @evidence_digest, @evidence_operator, @revision]
    )

    SQL.query!(
      Repo,
      """
      UPDATE public.effect_execution_protocols
      SET mode = 'generation_fenced_v1',
          activation_epoch = $1::uuid,
          activated_at = timezone('UTC', clock_timestamp()),
          updated_at = timezone('UTC', clock_timestamp())
      WHERE name = 'effects'
      """,
      [epoch]
    )

    SQL.query!(Repo, "SET LOCAL session_replication_role = origin", [])
    :ok
  end

  defp effect_protocol_snapshot! do
    assert [row] =
             SQL.query!(
               Repo,
               """
               SELECT mode, activated_at, activation_epoch,
                      activation_evidence_id, activation_evidence_digest,
                      activated_by, exact_revision, updated_at
               FROM public.effect_execution_protocols
               WHERE name = 'effects'
               """,
               []
             ).rows

    row
  end

  defp restore_effect_protocol!([
         mode,
         activated_at,
         activation_epoch,
         evidence_id,
         evidence_digest,
         activated_by,
         exact_revision,
         updated_at
       ]) do
    assert {:ok, :restored} =
             Repo.transaction(fn ->
               SQL.query!(Repo, "SET LOCAL session_replication_role = replica", [])

               assert %{num_rows: 1} =
                        SQL.query!(
                          Repo,
                          """
                          UPDATE public.effect_execution_protocols
                          SET mode = $1, activated_at = $2, activation_epoch = $3,
                              activation_evidence_id = $4,
                              activation_evidence_digest = $5,
                              activated_by = $6, exact_revision = $7,
                              updated_at = $8
                          WHERE name = 'effects'
                          """,
                          [
                            mode,
                            activated_at,
                            activation_epoch,
                            evidence_id,
                            evidence_digest,
                            activated_by,
                            exact_revision,
                            updated_at
                          ]
                        )

               :restored
             end)
  end

  defp cleanup_fixtures!(fixtures) do
    job_ids =
      fixtures
      |> Enum.flat_map(fn fixture -> if fixture[:job_id], do: [fixture.job_id], else: [] end)
      |> Enum.map(&uuid_param/1)

    request_ids =
      fixtures
      |> Enum.map(&uuid_param(&1.request_id))

    unboxed(fn ->
      assert {:ok, :cleaned} =
               Repo.transaction(fn ->
                 SQL.query!(Repo, "SET LOCAL ROLE maraithon_migrator", [])

                 SQL.query!(
                   Repo,
                   """
                   ALTER TABLE public.privacy_erasure_job_deferral_receipts
                   DISABLE TRIGGER reject_privacy_erasure_job_deferral_receipt_mutation_trigger
                   """,
                   []
                 )

                 SQL.query!(
                   Repo,
                   """
                   ALTER TABLE public.privacy_erasure_job_deferral_receipts
                   DISABLE TRIGGER reject_privacy_erasure_job_deferral_receipt_truncate_trigger
                   """,
                   []
                 )

                 unless job_ids == [] do
                   SQL.query!(
                     Repo,
                     """
                     DELETE FROM public.privacy_erasure_job_deferral_receipts
                     WHERE job_id = ANY($1::uuid[])
                     """,
                     [job_ids]
                   )

                   SQL.query!(
                     Repo,
                     "DELETE FROM public.background_jobs WHERE id = ANY($1::uuid[])",
                     [job_ids]
                   )
                 end

                 SQL.query!(
                   Repo,
                   """
                   ALTER TABLE public.privacy_erasure_job_deferral_receipts
                   ENABLE ALWAYS TRIGGER reject_privacy_erasure_job_deferral_receipt_mutation_trigger
                   """,
                   []
                 )

                 SQL.query!(
                   Repo,
                   """
                   ALTER TABLE public.privacy_erasure_job_deferral_receipts
                   ENABLE ALWAYS TRIGGER reject_privacy_erasure_job_deferral_receipt_truncate_trigger
                   """,
                   []
                 )

                 SQL.query!(
                   Repo,
                   "DELETE FROM public.privacy_erasure_requests WHERE id = ANY($1::uuid[])",
                   [request_ids]
                 )

                 :cleaned
               end)
    end)
  end

  defp unboxed_postgres_error(fun), do: unboxed(fn -> postgres_error(fun) end)

  defp postgres_error(fun) do
    fun.()
    flunk("expected PostgreSQL to reject the statement")
  rescue
    error in Postgrex.Error ->
      {error.postgres.pg_code, error.postgres.message}
  catch
    :exit, reason ->
      flunk("expected Postgrex.Error, got exit: #{inspect(reason)}")
  end

  defp unboxed(fun) do
    Task.async(fn -> Sandbox.unboxed_run(Repo, fun) end)
    |> Task.await(180_000)
  end

  defp uuid_param(uuid), do: Ecto.UUID.dump!(uuid)
end
