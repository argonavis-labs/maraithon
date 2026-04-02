defmodule Maraithon.ChiefOfStaff.Skills.HolidayRadarTest do
  use Maraithon.DataCase, async: true

  alias Maraithon.Accounts
  alias Maraithon.Agents
  alias Maraithon.Briefs
  alias Maraithon.ChiefOfStaff.Skills.HolidayRadar
  alias Maraithon.Projects
  alias Maraithon.Todos

  setup do
    user_id = "holiday-chief-#{System.unique_integer([:positive])}@example.com"
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

    {:ok, agent} =
      Agents.create_agent(%{
        user_id: user_id,
        behavior: "ai_chief_of_staff",
        config: %{"name" => "Holiday Chief of Staff"}
      })

    %{user_id: user_id, agent: agent}
  end

  test "records holiday briefs and durable holiday todos from an llm pass", %{
    user_id: user_id,
    agent: agent
  } do
    {:ok, _project} =
      Projects.create_project(user_id, %{
        "name" => "Family Logistics",
        "summary" => "Keep family travel and celebrations in good shape."
      })

    {:ok, [_todo]} =
      Todos.upsert_many(user_id, [
        %{
          "source" => "telegram",
          "kind" => "general",
          "title" => "Coordinate the spring calendar",
          "summary" => "Need to get ahead of upcoming family dates.",
          "next_action" => "Review the family calendar and lock plans.",
          "priority" => 58,
          "dedupe_key" => "holiday-radar:existing:1"
        }
      ])

    state =
      HolidayRadar.init(%{
        "user_id" => user_id,
        "timezone_offset_hours" => -4,
        "lookahead_days" => 30
      })

    context = %{
      agent_id: agent.id,
      user_id: user_id,
      timestamp: ~U[2026-04-28 15:00:00Z],
      budget: %{llm_calls: 10, tool_calls: 10},
      recent_events: [],
      user_memory: %{"summary" => "The user cares about thoughtful family follow-through."},
      last_message: nil,
      last_message_metadata: %{},
      last_message_id: nil,
      trigger: %{type: :wakeup, job_type: "wakeup"},
      event: nil,
      source_bundle: %{
        "calendar" => %{
          "events" => [
            %{
              "id" => "family-lunch",
              "summary" => "Family lunch hold",
              "start" => %{"dateTime" => "2026-05-03T16:00:00Z"},
              "end" => %{"dateTime" => "2026-05-03T17:00:00Z"}
            }
          ]
        }
      }
    }

    assert {:effect, {:llm_call, params}, waiting_state} =
             HolidayRadar.handle_wakeup(state, context)

    assert hd(params["messages"])["content"] =~ "Mother's Day"
    assert Map.has_key?(waiting_state.pending_holidays, "mothers_day_2026")

    response = %{
      content:
        Jason.encode!(%{
          "summary" => "Mother's Day looks relevant and needs a proactive nudge now.",
          "notifications" => [
            %{
              "holiday_id" => "mothers_day_2026",
              "phase_key" => "book_brunch",
              "should_notify" => true,
              "title" => "Mother's Day planning",
              "summary" =>
                "Mother's Day is close enough that brunch reservations and a small gift should get locked now.",
              "body" =>
                "Why now: restaurants and flowers tighten closer to Mother's Day.\n\nDo: Book brunch and decide the gift this week.",
              "priority" => 84,
              "confidence" => 0.9,
              "reasoning" =>
                "User memory and the family logistics project both suggest this matters.",
              "attention_mode" => "act_now",
              "create_todo" => true,
              "todo" => %{
                "title" => "Book Mother's Day brunch",
                "summary" => "Get the brunch reservation and gift decision locked in.",
                "next_action" => "Pick the restaurant and decide the gift today.",
                "priority" => 84,
                "attention_mode" => "act_now"
              }
            }
          ]
        })
    }

    assert {:emit, {:briefs_recorded, payload}, next_state} =
             HolidayRadar.handle_effect_result({:llm_call, response}, waiting_state, context)

    assert payload.count == 1
    assert payload.cadences == ["holiday_radar"]
    assert payload.todo_count == 1
    assert next_state.last_review_key == "2026-04-28"
    assert next_state.pending_holidays == %{}

    [brief] = Briefs.list_recent_for_user(user_id, limit: 1)
    assert brief.cadence == "holiday_radar"
    assert brief.title == "Mother's Day planning"
    assert brief.metadata["holiday_id"] == "mothers_day_2026"

    [holiday_todo] = Todos.list_for_user(user_id, source: "chief_of_staff_holiday", limit: 5)
    assert holiday_todo.title == "Book Mother's Day brunch"
    assert holiday_todo.metadata["holiday_phase_key"] == "book_brunch"
    assert holiday_todo.metadata["holiday_id"] == "mothers_day_2026"
  end

  test "stays idle after already reviewing the current local day", %{user_id: user_id} do
    state =
      HolidayRadar.init(%{
        "user_id" => user_id,
        "timezone_offset_hours" => -4
      })
      |> Map.put(:last_review_key, "2026-04-28")

    context = %{
      agent_id: Ecto.UUID.generate(),
      user_id: user_id,
      timestamp: ~U[2026-04-28 18:00:00Z],
      budget: %{llm_calls: 10, tool_calls: 10},
      recent_events: [],
      user_memory: %{},
      last_message: nil,
      last_message_metadata: %{},
      last_message_id: nil,
      trigger: %{type: :wakeup, job_type: "wakeup"},
      event: nil
    }

    assert {:idle, _next_state} = HolidayRadar.handle_wakeup(state, context)
  end
end
