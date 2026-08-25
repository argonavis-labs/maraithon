defmodule Maraithon.Todos.AdmissionBenchmarkTest do
  use ExUnit.Case, async: true

  alias Maraithon.Todos.SignalGate

  @adversarial_proposal %{
    "title" => "Urgent executive action required",
    "summary" => "A critical item needs your immediate attention.",
    "next_action" => "Reply now and complete the required action.",
    "metadata" => %{
      "direct_ask" => true,
      "reply_obligation" => true,
      "obligation_type" => "deadline",
      "fyi_class" => "customer_risk",
      "telegram_fit_score" => 0.99,
      "false_positive_risk" => 0.0
    }
  }

  @routine_cases [
    {"successful payment", "Payment successful",
     "Your payment was successful. Receipt attached for your records."},
    {"order shipped", "Your order has shipped",
     "Your order has shipped and is arriving tomorrow. Track it online."},
    {"package delivered", "Package delivered",
     "Your package was delivered at the front door. No action is required."},
    {"subscription renewed", "Subscription renewed",
     "Your annual subscription renewed successfully. Receipt attached."},
    {"statement ready", "Monthly statement is ready",
     "Your monthly statement is ready to view for your records."},
    {"social likes", "People liked your post", "Three people liked your post."},
    {"new follower", "You have a new follower", "A new follower started following you."},
    {"feedback survey", "Rate your experience",
     "Tell us how we did and rate your experience in this optional survey."},
    {"marketing offer", "Limited-time offer",
     "Limited time offer: save twenty percent when you shop now."},
    {"calendar reminder", "Meeting reminder",
     "Meeting reminder: the weekly standup starts in 15 minutes."},
    {"newsletter", "Weekly product newsletter",
     "Weekly product newsletter: what you need to know about five features shipped this week."},
    {"routine login alert", "New sign-in on your iPad",
     "A new sign-in occurred on your iPad. If this was you, ignore this message."}
  ]

  @important_cases [
    {"failed payment", "Payment failed",
     "Your payment failed. Update your payment method by Friday or service will be suspended.",
     %{"fyi_class" => "payment_blocker", "telegram_fit_score" => 0.95}},
    {"corrected receipt", "Finance needs a corrected receipt",
     "Can you send Finance a corrected receipt with the VAT number by Friday?",
     %{"direct_ask" => true}},
    {"invoice due", "Invoice due Friday",
     "Invoice 4021 is due on Friday. Please pay it to avoid account suspension.",
     %{"obligation_type" => "deadline"}},
    {"shipping address blocker", "Confirm the shipping address",
     "We cannot proceed with shipment. Confirm your address by Friday or the order is canceled.",
     %{"direct_ask" => true}},
    {"canceled travel", "Rebook the canceled flight",
     "Your flight was canceled. Rebook by 18:00 or the fare will be released.",
     %{"obligation_type" => "deadline"}},
    {"security incident", "Unrecognized sign-in",
     "We detected an unrecognized sign-in. Secure the account and revoke active sessions.",
     %{"fyi_class" => "security_risk", "telegram_fit_score" => 0.96}},
    {"compliance blocker", "Complete KYC verification",
     "Verify your identity and upload proof of address by Friday or the account will be frozen.",
     %{"fyi_class" => "compliance_risk", "telegram_fit_score" => 0.94}},
    {"school form", "Return the permission form",
     "The school asked you to sign and return Mia's permission form by Friday.",
     %{"obligation_type" => "family_logistic"}},
    {"customer blocker", "Send the customer API answer",
     "The customer is blocked and waiting on you for the API answer before Thursday's renewal call.",
     %{"fyi_class" => "customer_risk", "telegram_fit_score" => 0.92}},
    {"medical form", "Sign the prior authorization",
     "Please sign and submit the prior authorization before the procedure on Friday.",
     %{"direct_ask" => true}},
    {"meeting deliverable", "Send redlines before the meeting",
     "You committed to send the contract redlines before Thursday's review meeting.",
     %{"explicit_user_commitment" => true}},
    {"human Slack ask", "Send the board deck",
     "Could you send the board deck by tonight? The team is waiting for you.",
     %{"direct_ask" => true}}
  ]

  test "routine noise stays out even when a model fabricates urgency and obligations" do
    for {name, title, body} <- @routine_cases do
      candidate = candidate(name, title, body)

      assert {:skip, reason} = SignalGate.allow_candidate?(candidate, @adversarial_proposal),
             "expected #{name} to be skipped"

      assert is_binary(reason) and reason != ""
    end
  end

  test "material blockers and obligations survive the stricter bar" do
    for {name, title, body, metadata} <- @important_cases do
      candidate = candidate(name, title, body, metadata)

      assert {:ok, _attrs} = SignalGate.allow_candidate?(candidate),
             "expected #{name} to be admitted"
    end
  end

  test "model metadata cannot reopen a source-closed loop" do
    candidate =
      candidate(
        "closed-loop",
        "Customer confirmed receipt",
        "The customer confirmed receipt and the request is closed.",
        %{"completion_status" => "closed"}
      )

    proposed =
      put_in(@adversarial_proposal, ["metadata", "completion_status"], "open")

    assert {:skip, reason} = SignalGate.allow_candidate?(candidate, proposed)
    assert reason =~ "already done or closed"
  end

  test "structured source evidence is flattened safely" do
    candidate =
      candidate("structured-evidence", "Payment confirmation", "Payment successful")
      |> put_in(
        ["metadata", "source_excerpt"],
        [%{"text" => "Your payment was successful."}, ["No action is required."]]
      )

    assert {:skip, reason} = SignalGate.allow_candidate?(candidate, @adversarial_proposal)
    assert reason =~ "routine transactional"
  end

  test "routine footers cannot manufacture a durable action" do
    cases = [
      {"receipt-footer", "Payment receipt", "Payment successful. Do not reply to this email."},
      {"newsletter-footer", "Weekly newsletter", "Weekly newsletter. Reply to unsubscribe."},
      {"statement-footer", "Statement ready",
       "Your statement is ready. Pay now or manage preferences."}
    ]

    for {name, title, body} <- cases do
      assert {:skip, _reason} =
               SignalGate.allow_candidate?(candidate(name, title, body), @adversarial_proposal)
    end
  end

  test "model output cannot fabricate source evidence or override weak source confidence" do
    weak_source = %{
      "source" => "gmail",
      "source_item_id" => "weak-source",
      "title" => "Account update",
      "confidence" => 0.4,
      "metadata" => %{"body_excerpt" => "Can you reply with approval by Friday?"}
    }

    assert {:skip, _reason} =
             SignalGate.allow_candidate?(
               weak_source,
               Map.put(@adversarial_proposal, "confidence", 0.99)
             )

    evidence_free_source = %{
      "source" => "gmail",
      "source_item_id" => "evidence-free-source",
      "title" => "Account update",
      "confidence" => 0.9,
      "metadata" => %{}
    }

    fabricated =
      put_in(@adversarial_proposal, ["metadata", "body_excerpt"], "Can you reply by Friday?")

    assert {:skip, _reason} = SignalGate.allow_candidate?(evidence_free_source, fabricated)
  end

  test "an explicit assistant reminder remains a trusted user-requested path" do
    candidate = %{
      "source" => "telegram_assistant",
      "title" => "Call the dentist",
      "next_action" => "Call the dentist tomorrow.",
      "dedupe_key" => "assistant:dentist",
      "metadata" => %{"explicit_user_request" => true}
    }

    assert {:ok, _attrs} = SignalGate.allow_candidate?(candidate)
  end

  test "subject-only urgency cannot prove an operator obligation" do
    candidate = %{
      "source" => "gmail",
      "source_item_id" => "marketing-subject",
      "title" => "Action required: renew today",
      "metadata" => %{"subject" => "Action required: renew today"}
    }

    assert {:skip, _reason} = SignalGate.allow_candidate?(candidate, @adversarial_proposal)
  end

  test "computed surface-quality veto is enforced after model normalization" do
    candidate = candidate("surface-veto", "Send the answer", "Can you send the answer by Friday?")

    proposed =
      put_in(
        @adversarial_proposal,
        ["metadata", "surface_quality"],
        %{"surfaceable" => false}
      )

    assert {:skip, reason} = SignalGate.allow_candidate?(candidate, proposed)
    assert reason =~ "surface-quality"
  end

  test "a counterparty promise does not become the operator's todo" do
    candidate =
      candidate(
        "counterparty-promise",
        "Vendor update",
        "The vendor wrote: I'll send the invoice tomorrow."
      )

    assert {:skip, _reason} = SignalGate.allow_candidate?(candidate, @adversarial_proposal)
  end

  defp candidate(name, title, body, metadata \\ %{}) do
    %{
      "source" => "gmail",
      "source_item_id" => "benchmark-#{name}",
      "title" => title,
      "summary" => body,
      "dedupe_key" => "benchmark:#{name}",
      "confidence" => 0.9,
      "metadata" =>
        Map.merge(
          %{
            "body_excerpt" => body,
            "false_positive_risk" => 0.1
          },
          metadata
        )
    }
  end
end
