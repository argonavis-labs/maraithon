defmodule Maraithon.ChiefOfStaff.Skills.MorningBriefingSmokeTest do
  use Maraithon.DataCase, async: false

  alias Maraithon.Accounts
  alias Maraithon.Agents
  alias Maraithon.ChiefOfStaff.Acquisition
  alias Maraithon.ChiefOfStaff.Skills.MorningBriefing
  alias Maraithon.TestSupport.{NewsStub, TravelCalendarStub}

  defmodule CapturingLLM do
    @behaviour Maraithon.LLM.Adapter

    @impl true
    def complete(params) do
      parent = Application.fetch_env!(:maraithon, __MODULE__) |> Keyword.fetch!(:test_pid)
      send(parent, {:morning_briefing_llm_params, params})

      {:ok,
       %{
         content:
           Jason.encode!(%{
             "title" => "Morning briefing",
             "summary" => "Dawn meeting included.",
             "body" => "Prep for Dawn Nguyen and Charlie Feng.",
             "todos" => []
           }),
         model: "capturing-test",
         tokens_in: 100,
         tokens_out: 40,
         finish_reason: "stop"
       }}
    end
  end

  setup do
    original_acquisition_config = Application.get_env(:maraithon, Acquisition, [])
    original_calendar_stub = Application.get_env(:maraithon, TravelCalendarStub, [])
    original_runtime_config = Application.get_env(:maraithon, Maraithon.Runtime, [])
    original_llm_config = Application.get_env(:maraithon, CapturingLLM, [])
    original_web_search_config = Application.get_env(:maraithon, Maraithon.WebSearch, [])

    Application.put_env(
      :maraithon,
      Acquisition,
      Keyword.merge(original_acquisition_config,
        calendar_module: TravelCalendarStub,
        news_module: NewsStub
      )
    )

    Application.put_env(
      :maraithon,
      Maraithon.Runtime,
      Keyword.merge(original_runtime_config,
        llm_provider: CapturingLLM,
        llm_provider_name: "test"
      )
    )

    Application.put_env(:maraithon, CapturingLLM, test_pid: self())
    Application.put_env(:maraithon, Maraithon.WebSearch, enabled: false)

    on_exit(fn ->
      Application.put_env(:maraithon, Acquisition, original_acquisition_config)
      Application.put_env(:maraithon, TravelCalendarStub, original_calendar_stub)
      Application.put_env(:maraithon, Maraithon.Runtime, original_runtime_config)
      Application.put_env(:maraithon, CapturingLLM, original_llm_config)
      Application.put_env(:maraithon, Maraithon.WebSearch, original_web_search_config)
    end)

    :ok
  end

  test "smoke_test acquires calendar sources before building the prompt" do
    user_id = "morning-smoke-#{System.unique_integer([:positive])}@example.com"
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

    now = ~U[2026-05-11 14:00:00Z]

    TravelCalendarStub.configure(
      events: [
        %{
          "event_id" => "evt-dawn",
          "summary" => "Dawn Nguyen and Charlie Feng",
          "start" => ~U[2026-05-11 19:00:00Z],
          "end" => ~U[2026-05-11 19:30:00Z],
          "attendees" => [
            %{"display_name" => "Dawn Nguyen", "email" => "dawn@kilnstudio.io"},
            %{"display_name" => "Charlie Feng", "email" => "charlie@runner.now"}
          ]
        }
      ]
    )

    source_scope = %{
      "google_accounts" => [
        %{
          "provider" => "google:calendar@example.com",
          "account_email" => "calendar@example.com",
          "services" => ["calendar"]
        }
      ]
    }

    {:ok, agent} =
      Agents.create_agent(%{
        user_id: user_id,
        behavior: "ai_chief_of_staff",
        config: %{
          "source_scope" => source_scope,
          "skill_configs" => %{
            "morning_briefing" => %{
              "timezone_offset_hours" => -5,
              "news_enabled" => false
            }
          }
        }
      })

    assert {:ok, brief, diagnostics} = MorningBriefing.smoke_test(agent.id, now: now)
    assert brief["body"] =~ "Dawn Nguyen"
    assert diagnostics.calendar_today_events == 1
    assert diagnostics.source_acquisition == "acquired"

    assert_receive {:morning_briefing_llm_params, params}
    prompt = params["messages"] |> List.first() |> Map.fetch!("content")

    assert prompt =~ "Dawn Nguyen and Charlie Feng"
    assert prompt =~ "\"meeting_prep\""
  end
end
