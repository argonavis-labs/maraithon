defmodule Maraithon.Delegations.PolicyTest do
  use ExUnit.Case, async: true
  alias Maraithon.Delegations.{Budget, Policy}

  setup do
    message = %{
      "message_id" => "aa11",
      "from" => "Kent <kent.fenwick@gmail.com>",
      "to" => "Kent <kent@runner.now>",
      "labels" => ["INBOX"],
      "text_body" => "The colour is indigo."
    }

    context = %{
      delegation: %{kind: "information", data: %{}},
      turn: %{source_revision: 0, wake_reason: "reply"},
      grant: %{
        data: %{
          "scope" => %{
            "identity" => %{"email" => "kent@runner.now"},
            "to" => ["kent.fenwick@gmail.com"],
            "cc" => []
          }
        }
      },
      run: %{prompt_snapshot: %{"sources" => %{"complete" => true, "messages" => [message]}}}
    }

    %{
      context: context,
      decision: %{
        "kind" => "send",
        "body" => "Got it. Indigo.",
        "reason" => "Confirm the answer",
        "evidence" => ["aa11"]
      }
    }
  end

  test "recipients, tools and other extra authority cannot be smuggled into a decision", c do
    for field <- ~w(to cc bcc from account_id tools attachments instruction) do
      assert {:error, :decision_out_of_scope} =
               Policy.validate(c.context, Map.put(c.decision, field, "other@example.invalid"))
    end

    assert {:ok, _} = Policy.validate(c.context, c.decision)
  end

  test "completion requires a counterparty source and independent outcome proof", c do
    decision = %{c.decision | "kind" => "complete"}
    assert {:ok, _} = Policy.validate(c.context, decision)

    refute Policy.approved?(decision, %{
             "allowed" => true,
             "outcome_proven" => false,
             "reason" => "Only a promise"
           })

    for changed <- [%{"from" => "kent@runner.now"}, %{"labels" => ["DRAFT"]}] do
      context =
        update_in(c.context, [:run, :prompt_snapshot, "sources", "messages"], fn [m] ->
          [Map.merge(m, changed)]
        end)

      assert {:error, :unverified_outcome} = Policy.validate(context, decision)
    end
  end

  test "invented evidence and incomplete sources cannot authorize a reply", c do
    assert {:error, :unverified_evidence} =
             Policy.validate(c.context, %{c.decision | "evidence" => ["fake"]})

    context = put_in(c.context, [:run, :prompt_snapshot, "sources", "complete"], false)
    assert {:error, :source_gap} = Policy.validate(context, c.decision)
  end

  test "as-user messages cannot introduce themselves as Kent's assistant", c do
    for intro <- ["I am Kent's assistant", "I'm your assistant", "As an AI assistant"] do
      assert {:error, :wrong_message_actor} =
               Policy.validate(c.context, %{c.decision | "body" => intro <> ", sharing times."})
    end

    assert {:ok, _} =
             Policy.validate(c.context, %{c.decision | "body" => "These times work for me."})
  end

  test "an offer must contain the exact local labels, not UTC marked Toronto", c do
    slot = %{
      "start_at" => "2026-09-16T16:15:00Z",
      "end_at" => "2026-09-16T16:45:00Z",
      "timezone" => "America/Toronto"
    }

    context = %{c.context | delegation: %{kind: "scheduling", data: %{}}}
    context = put_in(context, [:run, :prompt_snapshot, "scheduling"], %{"slots" => [slot]})

    decision =
      Map.merge(c.decision, %{
        "kind" => "propose_times",
        "slot_ids" => [Policy.slot_id(slot)],
        "body" => "2026-09-16T16:15:00Z to 2026-09-16T16:45:00Z America/Toronto"
      })

    assert {:error, :unverified_slot_wording} = Policy.validate(context, decision)
    label = Maraithon.Delegations.Scheduling.slot_label(slot)
    assert label =~ "12:15 PM"

    assert {:ok, _} =
             Policy.validate(context, %{decision | "body" => "Does this work?\n" <> label})
  end

  test "slot identity binds dates and timezone; booking cannot pick a new time", c do
    slot = %{
      "start_at" => "2026-09-16T14:00:00Z",
      "end_at" => "2026-09-16T14:30:00Z",
      "timezone" => "America/Toronto"
    }

    other = Map.put(slot, "start_at", "2026-09-16T15:00:00Z")
    refute Policy.slot_id(slot) == Policy.slot_id(other)
    context = %{c.context | delegation: %{kind: "scheduling", data: %{"offered_slots" => [slot]}}}

    decision =
      Map.merge(c.decision, %{"kind" => "book", "accepted_slot_id" => Policy.slot_id(slot)})

    assert {:ok, _} = Policy.validate(context, decision)

    assert {:error, :unoffered_slot} =
             Policy.validate(
               context,
               Map.put(decision, "accepted_slot_id", Policy.slot_id(other))
             )
  end

  test "the model receives only six recent messages, not months of mail", c do
    context =
      put_in(
        c.context,
        [:run, :prompt_snapshot, "sources", "messages"],
        for(n <- 1..100, do: %{"message_id" => to_string(n)})
      )

    assert Enum.map(Policy.context(context)["last_messages"], & &1["message_id"]) ==
             ~w(95 96 97 98 99 100)
  end

  test "model reservation uses a whole context and provider price ceilings" do
    endpoint = %{
      "tag" => "meta",
      "context_length" => 1_048_576,
      "supported_parameters" => ["max_tokens"],
      "pricing" => %{"prompt" => "0.0000001", "completion" => "0.0000002"}
    }

    assert {:ok, quote} = Budget.price([endpoint])
    assert quote["reserved_micro_usd"] == 105_268

    assert quote["provider"]["max_price"] == %{
             "prompt" => "0.1000000",
             "completion" => "0.2000000",
             "request" => "0"
           }

    assert quote["provider"]["only"] == ["meta"]
    refute quote["provider"]["allow_fallbacks"]

    for malformed <- [
          [],
          [%{}],
          [put_in(endpoint, ["pricing", "prompt"], "unknown")],
          [Map.put(endpoint, "supported_parameters", [])]
        ] do
      assert {:error, :model_price_unavailable} = Budget.price(malformed)
    end
  end

  test "normalizing a request preserves price ceilings and refuses a changed model" do
    provider = %{"max_price" => %{"prompt" => 0.1, "completion" => 0.2}}

    assert {:ok, params} =
             Maraithon.LLM.RequestBudget.validate(%{
               "model" => "meta/muse-spark-1.3-contributor",
               "provider" => provider,
               "messages" => [%{"role" => "user", "content" => "Eval"}]
             })

    assert params["provider"] == provider

    assert {:error, :model_changed} =
             Maraithon.LLM.UserModel.verify_expected(
               Map.put(params, "_expected_model", "different")
             )

    assert :ok =
             Maraithon.LLM.UserModel.verify_expected(
               Map.put(params, "_expected_model", params["model"])
             )
  end
end
