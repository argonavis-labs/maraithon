defmodule Maraithon.Crm.RelationshipDriftTest do
  use Maraithon.DataCase, async: true

  alias Maraithon.Accounts
  alias Maraithon.Crm
  alias Maraithon.Crm.Person
  alias Maraithon.Crm.ReconnectSuggestions
  alias Maraithon.Crm.RelationshipDrift
  alias Maraithon.Insights
  alias Maraithon.Insights.Insight

  defp user_id do
    id = "relationship-drift-#{System.unique_integer([:positive])}@example.com"
    {:ok, _user} = Accounts.get_or_create_user_by_email(id)
    id
  end

  defp set_signals(person, signals) do
    metadata = Map.put(person.metadata || %{}, "communication_signals", signals)
    {:ok, updated} = Crm.update_person(person, %{"metadata" => metadata})
    updated
  end

  # communication_score is system-owned (not in the changeset); seed it
  # directly so ReconnectSuggestions' candidate pool includes this person.
  defp seed_score(person, score) do
    Repo.update_all(
      from(p in Person, where: p.id == ^person.id),
      set: [communication_score: score]
    )

    %{person | communication_score: score}
  end

  defp overdue_person(uid, now, attrs \\ %{}) do
    {:ok, person} =
      Crm.create_person(
        uid,
        Map.merge(
          %{"first_name" => "Charlie", "display_name" => "Charlie Beckwith"},
          attrs
        )
      )

    person
    |> set_signals(%{
      "overdue" => true,
      "days_since_last" => 18,
      "cadence_days" => 7,
      "score" => 55,
      "computed_at" => DateTime.to_iso8601(now)
    })
    |> seed_score(55)
  end

  defp drift_insights(uid) do
    Insight
    |> where([i], i.user_id == ^uid and i.category == "relationship_drift")
    |> Repo.all()
  end

  test "an :overdue person with no prior insight produces exactly one candidate insight" do
    uid = user_id()
    now = DateTime.utc_now()
    person = overdue_person(uid, now)

    assert {:ok, %{recorded: 1}} = RelationshipDrift.run_for_user(uid, now: now)

    assert [insight] = drift_insights(uid)
    assert insight.category == "relationship_drift"
    assert insight.source == "relationship_drift"
    assert insight.status == "candidate"
    assert insight.dedupe_key == "relationship_drift:#{person.id}"
    assert insight.tracking_key == "relationship_drift:#{person.id}"
    # MemoryGate semantic recall matches on title/summary text, so the
    # person's name must be plain text in both (SPEC 03 R6).
    assert insight.title =~ "Charlie"
    assert insight.summary =~ "Charlie"
    assert insight.summary =~ "18 days"
    assert insight.confidence == 0.65
    assert insight.metadata["detector"] == "relationship_drift"
    assert insight.metadata["drift_category"] == "overdue"
    assert insight.metadata["person_id"] == person.id
    assert insight.metadata["person_name"] == "Charlie"
    assert insight.metadata["days_since_last"] == 18
    assert insight.metadata["cadence_days"] == 7
  end

  test "running twice for a still-qualifying person keeps exactly one row" do
    uid = user_id()
    now = DateTime.utc_now()
    _person = overdue_person(uid, now)

    assert {:ok, %{recorded: 1}} = RelationshipDrift.run_for_user(uid, now: now)
    assert {:ok, %{recorded: 1}} = RelationshipDrift.run_for_user(uid, now: now)

    assert [insight] = drift_insights(uid)
    assert insight.status == "candidate"
  end

  test "a dismissed insight inside the cooldown window is not reopened" do
    uid = user_id()
    now = DateTime.utc_now()
    _person = overdue_person(uid, now)

    assert {:ok, %{recorded: 1}} = RelationshipDrift.run_for_user(uid, now: now)
    assert [insight] = drift_insights(uid)
    {:ok, _dismissed} = Insights.dismiss(uid, insight.id)

    later = DateTime.add(now, 2, :day)
    assert {:ok, %{recorded: 0}} = RelationshipDrift.run_for_user(uid, now: later)

    assert [row] = drift_insights(uid)
    assert row.id == insight.id
    assert row.status == "dismissed"
  end

  test "a dismissed insight outside the cooldown window is reopened" do
    uid = user_id()
    now = DateTime.utc_now()
    _person = overdue_person(uid, now)

    assert {:ok, %{recorded: 1}} = RelationshipDrift.run_for_user(uid, now: now)
    assert [insight] = drift_insights(uid)
    {:ok, _dismissed} = Insights.dismiss(uid, insight.id)

    # Simulate the cooldown elapsing: in real time the next detection's
    # `now` would be 8+ days after both the dismissal and the original
    # detection, so backdate both timestamps together.
    stale = DateTime.add(now, -8, :day)

    Repo.update_all(
      from(i in Insight, where: i.id == ^insight.id),
      set: [updated_at: stale, source_occurred_at: stale]
    )

    assert {:ok, %{recorded: 1}} = RelationshipDrift.run_for_user(uid, now: now)

    assert [row] = drift_insights(uid)
    assert row.id == insight.id
    assert row.status == "candidate"
  end

  test "resumed contact resolves an open drift insight with auto_resolution metadata" do
    uid = user_id()
    now = DateTime.utc_now()
    person = overdue_person(uid, now)

    assert {:ok, %{recorded: 1}} = RelationshipDrift.run_for_user(uid, now: now)
    assert [insight] = drift_insights(uid)
    {:ok, _approved} = Insights.approve_candidate(uid, insight.id)

    # Contact resumed: the person no longer classifies as drifted.
    set_signals(person, %{
      "overdue" => false,
      "days_since_last" => 1,
      "cadence_days" => 7,
      "computed_at" => DateTime.to_iso8601(now)
    })

    later = DateTime.add(now, 1, :day)
    assert {:ok, %{recorded: 0, cleared: 1}} = RelationshipDrift.run_for_user(uid, now: later)

    assert [row] = drift_insights(uid)
    assert row.id == insight.id
    assert row.status == "acknowledged"
    assert %{"reason" => "contact_resumed"} = row.metadata["auto_resolution"]
  end

  test "resumed contact dismisses a never-reviewed candidate row" do
    uid = user_id()
    now = DateTime.utc_now()
    person = overdue_person(uid, now)

    assert {:ok, %{recorded: 1}} = RelationshipDrift.run_for_user(uid, now: now)
    assert [%{status: "candidate"} = insight] = drift_insights(uid)

    set_signals(person, %{
      "overdue" => false,
      "days_since_last" => 1,
      "cadence_days" => 7,
      "computed_at" => DateTime.to_iso8601(now)
    })

    later = DateTime.add(now, 1, :day)
    assert {:ok, %{recorded: 0, cleared: 1}} = RelationshipDrift.run_for_user(uid, now: later)

    assert [row] = drift_insights(uid)
    assert row.id == insight.id
    assert row.status == "dismissed"
  end

  test "a person overlapping the user's own handles is never built into a candidate" do
    uid = user_id()
    now = DateTime.utc_now()

    {:ok, person} =
      Crm.create_person(uid, %{
        "first_name" => "Kent",
        "display_name" => "Kent Self",
        "contact_details" => %{"emails" => [uid]},
        "relationship_strength" => 95
      })

    _person =
      set_signals(person, %{
        "days_since_last" => 30,
        "computed_at" => DateTime.to_iso8601(now)
      })

    # Guard against a vacuous pass: ReconnectSuggestions itself does classify
    # this self-person as :going_quiet on relationship_strength alone.
    assert Enum.any?(
             ReconnectSuggestions.suggestions(uid, limit: 50, goal_slots: 0, now: now),
             &(&1.person.id == person.id and &1.category == :going_quiet)
           )

    assert {:ok, %{recorded: 0}} = RelationshipDrift.run_for_user(uid, now: now)
    assert drift_insights(uid) == []
  end

  test "stale or missing communication_signals computed_at lowers confidence (R4)" do
    uid = user_id()
    now = DateTime.utc_now()

    {:ok, person} =
      Crm.create_person(uid, %{"first_name" => "Sam", "display_name" => "Sam Rivera"})

    # No computed_at at all: the day-count's freshness cannot be vouched for.
    person
    |> set_signals(%{"overdue" => true, "days_since_last" => 24, "cadence_days" => 7})
    |> seed_score(55)

    assert {:ok, %{recorded: 1}} = RelationshipDrift.run_for_user(uid, now: now)

    assert [insight] = drift_insights(uid)
    assert insight.confidence == 0.5
    # Copy still comes verbatim from ReconnectSuggestions (no re-derived math).
    assert insight.summary =~ "Sam"
  end
end
