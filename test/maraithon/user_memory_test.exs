defmodule Maraithon.UserMemoryTest do
  use Maraithon.DataCase, async: false

  alias Maraithon.Accounts
  alias Maraithon.ConnectedAccounts
  alias Maraithon.Projects
  alias Maraithon.Repo
  alias Maraithon.TelegramAssistant.Context
  alias Maraithon.UserMemory
  alias Maraithon.UserMemory.Profile

  setup do
    user_id = "user-memory@example.com"
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)
    %{user_id: user_id}
  end

  test "refresh_profile stores an llm-derived durable profile", %{user_id: user_id} do
    assert {:ok, _project} =
             Projects.create_project(user_id, %{
               "name" => "Operator Core",
               "summary" => "Ship the reactive operator loop."
             })

    assert {:ok, _account} =
             ConnectedAccounts.upsert_manual(user_id, "google", %{
               external_account_id: "acct-1",
               metadata: %{"email" => user_id}
             })

    assert {:ok, _slack_account} =
             ConnectedAccounts.upsert_manual(user_id, "slack:TSECRET123", %{
               external_account_id: "TSECRET123",
               scopes: ["search:read"],
               metadata: %{"team_id" => "TSECRET123", "team_name" => "Executive Ops"}
             })

    assert {:ok, profile} =
             UserMemory.refresh_profile(user_id,
               llm_complete: fn prompt ->
                 assert prompt =~ "Operator Core"
                 assert prompt =~ "\"provider\":\"google\""
                 assert prompt =~ "\"provider\":\"slack\""
                 refute prompt =~ "TSECRET123"
                 refute prompt =~ "search:read"
                 refute prompt =~ "external_account_id"

                 {:ok,
                  Jason.encode!(%{
                    "summary" =>
                      "Operate as a concise chief of staff for this user and keep work tied to Operator Core.",
                    "profile" => %{
                      "working_style" => "Move quickly with clear next actions.",
                      "communication_style" => "Keep updates concise and operational.",
                      "decision_style" =>
                        "Bias toward practical execution over abstract analysis.",
                      "current_focus" => "Operator Core is the active focus right now.",
                      "important_context" => "Google is connected and part of the daily workflow."
                    },
                    "confidence" => 0.93
                  })}
               end
             )

    assert profile.summary =~ "concise chief of staff"
    assert profile.profile["working_style"] == "Move quickly with clear next actions."
    assert profile.confidence == 0.93

    assert %Profile{} = Repo.get_by(Profile, user_id: user_id)
    assert UserMemory.prompt_context(user_id).profile["current_focus"] =~ "Operator Core"
  end

  test "refresh_profile fallback uses confirmed defaults instead of internal placeholders", %{
    user_id: user_id
  } do
    assert {:ok, profile} =
             UserMemory.refresh_profile(user_id,
               llm_complete: fn _prompt -> {:error, :summary_unavailable} end
             )

    assert profile.summary =~ "No current focus has been confirmed yet."
    assert profile.profile["working_style"] =~ "source-grounded recommendations"
    assert profile.profile["important_context"] =~ "connected-source evidence"

    refute profile.summary =~ "Patterns are still emerging"
    refute profile.summary =~ "No active projects have been captured"
    refute profile.summary =~ "durable"
  end

  test "telegram assistant context exposes stored user memory", %{user_id: user_id} do
    now = DateTime.utc_now()

    Repo.insert!(%Profile{
      user_id: user_id,
      summary: "Adapt to this user by staying concise and action-heavy.",
      profile: %{
        "working_style" => "Action-heavy.",
        "communication_style" => "Concise.",
        "decision_style" => "Pragmatic.",
        "current_focus" => "Inbox triage.",
        "important_context" => "Google and Telegram are core surfaces."
      },
      confidence: 0.88,
      source_window_start: DateTime.add(now, -3600, :second),
      source_window_end: now
    })

    context = Context.build(%{user_id: user_id, chat_id: "12345"})
    user_memory = Map.fetch!(context, :user_memory)

    assert user_memory.summary =~ "staying concise"
    assert user_memory.profile["current_focus"] == "Inbox triage."
    assert user_memory.confidence == 0.88
  end
end
