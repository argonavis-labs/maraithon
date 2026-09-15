defmodule Maraithon.Delegations.EvaluationTest do
  use ExUnit.Case, async: true
  alias Maraithon.Delegations.{Evaluation, Scheduling}

  test "evening and late-day evals wait for a full working hour without changing preferences" do
    prefs = Maraithon.Delegations.Preferences.defaults()

    for now <- [~U[2026-09-15 21:30:00Z], ~U[2026-09-15 23:00:00Z]] do
      assert {:ok, ~U[2026-09-16 12:00:00Z], ~U[2026-09-16 13:00:00Z]} =
               Evaluation.window(now, prefs)
    end

    assert {:ok, ~U[2026-09-15 20:00:00Z], ~U[2026-09-15 21:00:00Z]} =
             Evaluation.window(~U[2026-09-15 20:00:00Z], prefs)

    assert {:ok, ~U[2026-09-15 21:00:00Z], ~U[2026-09-15 22:00:00Z]} =
             Evaluation.window(~U[2026-09-15 21:00:00Z], prefs)

    assert {:ok, ~U[2026-11-02 13:00:00Z], ~U[2026-11-02 14:00:00Z]} =
             Evaluation.window(~U[2026-10-30 21:30:00Z], prefs)

    assert {:error, :eval_work_window_too_short} =
             Evaluation.window(~U[2026-09-15 23:00:00Z], Map.put(prefs, "work_end", "08:30"))

    assert {:ok, ~U[2026-09-16 12:00:00Z], ~U[2026-09-16 13:00:00Z]} =
             Evaluation.window(~U[2026-09-16 03:30:00Z], Map.put(prefs, "work_end", "23:59"))
  end

  test "the live fixture will not accept wrong-week, UTC-labelled or assistant-authored offers" do
    requested = ~U[2026-09-15 16:00:00Z]
    scenario = %{"expect" => %{"requested_week_offset" => 1}}

    slots =
      for hour <- [13, 14, 15],
          do: %{
            "start_at" => "2026-09-21T#{hour}:00:00Z",
            "end_at" => "2026-09-21T#{hour}:30:00Z",
            "timezone" => "America/Toronto"
          }

    body = Enum.map_join(slots, "\n", &Scheduling.slot_label/1)
    assert :ok = Evaluation.verify_offer(scenario, slots, body, requested)

    assert :ok =
             Evaluation.verify_offer(
               scenario,
               slots,
               "I am Kent's assistant.\n" <> body,
               requested,
               "as_assistant"
             )

    for bad_body <- ["I am Kent's assistant.\n" <> body, "2026-09-21T13:00:00Z America/Toronto"] do
      assert {:error, :received_offer_not_proven} =
               Evaluation.verify_offer(scenario, slots, bad_body, requested)
    end

    tomorrow =
      Enum.map(slots, fn slot ->
        Map.new(slot, fn {key, value} ->
          {key, String.replace(value, "2026-09-21", "2026-09-16")}
        end)
      end)

    body = Enum.map_join(tomorrow, "\n", &Scheduling.slot_label/1)

    assert {:error, :received_offer_not_proven} =
             Evaluation.verify_offer(scenario, tomorrow, body, requested)
  end
end
