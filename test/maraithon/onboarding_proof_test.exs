defmodule Maraithon.OnboardingProofTest do
  use ExUnit.Case, async: true

  alias Maraithon.OnboardingProof

  test "frames onboarding preview value for executives and operators" do
    parent = self()

    llm_complete = fn prompt ->
      send(parent, {:onboarding_prompt, prompt})
      {:ok, "[]"}
    end

    assert {:ok, _preview} =
             OnboardingProof.preview("user@example.com",
               sources: [
                 %{
                   "source" => "gmail",
                   "label" => "Gmail",
                   "account_label" => "exec@example.com",
                   "items" => %{
                     "inbox" => [
                       %{
                         "subject" => "Deck follow-up",
                         "snippet" => "Can you send the deck today?"
                       }
                     ]
                   }
                 }
               ],
               llm_complete: llm_complete
             )

    assert_receive {:onboarding_prompt, prompt}
    assert prompt =~ "valuable to an executive or operator"
    refute prompt =~ "valuable to a founder or operator"
  end

  test "normalizes up to three preview items from the llm response" do
    sources = [
      %{
        "source" => "gmail",
        "label" => "Gmail",
        "account_label" => "kent@voteagora.com",
        "items" => %{
          "inbox" => [
            %{"subject" => "Deck follow-up", "snippet" => "Can you send the deck today?"}
          ],
          "sent" => [%{"subject" => "Re: Deck", "snippet" => "I'll send it this afternoon."}]
        }
      },
      %{
        "source" => "slack",
        "label" => "Slack",
        "account_label" => "Agora",
        "items" => [%{"text" => "I’ll send owners and next steps after the planning meeting."}]
      }
    ]

    llm_complete = fn _prompt ->
      {:ok,
       Jason.encode!([
         %{
           "title" => "You promised the deck to Sarah",
           "summary" =>
             "A real email thread shows a promised deck with no visible follow-through yet.",
           "rationale" =>
             "This is exactly the kind of founder promise that slips unless someone is watching sent and inbox together.",
           "recommended_action" =>
             "Watch the thread, verify delivery, and nudge if nothing is sent by end of day.",
           "source" => "gmail",
           "account_label" => "kent@voteagora.com",
           "suggested_behavior" => "founder_followthrough_agent",
           "confidence" => 0.92
         },
         %{
           "title" => "Planning meeting likely created follow-up work",
           "summary" => "Slack shows a promise to send owners and next steps after planning.",
           "rationale" =>
             "Planning meetings are high-retention moments because users feel the pain immediately when owners never get circulated.",
           "recommended_action" =>
             "Track the promise and check whether the thread gets a real update.",
           "source" => "slack",
           "account_label" => "Agora",
           "suggested_behavior" => "slack_followthrough_agent",
           "confidence" => 0.84
         },
         %{
           "title" => "Inbox unanswered-reply preview",
           "summary" => "The inbox sample contains a direct ask that looks unresolved.",
           "rationale" =>
             "Unanswered replies are a reliable proof-of-value wedge because users instantly recognize the missed loop.",
           "recommended_action" =>
             "Flag the thread and escalate only if no response is sent after the promised window.",
           "source" => "gmail",
           "account_label" => "kent@voteagora.com",
           "suggested_behavior" => "inbox_calendar_advisor",
           "confidence" => 0.8
         },
         %{
           "title" => "Should be dropped because only three items are allowed",
           "summary" => "This item should not survive normalization.",
           "rationale" => "The UI intentionally limits the preview to the top three catches.",
           "recommended_action" => "Drop it.",
           "source" => "gmail",
           "account_label" => "kent@voteagora.com",
           "suggested_behavior" => "founder_followthrough_agent",
           "confidence" => 0.78
         }
       ])}
    end

    assert {:ok, preview} =
             OnboardingProof.preview("user@example.com",
               sources: sources,
               llm_complete: llm_complete
             )

    assert length(preview.items) == 3
    assert Enum.at(preview.items, 0).title == "You promised the deck to Sarah"
    assert Enum.at(preview.items, 1).source == "slack"
    assert Enum.at(preview.items, 2).suggested_behavior == "inbox_calendar_advisor"
    assert preview.sources == ["Gmail · kent@voteagora.com", "Slack · Agora"]
  end

  test "keeps onboarding preview copy product-facing while retaining internal confidence" do
    sources = [
      %{
        "source" => "gmail",
        "label" => "Gmail",
        "account_label" => "kent@voteagora.com",
        "items" => %{
          "inbox" => [
            %{"subject" => "Deck follow-up", "snippet" => "Can you send the deck today?"}
          ]
        }
      }
    ]

    llm_complete = fn _prompt ->
      {:ok,
       Jason.encode!([
         %{
           "title" => "Deck follow-up for Sarah",
           "summary" => "The Sarah thread still needs a promised deck.",
           "rationale" =>
             "90% confidence from the model score.\nSarah asked for the deck and the sample does not show delivery.",
           "recommended_action" =>
             "Reasoning: this is high signal.\nCheck the thread and send the deck if it is still missing.",
           "source" => "gmail",
           "account_label" => "kent@voteagora.com",
           "suggested_behavior" => "founder_followthrough_agent",
           "confidence" => 0.97
         }
       ])}
    end

    assert {:ok, preview} =
             OnboardingProof.preview("user@example.com",
               sources: sources,
               llm_complete: llm_complete
             )

    [item] = preview.items
    assert item.confidence == 0.97
    assert item.rationale == "Sarah asked for the deck and the sample does not show delivery."
    assert item.recommended_action == "Check the thread and send the deck if it is still missing."

    visible_copy =
      Enum.join([item.title, item.summary, item.rationale, item.recommended_action], " ")

    refute visible_copy =~ "90%"
    refute String.contains?(String.downcase(visible_copy), "confidence")
    refute String.contains?(String.downcase(visible_copy), "model")
    refute String.contains?(String.downcase(visible_copy), "score")
    refute String.contains?(String.downcase(visible_copy), "reasoning")
  end

  test "returns an empty preview when no connected data is available" do
    assert {:ok, preview} = OnboardingProof.preview("user@example.com", sources: [])
    assert preview.items == []
    assert preview.sources == []
  end
end
