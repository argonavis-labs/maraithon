defmodule Maraithon.TelegramAssistant.ProactiveQueueTest do
  use Maraithon.DataCase, async: true

  alias Maraithon.Accounts
  alias Maraithon.Push.Devices
  alias Maraithon.Repo
  alias Maraithon.TelegramAssistant.ProactiveCandidate
  alias Maraithon.TelegramAssistant.ProactiveQueue

  setup do
    user_id = "proactive-queue-#{System.unique_integer([:positive])}@example.com"
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

    %{user_id: user_id}
  end

  test "enqueue stores a normalized pending candidate", %{user_id: user_id} do
    assert {:ok, %ProactiveCandidate{} = candidate} =
             ProactiveQueue.enqueue(
               candidate_attrs(user_id, %{
                 telegram_opts: [parse_mode: "HTML"],
                 structured_data: %{message_class: "assistant_push"},
                 urgency: "0.84"
               })
             )

    assert candidate.status == "pending"
    assert candidate.telegram_opts == %{"parse_mode" => "HTML"}
    assert candidate.structured_data == %{"message_class" => "assistant_push"}
    assert candidate.urgency == 0.84
    assert DateTime.compare(candidate.expires_at, DateTime.utc_now()) == :gt
  end

  test "enqueue returns the existing live row for duplicate dedupe keys", %{user_id: user_id} do
    attrs = candidate_attrs(user_id, %{dedupe_key: "live:duplicate"})

    assert {:ok, first} = ProactiveQueue.enqueue(attrs)

    assert {:ok, second} =
             ProactiveQueue.enqueue(%{
               attrs
               | body: "new body that should not overwrite the pending row"
             })

    assert second.id == first.id
    assert second.body == first.body
  end

  test "held rows remain live dedupe blockers", %{user_id: user_id} do
    attrs = candidate_attrs(user_id, %{dedupe_key: "held:duplicate"})

    assert {:ok, first} = ProactiveQueue.enqueue(attrs)
    assert {:ok, held} = ProactiveQueue.mark_held(first)

    assert {:ok, duplicate} =
             ProactiveQueue.enqueue(%{attrs | body: "must not create a second held row"})

    assert duplicate.id == held.id
    assert duplicate.status == "held"
    assert duplicate.body == held.body
  end

  test "delivery-unknown quarantines are never folded into a later held brief", %{
    user_id: user_id
  } do
    assert {:ok, candidate} =
             ProactiveQueue.enqueue(
               candidate_attrs(user_id, %{dedupe_key: "held:delivery-unknown"})
             )

    candidate =
      candidate
      |> Ecto.Changeset.change(status: "held", plan_reason: "delivery_unknown")
      |> Repo.update!()

    refute candidate.id in (ProactiveQueue.held_interruptions_for_prompt(user_id)
                            |> Enum.map(& &1["id"]))

    stale_at = DateTime.utc_now() |> DateTime.add(-8 * 24 * 60 * 60, :second)

    from(row in ProactiveCandidate, where: row.id == ^candidate.id)
    |> Repo.update_all(set: [updated_at: stale_at])

    assert ProactiveQueue.expire_stale_held(DateTime.utc_now(), 1) == []

    assert {:error, :not_resolvable} =
             ProactiveQueue.mark_resolvable_held_delivered(candidate.id)

    assert Repo.get!(ProactiveCandidate, candidate.id).status == "held"
  end

  test "enqueue allows a reused dedupe key after the prior row is terminal", %{user_id: user_id} do
    attrs = candidate_attrs(user_id, %{dedupe_key: "terminal:duplicate"})

    assert {:ok, first} = ProactiveQueue.enqueue(attrs)
    assert {:ok, _delivered} = ProactiveQueue.mark_delivered(first)

    assert {:ok, second} =
             ProactiveQueue.enqueue(%{
               attrs
               | source_id: "source-reused",
                 body: "fresh body"
             })

    refute second.id == first.id
    assert second.body == "fresh body"
  end

  test "recovers stale planned rows without changing evidence age", %{user_id: user_id} do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    assert {:ok, candidate} =
             ProactiveQueue.enqueue(
               candidate_attrs(user_id, %{dedupe_key: "stale-planned-recovery"})
             )

    assert {:ok, planned} = ProactiveQueue.mark_planned(candidate, "hold", "Temporary plan")
    inserted_at = planned.inserted_at
    stale_at = DateTime.add(now, -16 * 60, :second)

    planned
    |> Ecto.Changeset.change(planned_at: stale_at, updated_at: stale_at)
    |> Repo.update!()

    assert ProactiveQueue.recover_stale_planned(now, 15) == 1

    recovered = Repo.get!(ProactiveCandidate, planned.id)
    assert recovered.status == "pending"
    assert recovered.disposition == nil
    assert recovered.plan_reason == nil
    assert recovered.planned_at == nil
    assert recovered.inserted_at == inserted_at
  end

  test "list_pending_for_user orders by urgency descending", %{user_id: user_id} do
    assert {:ok, low} = ProactiveQueue.enqueue(candidate_attrs(user_id, %{urgency: 0.2}))
    assert {:ok, high} = ProactiveQueue.enqueue(candidate_attrs(user_id, %{urgency: 0.9}))
    assert {:ok, middle} = ProactiveQueue.enqueue(candidate_attrs(user_id, %{urgency: 0.5}))

    assert Enum.map(ProactiveQueue.list_pending_for_user(user_id), & &1.id) == [
             high.id,
             middle.id,
             low.id
           ]
  end

  test "list_pending_for_user bounds each planning batch", %{user_id: user_id} do
    for index <- 1..30 do
      assert {:ok, _candidate} =
               ProactiveQueue.enqueue(
                 candidate_attrs(user_id, %{
                   urgency: index / 100,
                   dedupe_key: "bounded-candidate:#{index}"
                 })
               )
    end

    assert length(ProactiveQueue.list_pending_for_user(user_id)) == 30
    assert length(ProactiveQueue.list_pending_for_user(user_id, candidate_limit: 25)) == 25
    assert length(ProactiveQueue.list_pending_for_user(user_id, candidate_limit: 3)) == 3
  end

  test "required-brief share cannot crowd urgent ordinary work out of acquisition", %{
    user_id: user_id
  } do
    Enum.each(1..60, fn index ->
      assert {:ok, _brief} =
               ProactiveQueue.enqueue(
                 candidate_attrs(user_id, %{
                   source: "brief",
                   dedupe_key: "brief-share:#{index}",
                   urgency: 0.99
                 })
               )
    end)

    assert {:ok, urgent} =
             ProactiveQueue.enqueue(
               candidate_attrs(user_id, %{
                 dedupe_key: "brief-share:urgent-ordinary",
                 urgency: 1.0
               })
             )

    bounded = ProactiveQueue.list_pending_for_user(user_id, candidate_limit: 50)

    assert Enum.count(bounded, &(&1.source == "brief")) == 12
    assert Enum.any?(bounded, &(&1.id == urgent.id))
  end

  test "bounded pending windows reserve required rows and rotate old low-urgency work", %{
    user_id: user_id
  } do
    assert {:ok, old_low} =
             ProactiveQueue.enqueue(
               candidate_attrs(user_id, %{
                 dedupe_key: "fair-old-low",
                 urgency: 0.01
               })
             )

    high =
      Enum.map(1..30, fn index ->
        assert {:ok, candidate} =
                 ProactiveQueue.enqueue(
                   candidate_attrs(user_id, %{
                     dedupe_key: "fair-high:#{index}",
                     urgency: 0.69 + index / 100
                   })
                 )

        candidate
      end)

    assert {:ok, required_brief} =
             ProactiveQueue.enqueue(
               candidate_attrs(user_id, %{
                 source: "brief",
                 dedupe_key: "fair-required-brief",
                 urgency: 0.0
               })
             )

    bounded = ProactiveQueue.list_pending_for_user(user_id, candidate_limit: 25)
    bounded_ids = MapSet.new(bounded, & &1.id)

    assert length(bounded) == 25
    assert MapSet.member?(bounded_ids, old_low.id)
    assert MapSet.member?(bounded_ids, required_brief.id)
    assert MapSet.member?(bounded_ids, List.last(high).id)
  end

  test "bounded windows use ids to resolve exact priority timestamp ties", %{user_id: user_id} do
    tied_at = ~U[2026-08-08 00:00:00.000000Z]

    candidates =
      Enum.map(1..30, fn index ->
        assert {:ok, candidate} =
                 ProactiveQueue.enqueue(
                   candidate_attrs(user_id, %{
                     dedupe_key: "tied-window:#{index}",
                     urgency: 0.5
                   })
                 )

        candidate
        |> Ecto.Changeset.change(inserted_at: tied_at)
        |> Repo.update!()
      end)

    expected_ids = candidates |> Enum.map(& &1.id) |> Enum.sort() |> Enum.take(25)

    actual_ids =
      user_id
      |> ProactiveQueue.list_pending_for_user(candidate_limit: 25)
      |> Enum.map(& &1.id)

    assert actual_ids == expected_ids
  end

  test "device-less users cannot consume the deliverable due-user batch", %{user_id: user_id} do
    Enum.each(1..30, fn index ->
      other_user_id =
        "device-less-queue-#{index}-#{System.unique_integer([:positive])}@example.com"

      {:ok, _user} = Accounts.get_or_create_user_by_email(other_user_id)

      assert {:ok, _candidate} =
               ProactiveQueue.enqueue(
                 candidate_attrs(other_user_id, %{dedupe_key: "device-less:#{index}"})
               )
    end)

    assert {:ok, _candidate} =
             ProactiveQueue.enqueue(
               candidate_attrs(user_id, %{dedupe_key: "deliverable-after-backlog"})
             )

    assert {:ok, _device} =
             Devices.register(user_id, %{
               "device_token" => String.duplicate("a", 64),
               "environment" => "sandbox"
             })

    assert ProactiveQueue.pending_deliverable_user_ids(limit: 25) == [user_id]
  end

  test "planner rotation advances a constant-size cursor without rewriting pending rows", %{
    user_id: user_id
  } do
    assert {:ok, candidate} =
             ProactiveQueue.enqueue(
               candidate_attrs(user_id, %{dedupe_key: "cursor-without-row-rewrite"})
             )

    original_updated_at = candidate.updated_at
    attempted_at = DateTime.utc_now() |> DateTime.add(60, :second)

    assert {:ok, 1} = ProactiveQueue.rotate_pending_user(user_id, attempted_at)
    assert Repo.reload!(candidate).updated_at == original_updated_at

    assert %{last_attempted_at: persisted_at} =
             Repo.one!(
               from(cursor in "proactive_planner_user_cursors",
                 where: field(cursor, :user_id) == ^user_id,
                 select: %{last_attempted_at: field(cursor, :last_attempted_at)}
               )
             )

    assert NaiveDateTime.compare(persisted_at, DateTime.to_naive(attempted_at)) == :eq
  end

  test "pending_user_ids returns distinct pending users", %{user_id: first_user_id} do
    second_user_id = "proactive-queue-#{System.unique_integer([:positive])}@example.com"
    {:ok, _user} = Accounts.get_or_create_user_by_email(second_user_id)

    assert {:ok, _first} = ProactiveQueue.enqueue(candidate_attrs(first_user_id))
    assert {:ok, _duplicate_user} = ProactiveQueue.enqueue(candidate_attrs(first_user_id))
    assert {:ok, _second} = ProactiveQueue.enqueue(candidate_attrs(second_user_id))

    assert ProactiveQueue.pending_user_ids(limit: 10) |> Enum.sort() ==
             [first_user_id, second_user_id] |> Enum.sort()
  end

  test "status transitions preserve planning metadata", %{user_id: user_id} do
    assert {:ok, candidate} = ProactiveQueue.enqueue(candidate_attrs(user_id))

    assert {:ok, planned} =
             ProactiveQueue.mark_planned(candidate, "digest", "Batch this with related work.")

    assert planned.status == "planned"
    assert planned.disposition == "digest"
    assert planned.plan_reason == "Batch this with related work."
    assert %DateTime{} = planned.planned_at

    assert {:ok, delivered} = ProactiveQueue.mark_delivered(planned.id)
    assert delivered.status == "delivered"
    assert %DateTime{} = delivered.delivered_at

    assert {:ok, held} =
             user_id
             |> candidate_attrs()
             |> ProactiveQueue.enqueue()
             |> elem(1)
             |> ProactiveQueue.mark_held()

    assert held.status == "held"
  end

  test "expire_stale marks pending and planned stale rows expired", %{user_id: user_id} do
    now = DateTime.utc_now()
    stale_time = DateTime.add(now, -60, :second)

    assert {:ok, pending} =
             ProactiveQueue.enqueue(candidate_attrs(user_id, %{expires_at: stale_time}))

    assert {:ok, planned} =
             user_id
             |> candidate_attrs(%{expires_at: stale_time})
             |> ProactiveQueue.enqueue()
             |> elem(1)
             |> ProactiveQueue.mark_planned("hold", "Too old.")

    assert {:ok, fresh} =
             ProactiveQueue.enqueue(
               candidate_attrs(user_id, %{expires_at: DateTime.add(now, 60, :second)})
             )

    assert ProactiveQueue.expire_stale(now) == 2

    assert Repo.get!(ProactiveCandidate, pending.id).status == "expired"
    assert Repo.get!(ProactiveCandidate, planned.id).status == "expired"
    assert Repo.get!(ProactiveCandidate, fresh.id).status == "pending"
  end

  # SPEC 02 R7: held candidates expire by updated_at (age since held), never
  # by the stale pre-hold expires_at, and each expiry writes an audit fact.
  test "expire_stale_held/2 expires only stale held candidates and records the drop", %{
    user_id: user_id
  } do
    now = DateTime.utc_now()

    {:ok, stale} = ProactiveQueue.enqueue(candidate_attrs(user_id))
    {:ok, fresh} = ProactiveQueue.enqueue(candidate_attrs(user_id))
    {:ok, _} = ProactiveQueue.mark_held(stale)
    {:ok, _} = ProactiveQueue.mark_held(fresh)

    eight_days_ago = DateTime.add(now, -8 * 86_400, :second)

    {1, _} =
      ProactiveCandidate
      |> where([row], row.id == ^stale.id)
      |> Repo.update_all(set: [updated_at: eight_days_ago])

    expired = ProactiveQueue.expire_stale_held(now)

    assert [%{id: expired_id, user_id: ^user_id}] = expired
    assert expired_id == stale.id
    assert Repo.get!(ProactiveCandidate, stale.id).status == "expired"
    assert Repo.get!(ProactiveCandidate, fresh.id).status == "held"

    [entry] =
      Maraithon.ActionLedger.list_recent(user_id,
        event_type: "held_interruption_expired",
        limit: 5
      )

    assert entry.metadata["candidate_id"] == stale.id

    # Idempotent: a second sweep finds nothing (expired rows are terminal).
    assert ProactiveQueue.expire_stale_held(now) == []
  end

  # SPEC 02 R8: a CalendarCheckIn-recorded check-in brief carries
  # held_interruption_ids in metadata, and the existing generic
  # delivery-confirmation function flips those candidates to "delivered"
  # once the brief sends — no cadence-specific plumbing.
  test "check-in brief held_interruption_ids flip held candidates to delivered on send", %{
    user_id: user_id
  } do
    {:ok, agent} =
      Maraithon.Agents.create_agent(%{
        user_id: user_id,
        behavior: "prompt_agent",
        config: %{"name" => "check-in"}
      })

    {:ok, first} = ProactiveQueue.enqueue(candidate_attrs(user_id))
    {:ok, second} = ProactiveQueue.enqueue(candidate_attrs(user_id))
    {:ok, _} = ProactiveQueue.mark_held(first)
    {:ok, _} = ProactiveQueue.mark_held(second)

    held_ids =
      user_id
      |> ProactiveQueue.held_interruptions_for_prompt(limit: 25)
      |> Enum.map(&Map.fetch!(&1, "id"))

    assert Enum.sort(held_ids) == Enum.sort([first.id, second.id])

    {:ok, brief} =
      Maraithon.Briefs.record(user_id, agent.id, %{
        "cadence" => "check_in",
        "scheduled_for" => DateTime.to_iso8601(DateTime.utc_now()),
        "dedupe_key" => "check-in-held-drain-#{System.unique_integer([:positive])}",
        "status" => "pending",
        "title" => "Open afternoon",
        "summary" => "Quiet stretch after lunch.",
        "body" => "You have the afternoon open.",
        "metadata" => %{
          "origin_skill_id" => "calendar_check_in",
          "held_interruption_ids" => held_ids
        }
      })

    # The confirmed-delivery path (PushBroker.mark_held_interruptions_delivered/1,
    # called by both the legacy send path and DeliveryPlanner) is
    # cadence-agnostic: the metadata key is the entire wiring.
    :ok = Maraithon.TelegramAssistant.PushBroker.mark_held_interruptions_delivered(brief)

    assert Repo.get!(ProactiveCandidate, first.id).status == "delivered"
    assert Repo.get!(ProactiveCandidate, second.id).status == "delivered"
    assert ProactiveQueue.list_held_for_user(user_id) == []
  end

  test "one user-scoped planner lease blocks even a disjoint row claim", %{user_id: user_id} do
    {:ok, first} = ProactiveQueue.enqueue(candidate_attrs(user_id))
    {:ok, second} = ProactiveQueue.enqueue(candidate_attrs(user_id))

    assert {:ok, claim} = ProactiveQueue.claim_pending([first])
    assert claim.ids == MapSet.new([first.id])

    assert {:error, :user_claim_busy} = ProactiveQueue.claim_pending([second])

    assert ProactiveQueue.release_claim(claim.token) == 1
    assert Repo.get!(ProactiveCandidate, first.id).status == "pending"
    assert Repo.get!(ProactiveCandidate, second.id).status == "pending"
  end

  test "dispatch authorization remains rollback-compatible planned state", %{user_id: user_id} do
    {:ok, candidate} = ProactiveQueue.enqueue(candidate_attrs(user_id))
    assert {:ok, claim} = ProactiveQueue.claim_pending([candidate])

    assert {:ok, planned} =
             ProactiveQueue.finalize_claim(candidate, claim.token, "interrupt_now")

    assert planned.status == "planned"
    assert {:ok, authorized} = ProactiveQueue.authorize_dispatch(candidate, claim.token)
    assert authorized.status == "planned"

    assert {:ok, delivered} =
             ProactiveQueue.complete_claim(candidate, claim.token, "delivered")

    assert delivered.status == "delivered"

    assert {:error, :claim_lost} =
             ProactiveQueue.complete_claim(candidate, claim.token, "delivered")
  end

  test "rejects wide, deep, cumulative-large, and improper JSON before normalization", %{
    user_id: user_id
  } do
    wide = Map.new(1..3_000, &{"key-#{&1}", "value"})
    deep = Enum.reduce(1..20, %{"leaf" => true}, fn _, acc -> %{"nested" => acc} end)
    cumulative = Map.new(1..100, &{"key-#{&1}", String.duplicate("x", 4_000)})
    improper = [{"ok", true} | :improper]
    duplicate_pairs = List.duplicate({"same", String.duplicate("x", 4_000)}, 100)

    for value <- [wide, deep, cumulative] do
      assert {:error, :invalid_proactive_candidate} =
               ProactiveQueue.enqueue(candidate_attrs(user_id, %{structured_data: value}))
    end

    for value <- [improper, duplicate_pairs] do
      assert {:error, :invalid_proactive_candidate} =
               ProactiveQueue.enqueue(candidate_attrs(user_id, %{telegram_opts: value}))
    end

    assert {:ok, _candidate} =
             ProactiveQueue.enqueue(candidate_attrs(user_id, %{ignored_remote_blob: wide}))

    assert {:error, :invalid_proactive_candidate} =
             ProactiveQueue.enqueue(
               candidate_attrs(user_id, %{source_id: String.duplicate("x", 1_000_000)})
             )

    assert {:error, :invalid_proactive_candidate} =
             ProactiveQueue.enqueue(
               candidate_attrs(user_id, %{urgency: Integer.pow(10, 100_000)})
             )
  end

  defp candidate_attrs(user_id, overrides \\ %{}) do
    unique = System.unique_integer([:positive])

    Map.merge(
      %{
        user_id: user_id,
        source: "insight",
        source_id: "source-#{unique}",
        dedupe_key: "candidate:#{unique}",
        title: "Reply to customer escalation",
        body: "The customer escalation needs a same-day reply.",
        urgency: 0.7,
        why_now: "The thread is urgent and still open.",
        structured_data: %{"source" => "test"},
        telegram_opts: %{"parse_mode" => "HTML"}
      },
      overrides
    )
  end
end
