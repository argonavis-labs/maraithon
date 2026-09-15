defmodule Maraithon.Delegations.EvaluationTest do
  use ExUnit.Case, async: true
  alias Maraithon.Delegations.{Evaluation, Scheduling}

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
