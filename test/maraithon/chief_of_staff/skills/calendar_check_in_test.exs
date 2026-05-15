defmodule Maraithon.ChiefOfStaff.Skills.CalendarCheckInTest do
  use Maraithon.DataCase, async: true

  alias Maraithon.Accounts
  alias Maraithon.Agents
  alias Maraithon.Briefs.Brief
  alias Maraithon.ChiefOfStaff.Skills.CalendarCheckIn
  alias Maraithon.Repo

  setup do
    user_id = "calendar-checkin-test@example.com"
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

    {:ok, agent} =
      Agents.create_agent(%{
        user_id: user_id,
        behavior: "prompt_agent",
        config: %{"name" => "cos"}
      })

    state = CalendarCheckIn.init(%{"user_id" => user_id})

    # A guaranteed Wednesday so within_work_day? holds; 15:00 UTC = 10:00 local
    # at the default -5 offset.
    date =
      0..6
      |> Enum.find(fn d -> Date.day_of_week(Date.add(~D[2026-05-13], -d)) == 3 end)
      |> then(&Date.add(~D[2026-05-13], -&1))

    now = DateTime.new!(date, ~T[15:00:00], "Etc/UTC")

    %{user_id: user_id, agent: agent, state: state, date: date, now: now}
  end

  defp context(ctx, events, now \\ nil) do
    %{
      user_id: ctx.user_id,
      agent_id: ctx.agent.id,
      timestamp: now || ctx.now,
      trigger: %{type: :wakeup},
      source_bundle: %{"calendar" => %{"events" => events}}
    }
  end

  defp event(date, start_time, end_time, summary \\ "Meeting") do
    %{
      "summary" => summary,
      "start" => date |> DateTime.new!(start_time, "Etc/UTC") |> DateTime.to_iso8601(),
      "end" => date |> DateTime.new!(end_time, "Etc/UTC") |> DateTime.to_iso8601()
    }
  end

  test "idles outside the work day", %{state: state} = ctx do
    # 23:30 UTC = 18:30 local — past the work-day end.
    late = DateTime.new!(ctx.date, ~T[23:30:00], "Etc/UTC")
    assert {:idle, _state} = CalendarCheckIn.handle_wakeup(state, context(ctx, [], late))
  end

  test "produces an llm_call effect when the work day has an opening", %{state: state} = ctx do
    events = [event(ctx.date, ~T[16:00:00], ~T[17:00:00])]

    assert {:effect, {:llm_call, params}, pending} =
             CalendarCheckIn.handle_wakeup(state, context(ctx, events))

    assert is_map(params)
    assert pending.pending_check_in_input["openings"] != []
  end

  test "idles when the work day is fully booked", %{state: state} = ctx do
    # One event spanning the whole remaining work-day window.
    events = [event(ctx.date, ~T[14:00:00], ~T[23:59:59])]
    assert {:idle, _state} = CalendarCheckIn.handle_wakeup(state, context(ctx, events))
  end

  test "records a check-in brief on a 'send' decision", %{state: state} = ctx do
    events = [event(ctx.date, ~T[16:00:00], ~T[17:00:00])]

    {:effect, {:llm_call, _params}, pending} =
      CalendarCheckIn.handle_wakeup(state, context(ctx, events))

    response = %{
      content:
        Jason.encode!(%{
          "decision" => "send",
          "title" => "Open afternoon",
          "summary" => "You're mostly free this afternoon.",
          "body" => "You're open 12-6 except a noon meeting — want me to tee up that reply?",
          "reason" => "Large opening plus an owed reply."
        })
    }

    assert {:emit, {:briefs_recorded, payload}, final_state} =
             CalendarCheckIn.handle_effect_result(
               {:llm_call, response},
               pending,
               context(ctx, events)
             )

    assert payload.cadences == ["check_in"]
    assert final_state.last_check_in_at != nil
    assert final_state.pending_check_in_input == nil

    brief = Repo.get(Brief, payload.brief_id)
    assert brief.cadence == "check_in"
    assert brief.body =~ "noon meeting"
  end

  test "holds without recording when the model decides not to interrupt", %{state: state} = ctx do
    events = [event(ctx.date, ~T[16:00:00], ~T[17:00:00])]

    {:effect, {:llm_call, _params}, pending} =
      CalendarCheckIn.handle_wakeup(state, context(ctx, events))

    response = %{
      content:
        Jason.encode!(%{
          "decision" => "hold",
          "title" => "",
          "summary" => "",
          "body" => "",
          "reason" => "Openings are short and there is nothing worth a ping."
        })
    }

    assert {:idle, final_state} =
             CalendarCheckIn.handle_effect_result(
               {:llm_call, response},
               pending,
               context(ctx, events)
             )

    assert final_state.last_check_in_at == nil
    assert final_state.pending_check_in_input == nil
  end

  test "idles when recently checked in", %{state: state} = ctx do
    recent = %{state | last_check_in_at: DateTime.to_iso8601(DateTime.add(ctx.now, -30, :minute))}
    events = [event(ctx.date, ~T[16:00:00], ~T[17:00:00])]

    assert {:idle, _state} = CalendarCheckIn.handle_wakeup(recent, context(ctx, events))
  end
end
