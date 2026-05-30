defmodule Maraithon.ChiefOfStaff.Skills.CalendarCheckInTest do
  use Maraithon.DataCase, async: true

  alias Maraithon.Accounts
  alias Maraithon.Agents
  alias Maraithon.Briefs.Brief
  alias Maraithon.ChiefOfStaff.Skills.CalendarCheckIn
  alias Maraithon.Repo
  alias Maraithon.Todos

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

  test "accepts markdown-fenced model JSON as a real check-in", %{state: state} = ctx do
    events = [event(ctx.date, ~T[16:00:00], ~T[17:00:00])]

    {:effect, {:llm_call, _params}, pending} =
      CalendarCheckIn.handle_wakeup(state, context(ctx, events))

    check_in_json =
      Jason.encode!(%{
        "decision" => "send",
        "title" => "Open afternoon",
        "summary" => "You have a clean work block this afternoon.",
        "body" => "You have a clean 12-6 window. Use it to reply to Alex about pricing.",
        "reason" => "Large opening plus a specific owed reply."
      })

    response = %{
      content: """
      This is the check-in I would send.

      ```json
      #{check_in_json}
      ```
      """
    }

    assert {:emit, {:briefs_recorded, payload}, final_state} =
             CalendarCheckIn.handle_effect_result(
               {:llm_call, response},
               pending,
               context(ctx, events)
             )

    assert payload.generation_mode == "llm"
    assert final_state.last_check_in_at != nil

    brief = Repo.get!(Brief, payload.brief_id)
    assert brief.title == "Open afternoon"
    assert brief.summary == "You have a clean work block this afternoon"
    assert brief.body == "You have a clean 12-6 window. Use it to reply to Alex about pricing"
    assert brief.metadata["generation_mode"] == "llm"
    refute brief.body =~ "model_response_invalid"
  end

  test "cleans internal process language before recording a check-in brief",
       %{state: state} = ctx do
    events = [event(ctx.date, ~T[16:00:00], ~T[17:00:00])]

    {:effect, {:llm_call, _params}, pending} =
      CalendarCheckIn.handle_wakeup(state, context(ctx, events))

    response = %{
      content:
        Jason.encode!(%{
          "decision" => "send",
          "title" => "90% confidence: interrupt now",
          "summary" => "Model score says this calendar gap is worth a Telegram check-in.",
          "body" =>
            "90% confidence this should send.\n\nAction: Use 12-6 to reply to Alex about pricing.\n\nReasoning: model saw an owed reply.",
          "reason" => "Model confidence was high."
        })
    }

    assert {:emit, {:briefs_recorded, payload}, _final_state} =
             CalendarCheckIn.handle_effect_result(
               {:llm_call, response},
               pending,
               context(ctx, events)
             )

    brief = Repo.get(Brief, payload.brief_id)

    assert brief.title =~ "Open time:"
    assert brief.summary == "Best use: Use 12-6 to reply to Alex about pricing."
    assert brief.body == "Use 12-6 to reply to Alex about pricing"
    assert brief.metadata["reason"] == "Model confidence was high."

    refute brief.title =~ "confidence"
    refute brief.summary =~ "Model"
    refute brief.summary =~ "most important reply or meeting prep"
    refute brief.body =~ "confidence"
    refute brief.body =~ "Reasoning"
    refute brief.body =~ "model"
  end

  test "fallback check-in copy uses the concrete next action for open work",
       %{state: state} = ctx do
    {:ok, [_todo]} =
      Todos.upsert_many(ctx.user_id, [
        %{
          "source" => "gmail",
          "kind" => "gmail_triage",
          "title" => "Reply to Alex about pricing",
          "summary" => "Alex is waiting for pricing guidance before the afternoon follow-up.",
          "next_action" => "Send Alex the revised enterprise price before the 2 PM follow-up.",
          "dedupe_key" => "calendar-checkin:alex-pricing",
          "priority" => 98
        }
      ])

    events = [event(ctx.date, ~T[16:00:00], ~T[17:00:00])]

    {:effect, {:llm_call, _params}, pending} =
      CalendarCheckIn.handle_wakeup(state, context(ctx, events))

    response = %{
      content:
        Jason.encode!(%{
          "decision" => "send",
          "title" => "95% confidence: interrupt now",
          "summary" => "Model score says the calendar gap is worth a Telegram check-in.",
          "body" => "95% confidence this should send.\n\nReasoning: model saw one open todo.",
          "reason" => "Model confidence was high."
        })
    }

    assert {:emit, {:briefs_recorded, payload}, _final_state} =
             CalendarCheckIn.handle_effect_result(
               {:llm_call, response},
               pending,
               context(ctx, events)
             )

    brief = Repo.get!(Brief, payload.brief_id)

    assert brief.summary ==
             "Best use: Send Alex the revised enterprise price before the 2 PM follow-up."

    assert brief.body =~ "You have 10:00-11:00 open."

    assert brief.body =~
             "Best use: Send Alex the revised enterprise price before the 2 PM follow-up."

    refute brief.body =~ "handle Reply to Alex about pricing"
    refute String.downcase(brief.body) =~ "model"
    refute String.downcase(brief.summary) =~ "confidence"
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
