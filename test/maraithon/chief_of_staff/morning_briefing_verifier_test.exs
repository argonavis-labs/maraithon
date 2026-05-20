defmodule Maraithon.ChiefOfStaff.MorningBriefingVerifierTest do
  use Maraithon.DataCase, async: true

  alias Maraithon.Accounts
  alias Maraithon.Agents
  alias Maraithon.Briefs
  alias Maraithon.ChiefOfStaff.MorningBriefingVerifier
  alias Maraithon.Effects.Effect
  alias Maraithon.Repo

  setup do
    user_id = "morning-briefing-verifier-#{System.unique_integer([:positive])}@example.com"
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

    %{user_id: user_id}
  end

  test "flags stale nested LLM budget and recent generation failures", %{user_id: user_id} do
    {:ok, agent} =
      Agents.create_agent(%{
        user_id: user_id,
        behavior: "ai_chief_of_staff",
        status: "running",
        config: %{
          "skill_configs" => %{
            "morning_briefing" => %{
              "llm_max_tokens" => 64_000,
              "llm_reasoning_effort" => "xhigh"
            }
          }
        }
      })

    assert {:ok, _brief} =
             Briefs.record(user_id, agent.id, %{
               "cadence" => "morning",
               "title" => "Morning briefing generation failed",
               "summary" => "The configured model did not produce a valid brief.",
               "body" => "Morning briefing model synthesis failed.",
               "status" => "sent",
               "scheduled_for" => DateTime.utc_now(),
               "dedupe_key" => "morning-briefing-verifier:failed",
               "metadata" => %{
                 "generation_mode" => "error",
                 "llm_finish_reason" => "error",
                 "error_message" =>
                   "Morning briefing model synthesis failed: {:rate_limited, 60000}"
               }
             })

    report = MorningBriefingVerifier.verify(agent_id: agent.id)
    issue_codes = Enum.map(report["issues"], & &1["code"])

    assert report["status"] == "attention_required"
    assert "morning_briefing_oversized_raw_budget" in issue_codes
    assert "morning_briefing_xhigh_raw_reasoning" in issue_codes
    assert "recent_morning_briefing_generation_failures" in issue_codes

    [agent_report] = report["agents"]
    assert agent_report["effective_request"]["llm_max_tokens"] == 16_000
    assert agent_report["effective_request"]["llm_reasoning_effort"] == "high"
  end

  test "passes clean running morning briefing config", %{user_id: user_id} do
    {:ok, agent} =
      Agents.create_agent(%{
        user_id: user_id,
        behavior: "ai_chief_of_staff",
        status: "running",
        config: %{
          "skill_configs" => %{
            "morning_briefing" => %{
              "llm_max_tokens" => 16_000,
              "llm_reasoning_effort" => "high"
            }
          }
        }
      })

    report = MorningBriefingVerifier.verify(agent_id: agent.id)
    agent_id = agent.id

    assert report["status"] == "ok"
    assert report["issues"] == []
    assert [%{"agent_id" => ^agent_id}] = report["agents"]
  end

  test "flags recent rate-limited LLM effects", %{user_id: user_id} do
    {:ok, agent} =
      Agents.create_agent(%{
        user_id: user_id,
        behavior: "ai_chief_of_staff",
        status: "running",
        config: %{}
      })

    {:ok, effect_id} =
      Maraithon.Effects.request(agent.id, "llm_call", nil, %{
        "messages" => [%{"role" => "user", "content" => "brief"}]
      })

    retry_after = DateTime.add(DateTime.utc_now(), 60, :second)

    Repo.update_all(
      from(e in Effect, where: e.id == ^effect_id),
      set: [
        status: "pending",
        retry_after: retry_after,
        error: "{:rate_limited, 60000}"
      ]
    )

    report = MorningBriefingVerifier.verify(agent_id: agent.id)
    issue_codes = Enum.map(report["issues"], & &1["code"])

    assert report["status"] == "attention_required"
    assert "recent_llm_rate_limits" in issue_codes
    assert report["effect_queue"]["active_status_counts"]["pending"] == 1
    assert [%{"id" => ^effect_id}] = report["effect_queue"]["recent_noncompleted_llm_effects"]
  end
end
