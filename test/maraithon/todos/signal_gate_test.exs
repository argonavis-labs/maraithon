defmodule Maraithon.Todos.SignalGateTest do
  use ExUnit.Case, async: true

  alias Maraithon.Todos.SignalGate

  test "rejects a Brawl Stars login code even when the model promotes it" do
    candidate = %{
      "source" => "gmail",
      "title" => "Your Brawl Stars login code",
      "source_item_id" => "gmail-message-brawl-stars-code",
      "dedupe_key" => "gmail:brawl-stars-code",
      "metadata" => %{
        "body_excerpt" =>
          "Use 123456 to finish signing in to Brawl Stars. It expires in 15 minutes.",
        "fyi_class" => "security_risk",
        "telegram_fit_score" => 0.99
      }
    }

    proposed = %{
      "title" => "Unrecognized Brawl Stars sign-in needs remediation",
      "summary" => "A Brawl Stars sign-in is waiting for the delivered code.",
      "next_action" => "Enter the code to finish signing in.",
      "metadata" => %{"direct_ask" => true}
    }

    assert {:skip, reason} = SignalGate.allow_candidate?(candidate, proposed)
    assert reason =~ "one-time authentication credentials"
  end

  test "rejects a direct high-impact FYI verification code" do
    insight = %Maraithon.Insights.Insight{
      source: "gmail",
      category: "important_fyi",
      title: "Verification required",
      summary: "Your game verification code is 739201 and expires in ten minutes.",
      recommended_action: "Use the delivered code to finish signing in.",
      source_id: "gmail-message-direct-fyi-code",
      dedupe_key: "gmail:direct-fyi-code",
      metadata: %{
        "body_excerpt" => "Use verification code 739201 to log in. Do not share this code.",
        "fyi_class" => "account_risk",
        "telegram_fit_score" => 0.95
      }
    }

    assert {:skip, reason} = SignalGate.allow_insight?(insight)
    assert reason =~ "one-time authentication credentials"
  end

  test "rejects related one-time passcode and redeem-code deliveries" do
    cases = [
      {"Your OTP", "Your OTP is A7K9Q2 and expires soon."},
      {"Temporary passcode", "Your passcode is 842913. Do not share this code."},
      {"Game reward", "Use this redeem code to claim the reward: BRAWL2026."}
    ]

    for {title, body_excerpt} <- cases do
      candidate = %{
        "source" => "gmail",
        "title" => title,
        "source_item_id" => "gmail-message-#{System.unique_integer([:positive])}",
        "dedupe_key" => "gmail:code-#{System.unique_integer([:positive])}",
        "metadata" => %{"body_excerpt" => body_excerpt}
      }

      assert {:skip, reason} = SignalGate.allow_candidate?(candidate)
      assert reason =~ "transient notifications"
    end
  end

  test "rejects a bare automated login-code subject without a body" do
    candidate = %{
      "source" => "gmail",
      "title" => "Your login code",
      "source_item_id" => "gmail-message-login-code",
      "dedupe_key" => "gmail:login-code"
    }

    proposed = %{
      "summary" => "Use the login code to continue.",
      "next_action" => "Enter the login code."
    }

    assert {:skip, reason} = SignalGate.allow_candidate?(candidate, proposed)
    assert reason =~ "transient notifications"
  end

  test "keeps a real unrecognized-login incident that requires remediation" do
    candidate = %{
      "source" => "gmail",
      "title" => "Unrecognized sign-in to your account",
      "summary" => "A new device signed in and the activity was not recognized.",
      "next_action" => "Review the sign-in and secure the account.",
      "source_item_id" => "gmail-message-security-incident",
      "dedupe_key" => "gmail:security-incident",
      "metadata" => %{
        "body_excerpt" =>
          "We detected an unrecognized sign-in. Secure your account and reset your password.",
        "fyi_class" => "security_risk",
        "telegram_fit_score" => 0.95
      }
    }

    assert {:ok, _attrs} = SignalGate.allow_candidate?(candidate)
  end

  test "keeps a human request to fix login-code delivery" do
    candidate = %{
      "source" => "gmail",
      "title" => "Fix the login code delivery bug",
      "summary" => "The authentication team needs the broken code flow fixed.",
      "next_action" => "Investigate and fix the login code delivery failure.",
      "source_item_id" => "gmail-message-login-code-bug",
      "dedupe_key" => "gmail:login-code-bug",
      "metadata" => %{
        "body_excerpt" =>
          "Can you fix the login code delivery bug by Friday? Sample code 123456 still fails and customers are blocked.",
        "direct_ask" => true,
        "why_it_matters" => "Customers cannot sign in."
      }
    }

    assert {:ok, _attrs} = SignalGate.allow_candidate?(candidate)
  end

  test "keeps a concrete password-remediation request without a delivered credential" do
    candidate = %{
      "source" => "gmail",
      "title" => "Reset the service account password by Friday",
      "summary" => "IT asked you to rotate the password before the deadline.",
      "next_action" => "Reset the service account password and confirm completion.",
      "source_item_id" => "gmail-message-password-reset-request",
      "dedupe_key" => "gmail:password-reset-request",
      "metadata" => %{
        "body_excerpt" =>
          "IT asked you to reset the service account password by Friday and confirm when done.",
        "direct_ask" => true,
        "why_it_matters" => "The service account will be disabled after Friday."
      }
    }

    assert {:ok, _attrs} = SignalGate.allow_candidate?(candidate)
  end
end
