defmodule Maraithon.ChiefOfStaff.Skills.MorningBriefingSmokeTest do
  use Maraithon.DataCase, async: false

  alias Maraithon.Accounts
  alias Maraithon.Agents
  alias Maraithon.ChiefOfStaff.Acquisition
  alias Maraithon.ChiefOfStaff.SourceBundle
  alias Maraithon.ChiefOfStaff.Skills.MorningBriefing
  alias Maraithon.ConnectedAccounts
  alias Maraithon.TestSupport.{CapturingTelegram, NewsStub, TravelCalendarStub}
  alias Maraithon.Todos

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
             "body" => "## Today's Schedule\n- **Prep for Dawn Nguyen** and Charlie Feng.",
             "todos" => [
               %{
                 "source" => "calendar",
                 "title" => "Prep for Dawn Nguyen",
                 "summary" => "Bring meeting context into the Dawn Nguyen call.",
                 "next_action" => "Review Dawn and Kiln Studio context before the meeting.",
                 "dedupe_key" => "morning:calendar:dawn-nguyen"
               }
             ]
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
    original_insights_config = Application.get_env(:maraithon, :insights, [])
    original_todos_config = Application.get_env(:maraithon, :todos, [])

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
    Application.put_env(:maraithon, :insights, telegram_module: CapturingTelegram)

    Application.put_env(
      :maraithon,
      :todos,
      Keyword.merge(original_todos_config, llm_complete: &todo_intelligence_llm/1)
    )

    on_exit(fn ->
      Application.put_env(:maraithon, Acquisition, original_acquisition_config)
      Application.put_env(:maraithon, TravelCalendarStub, original_calendar_stub)
      Application.put_env(:maraithon, Maraithon.Runtime, original_runtime_config)
      Application.put_env(:maraithon, CapturingLLM, original_llm_config)
      Application.put_env(:maraithon, Maraithon.WebSearch, original_web_search_config)
      Application.put_env(:maraithon, :insights, original_insights_config)
      Application.put_env(:maraithon, :todos, original_todos_config)
    end)

    :ok
  end

  defp todo_intelligence_llm(_prompt) do
    {:ok,
     %{
       content:
         Jason.encode!(%{
           "summary" => "Created one briefing todo.",
           "decisions" => [
             %{
               "candidate_index" => 0,
               "action" => "create",
               "dedupe_key" => "morning:calendar:dawn-nguyen",
               "reasoning" => "The briefing emitted a concrete meeting-prep action.",
               "todo" => %{
                 "source" => "calendar",
                 "kind" => "general",
                 "attention_mode" => "act_now",
                 "title" => "Prep for Dawn Nguyen",
                 "summary" => "Bring meeting context into the Dawn Nguyen call.",
                 "next_action" => "Review Dawn and Kiln Studio context before the meeting.",
                 "priority" => 50,
                 "status" => "open",
                 "dedupe_key" => "morning:calendar:dawn-nguyen",
                 "metadata" => %{"origin_skill_id" => "morning_briefing"}
               }
             }
           ]
         })
     }}
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
    assert prompt =~ "\"schedule_coverage\""
    assert prompt =~ "\"schedule_required\":true"
    assert prompt =~ "Required external meetings are a hard coverage contract"
  end

  test "smoke_test sends Telegram-formatted HTML when requested" do
    start_supervised!(%{
      id: :capturing_telegram_recorder,
      start: {Agent, :start_link, [fn -> [] end, [name: :capturing_telegram_recorder]]}
    })

    user_id = "morning-smoke-send-#{System.unique_integer([:positive])}@example.com"
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

    {:ok, _account} =
      ConnectedAccounts.upsert_manual(user_id, "telegram", %{external_account_id: "444123"})

    {:ok, agent} =
      Agents.create_agent(%{
        user_id: user_id,
        behavior: "ai_chief_of_staff",
        config: %{
          "skill_configs" => %{
            "morning_briefing" => %{
              "timezone_offset_hours" => -5,
              "news_enabled" => false
            }
          }
        }
      })

    source_bundle =
      SourceBundle.empty(%{trigger: %{type: :manual}, timestamp: ~U[2026-05-11 14:00:00Z]})

    assert {:ok, brief, diagnostics} =
             MorningBriefing.smoke_test(agent.id,
               now: ~U[2026-05-11 14:00:00Z],
               source_bundle: source_bundle,
               send: true
             )

    assert brief["body"] =~ "Dawn Nguyen"
    assert diagnostics.todo_persistence.todo_count == 1

    [todo] = Todos.list_for_user(user_id, source: "calendar", limit: 5)
    assert todo.title == "Prep for Dawn Nguyen"
    assert todo.metadata["origin_skill_id"] == "morning_briefing"

    [message | _] = messages = Agent.get(:capturing_telegram_recorder, &Enum.reverse/1)

    assert message.chat_id == "444123"
    assert message.opts[:parse_mode] == "HTML"
    assert message.text =~ "<b>Today's Schedule</b>"
    assert message.text =~ "• <b>Prep for Dawn Nguyen</b>"
    assert message.text =~ "Review Dawn and Kiln Studio context"
    refute message.text =~ "## Today's Schedule"
    refute message.text =~ "**Prep"

    assert Enum.any?(messages, &String.contains?(&1.text, "Review Dawn and Kiln Studio context"))

    keyboard = get_in(List.last(messages).opts, [:reply_markup, "inline_keyboard"]) || []
    assert keyboard |> List.flatten() |> Enum.any?(&(&1["text"] == "Review Open Work"))
    assert diagnostics.telegram_delivery.todo_review_brief_id
  end
end
