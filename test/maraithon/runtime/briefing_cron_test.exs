defmodule Maraithon.Runtime.BriefingCronTest do
  use Maraithon.DataCase, async: false

  import Ecto.Query

  alias Maraithon.Accounts
  alias Maraithon.AgentMarketplace
  alias Maraithon.Agents
  alias Maraithon.Briefs
  alias Maraithon.Repo
  alias Maraithon.Runtime.BriefingCron
  alias Maraithon.Runtime.ScheduledJob

  setup do
    user_id = "briefing-cron-#{System.unique_integer([:positive])}@example.com"
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

    {:ok, agent} =
      Agents.create_agent(%{
        user_id: user_id,
        behavior: "ai_chief_of_staff",
        status: "running",
        config: %{
          "enabled_skills" => ["morning_briefing"],
          "timezone_offset_hours" => -4,
          "morning_brief_hour_local" => 8,
          "news_enabled" => true,
          "news_feeds" => [%{"name" => "Test", "url" => "https://example.com/rss.xml"}]
        }
      })

    %{user_id: user_id, agent: agent}
  end

  test "schedules a due morning briefing wakeup once per configured user", %{agent: agent} do
    now = ~U[2026-05-08 13:05:00Z]

    assert %{scheduled: scheduled} = BriefingCron.schedule_due_morning_briefings(now)
    assert scheduled >= 1

    assert %{skipped: skipped} = BriefingCron.schedule_due_morning_briefings(now)
    assert skipped >= 1

    [job] =
      ScheduledJob
      |> where([j], j.agent_id == ^agent.id and j.job_type == "wakeup")
      |> Repo.all()

    assert job.status == "pending"
    assert job.payload["source"] == "briefing_cron"
    assert job.payload["cadence"] == "morning"
    assert job.payload["dedupe_key"] == "morning_briefing:2026-05-08"
    assert job.payload["local_date"] == "2026-05-08"

    assert job.payload["timezone_offset_hours"] == -4
  end

  test "does not schedule when today's brief already exists", %{user_id: user_id, agent: agent} do
    now = ~U[2026-05-08 13:05:00Z]

    assert {:ok, _brief} =
             Briefs.record(user_id, agent.id, %{
               "cadence" => "morning",
               "title" => "Morning briefing already queued",
               "summary" => "This user already has a morning briefing for today.",
               "body" => "No duplicate scheduler work should be created.",
               "scheduled_for" => now,
               "dedupe_key" => "morning_briefing:2026-05-08"
             })

    assert %{scheduled: scheduled} = BriefingCron.schedule_due_morning_briefings(now)
    assert scheduled >= 0

    assert [] =
             ScheduledJob
             |> where([j], j.agent_id == ^agent.id and j.job_type == "wakeup")
             |> Repo.all()
  end

  test "schedules manifest-installed Chief of Staff packages" do
    user_id = "manifest-briefing-cron-#{System.unique_integer([:positive])}@example.com"
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

    assert {:ok, [agent]} = AgentMarketplace.ensure_default_installations(user_id: user_id)
    assert agent.behavior == "manifest_agent"
    assert agent.config["source_behavior"] == "ai_chief_of_staff"

    now = ~U[2026-05-08 13:05:00Z]
    assert %{scheduled: scheduled} = BriefingCron.schedule_due_morning_briefings(now)
    assert scheduled >= 1

    assert [job] =
             ScheduledJob
             |> where([j], j.agent_id == ^agent.id and j.job_type == "wakeup")
             |> Repo.all()

    assert job.payload["source"] == "briefing_cron"
    assert job.payload["cadence"] == "morning"
    assert job.payload["dedupe_key"] == "morning_briefing:2026-05-08"
  end
end
