defmodule Maraithon.TelegramAssistant.ProactiveQueueTest do
  use Maraithon.DataCase, async: true

  alias Maraithon.Accounts
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
