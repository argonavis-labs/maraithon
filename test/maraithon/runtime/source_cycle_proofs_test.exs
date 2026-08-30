defmodule Maraithon.Runtime.SourceCycleProofsTest do
  use Maraithon.DataCase, async: false

  alias Maraithon.Accounts
  alias Maraithon.ConnectedAccounts
  alias Maraithon.Repo
  alias Maraithon.Runtime.BackgroundJobs
  alias Maraithon.Runtime.SourceCycle
  alias Maraithon.Runtime.SourceCycleItem
  alias Maraithon.Runtime.SourceCycleProofs

  test "acquisition-only empty cycles tile a window without inventing fanout jobs" do
    fixture = cycle_fixture("empty", "discovery", fanout?: false)

    assert {:ok, cycle} = SourceCycleProofs.create_cycle(fixture.attrs, [], [])
    assert cycle.reason_job_ids == []
    assert cycle.reason_job_count == 0
    assert is_nil(cycle.finalizer_job_id)
    assert cycle.source_item_count == 0
    assert byte_size(cycle.source_manifest_digest) == 32

    assert {:ok,
            %{
              source_items: 0,
              source_decisions: 0,
              todo_snapshots: 0,
              todo_closures: 0,
              expected_jobs: 1
            }} = SourceCycleProofs.verify_complete(cycle)
  end

  test "discovery proof stays incomplete until every immutable item has one exact decision" do
    fixture = cycle_fixture("discovery", "discovery")
    source_ref_digest = digest("private-provider-ref")

    source_items = [
      %{
        source_ref_digest: source_ref_digest,
        source_identity_digest: digest("provider-identity"),
        source_revision_digest: digest("provider-revision"),
        provider_occurred_at: ~U[2026-08-30 12:00:00.000000Z]
      }
    ]

    assert {:ok, cycle} = SourceCycleProofs.create_cycle(fixture.attrs, source_items, [])
    assert {:error, :source_cycle_incomplete} = SourceCycleProofs.verify_complete(cycle)

    assert %SourceCycleItem{} =
             stored_item =
             Repo.get_by!(SourceCycleItem,
               cycle_id: cycle.id,
               source_ref_digest: source_ref_digest
             )

    refute Map.has_key?(Map.from_struct(stored_item), :source_ref)

    decision = %{
      source_ref_digest: source_ref_digest,
      reason_job_id: fixture.reason_job.id,
      action: "skip",
      evaluator: "model",
      reason_code: "not_actionable",
      evidence_digest: digest("bounded-evidence")
    }

    assert {:ok, [:inserted]} = SourceCycleProofs.record_source_decisions(cycle, [decision])
    assert {:ok, [:duplicate]} = SourceCycleProofs.record_source_decisions(cycle, [decision])

    assert {:error, :source_cycle_receipt_idempotency_conflict} =
             SourceCycleProofs.record_source_decisions(cycle, [
               %{decision | reason_code: "different_decision"}
             ])

    assert {:ok, %{source_items: 1, source_decisions: 1, expected_jobs: 3}} =
             SourceCycleProofs.verify_complete(cycle)
  end

  test "closure proof binds every receipt to the exact snapshotted todo state" do
    fixture = cycle_fixture("closure", "closure")
    todo_id = Ecto.UUID.generate()
    before_digest = digest("open-todo-version")

    snapshots = [
      %{
        todo_id: todo_id,
        eligible_status: "open",
        todo_state_digest: before_digest,
        todo_updated_at: ~U[2026-08-30 12:01:00.000000Z]
      }
    ]

    assert {:ok, cycle} = SourceCycleProofs.create_cycle(fixture.attrs, [], snapshots)
    assert {:error, :source_cycle_incomplete} = SourceCycleProofs.verify_complete(cycle)

    closure = %{
      todo_id: todo_id,
      reason_job_id: fixture.reason_job.id,
      todo_before_digest: before_digest,
      todo_after_digest: before_digest,
      outcome: "still_open",
      evaluator: "deterministic",
      reason_code: "no_completion_evidence"
    }

    assert {:ok, [:inserted]} = SourceCycleProofs.record_todo_closures(cycle, [closure])
    assert {:ok, [:duplicate]} = SourceCycleProofs.record_todo_closures(cycle, [closure])

    assert {:ok, %{todo_snapshots: 1, todo_closures: 1, expected_jobs: 3}} =
             SourceCycleProofs.verify_complete(cycle)

    assert {:error, %Ecto.Changeset{}} =
             SourceCycleProofs.record_todo_closures(cycle, [
               %{
                 closure
                 | todo_id: Ecto.UUID.generate(),
                   todo_before_digest: digest("other-state"),
                   outcome: "completed"
               }
             ])
  end

  test "schema rejects a finalizer without reason jobs and mutable cycle updates" do
    fixture = cycle_fixture("shape", "discovery")

    attrs =
      Map.merge(fixture.attrs, %{
        reason_job_ids: [],
        finalizer_job_id: fixture.finalizer_job.id,
        reason_job_count: 0,
        cycle_key: digest("cycle"),
        job_manifest_digest: digest("jobs"),
        source_item_count: 0,
        source_manifest_digest: digest("sources"),
        todo_snapshot_count: 0,
        todo_snapshot_manifest_digest: digest("todos"),
        captured_at: ~U[2026-08-30 12:00:00.000000Z],
        sealed_at: ~U[2026-08-30 12:00:00.000000Z],
        inserted_at: ~U[2026-08-30 12:00:00.000000Z]
      })

    refute SourceCycle.changeset(%SourceCycle{}, attrs).valid?

    empty_fixture = cycle_fixture("immutable", "discovery", fanout?: false)
    assert {:ok, cycle} = SourceCycleProofs.create_cycle(empty_fixture.attrs, [], [])

    assert_raise Postgrex.Error, fn ->
      Repo.update_all(from(row in SourceCycle, where: row.id == ^cycle.id),
        set: [upper_cursor: "changed"]
      )
    end
  end

  defp cycle_fixture(suffix, role, opts \\ []) do
    unique = System.unique_integer([:positive])
    user_id = "source-cycle-#{suffix}-#{unique}@example.com"
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

    {:ok, account} =
      ConnectedAccounts.upsert_manual(user_id, "google:#{user_id}", %{
        metadata: %{"account_email" => user_id, "services" => ["gmail"]}
      })

    prefix = "source-cycle-proof:#{suffix}:#{unique}"
    fanout? = Keyword.get(opts, :fanout?, true)

    {acquisition_type, reason_type, finalizer_type} =
      case role do
        "discovery" ->
          {"runtime_partition:source_account_discovery",
           "runtime_partition:source_account_discovery_reason",
           "runtime_partition:source_account_discovery_finalize"}

        "closure" ->
          {"runtime_partition:source_account_closure_acquire",
           "runtime_partition:source_account_closure_reason",
           "runtime_partition:source_account_closure_finalize"}
      end

    acquisition_job = enqueue_job(acquisition_type, user_id, "#{prefix}:acquisition")

    {reason_job, finalizer_job, reason_job_ids} =
      if fanout? do
        reason_job = enqueue_job(reason_type, user_id, "#{prefix}:reason")
        finalizer_job = enqueue_job(finalizer_type, user_id, "#{prefix}:finalizer")
        {reason_job, finalizer_job, [reason_job.id]}
      else
        {nil, nil, []}
      end

    %{
      reason_job: reason_job,
      finalizer_job: finalizer_job,
      attrs: %{
        user_id: user_id,
        connected_account_id: account.id,
        provider: account.provider,
        role: role,
        cursor_kind: "#{role}_watermark",
        lower_cursor: "100",
        upper_cursor: "200",
        boundary: "lower_exclusive_upper_inclusive",
        acquisition_job_id: acquisition_job.id,
        reason_job_ids: reason_job_ids,
        finalizer_job_id: finalizer_job && finalizer_job.id
      }
    }
  end

  defp enqueue_job(job_type, user_id, dedupe_key) do
    assert {:ok, job} =
             BackgroundJobs.enqueue(job_type, %{
               user_id: user_id,
               queue: "runtime_model_user",
               dedupe_key: dedupe_key,
               scheduled_at: DateTime.utc_now(),
               payload: %{}
             })

    job
  end

  defp digest(value), do: :crypto.hash(:sha256, value)
end
