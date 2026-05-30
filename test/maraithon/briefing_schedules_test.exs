defmodule Maraithon.BriefingSchedulesTest do
  use Maraithon.DataCase, async: true

  alias Maraithon.Accounts
  alias Maraithon.Agents
  alias Maraithon.BriefingSchedules

  test "summaries expose the active local offset for named timezones" do
    user_id = "briefing-schedule-#{System.unique_integer([:positive])}@example.com"
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

    {:ok, agent} =
      Agents.create_agent(%{
        user_id: user_id,
        behavior: "ai_chief_of_staff",
        config: %{
          "name" => "Chief of Staff",
          "timezone" => "America/Toronto",
          "timezone_name" => "America/Toronto",
          "timezone_offset_hours" => -5,
          "morning_brief_hour_local" => 9
        }
      })

    summary =
      BriefingSchedules.summarize_for_prompt(user_id,
        now: ~U[2026-05-09 15:00:00Z]
      )

    assert summary.timezone_name == "America/Toronto"
    assert summary.timezone_offset_hours == -4
    assert summary.local_timezone == "ET"
    assert [%{id: agent_id} = agent_schedule] = summary.agents
    assert agent_id == agent.id
    assert agent_schedule.timezone_offset_hours == -4
    assert agent_schedule.local_timezone == "ET"
  end
end
