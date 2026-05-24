defmodule Maraithon.TelegramAssistant.VerificationLoop do
  @moduledoc """
  Scenario-based verification for the Telegram assistant chat path.

  This is intentionally not an ExUnit test. It is an operational verification
  loop that runs against the same model, context, tool, todo, and CRM paths used
  by Telegram chat, without sending Telegram messages.
  """

  import Ecto.Query

  alias Maraithon.Accounts
  alias Maraithon.Accounts.ConnectedAccount
  alias Maraithon.ActionLedger.Action
  alias Maraithon.AssistantHarness
  alias Maraithon.ConnectedAccounts
  alias Maraithon.ContextEngine
  alias Maraithon.Crm
  alias Maraithon.Crm.{Person, PersonLink}
  alias Maraithon.LocalBrowserHistory
  alias Maraithon.LocalBrowserHistory.LocalVisit
  alias Maraithon.LocalCalendar
  alias Maraithon.LocalCalendar.LocalEvent
  alias Maraithon.Memory
  alias Maraithon.Memory.Event, as: MemoryEvent
  alias Maraithon.Memory.Item, as: MemoryItem
  alias Maraithon.PreferenceMemory
  alias Maraithon.PreferenceMemory.Profile, as: PreferenceProfile
  alias Maraithon.PreferenceMemory.Rule, as: PreferenceRule
  alias Maraithon.PreferenceMemory.RuleEvent, as: PreferenceRuleEvent
  alias Maraithon.Repo
  alias Maraithon.ScheduledTasks
  alias Maraithon.ScheduledTasks.Run, as: ScheduledTaskRun
  alias Maraithon.ScheduledTasks.Task, as: ScheduledTask
  alias Maraithon.TelegramAssistant
  alias Maraithon.TelegramAssistant.{Client.LLMJson, Context, ModelRouting, Toolbox}
  alias Maraithon.TelegramConversations
  alias Maraithon.TelegramConversations.{Conversation, Turn}
  alias Maraithon.Todos
  alias Maraithon.Todos.Todo

  @default_max_attempts 3
  @minimum_score 10
  @chat_wall_clock_ms 120_000
  @chat_llm_turns 8
  @chat_tool_steps 18

  def run_until_pass!(opts \\ []) when is_list(opts) do
    max_attempts = positive_integer(Keyword.get(opts, :max_attempts), @default_max_attempts)
    minimum_score = positive_integer(Keyword.get(opts, :minimum_score), @minimum_score)

    1..max_attempts
    |> Enum.reduce_while(nil, fn attempt, _last_result ->
      result = run_once(Keyword.put(opts, :attempt, attempt))

      if result.score >= minimum_score do
        {:halt, result}
      else
        if attempt == max_attempts do
          raise """
          Telegram assistant verification stayed below #{minimum_score}/10 after #{max_attempts} attempt(s).

          #{format_summary(result)}
          """
        else
          {:cont, result}
        end
      end
    end)
  end

  def run_once(opts \\ []) when is_list(opts) do
    attempt = positive_integer(Keyword.get(opts, :attempt), 1)
    run_id = Keyword.get(opts, :run_id) || unique_id("telegram-chat-verify")
    user_id = Keyword.get(opts, :user_id) || "#{run_id}@example.com"
    chat_id = Keyword.get(opts, :chat_id) || unique_id("verify-chat")
    cleanup? = Keyword.get(opts, :cleanup?, true)

    env = seed_environment(user_id, chat_id, run_id)

    scenario_results =
      scenarios()
      |> Enum.map(&run_scenario(&1, env, opts))

    result = summarize(run_id, user_id, chat_id, attempt, scenario_results)

    if cleanup? do
      cleanup_environment(user_id)
    end

    result
  end

  def format_summary(%{} = result) do
    scenario_lines =
      result.scenarios
      |> Enum.map(fn scenario ->
        status = if scenario.score == 10, do: "PASS", else: "FAIL"
        findings = Enum.join(scenario.findings, "; ")
        suffix = if findings == "", do: "", else: " - #{findings}"
        "#{status} #{scenario.id}: #{scenario.score}/10#{suffix}"
      end)
      |> Enum.join("\n")

    """
    score=#{result.score}/10
    run_id=#{result.run_id}
    user_id=#{result.user_id}
    chat_id=#{result.chat_id}
    #{scenario_lines}
    """
  end

  defp scenarios do
    [
      %{
        id: :retry_options,
        kind: :static
      },
      %{
        id: :chief_of_staff_contract,
        kind: :static
      },
      %{
        id: :routing_contract,
        kind: :static
      },
      %{
        id: :responsiveness_contract,
        kind: :static
      },
      %{
        id: :otp_runtime_contract,
        kind: :static
      },
      %{
        id: :context_fault_tolerance,
        kind: :static
      },
      %{
        id: :linked_routing,
        kind: :static
      },
      %{
        id: :general_chat,
        text:
          "Give me a concise two-sentence reply to someone asking to move our meeting to next week."
      },
      %{
        id: :todo_read,
        text: "What is on my todo list right now?"
      },
      %{
        id: :todo_create,
        text: "Add renew the verification passport by Friday to my todo list."
      },
      %{
        id: :todo_resolve_linked,
        text: "Mark this done.",
        linked_todo_key: :resolution_todo
      },
      %{
        id: :crm_read,
        text: "Who is Matthew Raue?"
      },
      %{
        id: :crm_upsert,
        text: "Remember that Priya Shah is my design partner and prefers Slack."
      },
      %{
        id: :linked_context,
        text: "Who is this?",
        linked_todo_key: :matthew_todo
      },
      %{
        id: :connector_status,
        text: "What accounts are connected?"
      },
      %{
        id: :meeting_prep,
        text:
          "What should I know before my meeting with Matthew Raue tomorrow? Include who he is, why we are meeting, what I owe him, and the best next move."
      },
      %{
        id: :draft_reply,
        text: "Draft a reply to Matthew Raue about the setup path, pricing owner, and ETA."
      },
      %{
        id: :memory_write,
        text:
          "Remember as durable memory: in chief-of-staff mode, family and personal calendar commitments outrank routine stale work unless the work is a close relationship or active deliverable."
      },
      %{
        id: :scheduled_job,
        text: fn env ->
          "Queue a one-time job for #{DateTime.to_iso8601(env.scheduled_job_at)} to review my open loops, calendar, CRM, and todos, then send me a prep note."
        end
      },
      %{
        id: :browser_context,
        text:
          "I was researching the Matthew Raue setup and pricing project online. What did I look at?"
      },
      %{
        id: :chief_of_staff_priority,
        text:
          "What needs my attention first today? Re-rank personal, close relationships, active business deliverables, intros, and meetings instead of dumping stale work."
      }
    ]
  end

  defp run_scenario(%{kind: :static, id: :retry_options} = scenario, _env, _opts) do
    findings = retry_option_findings()
    scenario_result(scenario, findings, %{response: nil, tool_history: []})
  end

  defp run_scenario(%{kind: :static, id: :chief_of_staff_contract} = scenario, _env, _opts) do
    tool_names =
      %{}
      |> Toolbox.tool_definitions()
      |> Enum.map(&(Map.get(&1, "name") || Map.get(&1, :name)))

    prompt =
      AssistantHarness.build_prompt(%{
        current_user_request: %{text: "chief of staff contract check"},
        request_focus: nil,
        context: %{},
        tools: [],
        tool_history: [],
        runtime_policy: AssistantHarness.runtime_policy(),
        iteration: 1,
        llm_turns: 0,
        tool_steps: 0
      })

    findings =
      []
      |> require_finding(
        Enum.all?(
          ~w(calendar_events_around calendar_events_for_person review_connected_context browser_history_search write_memory create_scheduled_task gmail_drafts),
          &(&1 in tool_names)
        ),
        "Telegram tool surface must expose calendar, connected-source, browser, memory, scheduled-task, and draft tools"
      )
      |> require_finding(
        String.contains?(prompt, "meeting-prep") and
          String.contains?(prompt, "calendar_events_for_person"),
        "assistant contract must explicitly cover meeting prep with calendar + relationship context"
      )
      |> require_finding(
        String.contains?(prompt, "gmail_drafts") and
          String.contains?(prompt, "ready-to-send draft"),
        "assistant contract must explicitly cover reply drafting and Gmail draft creation"
      )
      |> require_finding(
        String.contains?(prompt, "create_scheduled_task") and
          String.contains?(prompt, "long-running job"),
        "assistant contract must explicitly cover queued/background work"
      )
      |> require_finding(
        String.contains?(prompt, "browser_history_search") and
          String.contains?(prompt, "connected web context"),
        "assistant contract must explicitly cover connected web/browser context"
      )

    scenario_result(scenario, findings, %{response: nil, tool_history: []})
  end

  defp run_scenario(%{kind: :static, id: :routing_contract} = scenario, _env, _opts) do
    findings =
      []
      |> require_finding(
        ModelRouting.tier_for_text("What should I know before my meeting with Matthew tomorrow?") ==
          :reasoning,
        "meeting prep must route to the reasoning tier"
      )
      |> require_finding(
        ModelRouting.tier_for_text("Queue a job tomorrow morning to review open loops") ==
          :reasoning,
        "queued/background work must route to the reasoning tier"
      )
      |> require_finding(
        ModelRouting.tier_for_text("Draft a reply to Matthew about setup and pricing") ==
          :reasoning,
        "contextual draft requests must route to the reasoning tier"
      )
      |> require_finding(
        ModelRouting.tier_for_text("2+2") == :chat,
        "simple general chat must stay on the fast chat tier"
      )

    scenario_result(scenario, findings, %{response: nil, tool_history: []})
  end

  defp run_scenario(%{kind: :static, id: :responsiveness_contract} = scenario, _env, _opts) do
    policy = AssistantHarness.runtime_policy()
    connector_profile = ModelRouting.profile_for(%{text: "What accounts are connected?"})

    chat_profile =
      ModelRouting.profile_for(%{text: "Give me a quick reply saying Tuesday works."})

    deep_profile = ModelRouting.profile_for(%{text: "What should I know before my meeting?"})

    findings =
      []
      |> require_finding(
        policy.loop.max_wall_clock_ms <= 25_000,
        "default assistant loop must have a tight wall-clock budget"
      )
      |> require_finding(
        policy.loop.max_llm_turns <= 6 and policy.loop.max_tool_steps <= 10,
        "default assistant loop must be bounded by turn and tool-step limits"
      )
      |> require_finding(
        policy.tool_calls.max_per_step <= 3,
        "assistant must cap parallel tool calls per model turn"
      )
      |> require_finding(
        Map.get(chat_profile, :tier) == :chat,
        "simple conversational work must stay on the fast chat tier"
      )
      |> require_finding(
        Map.get(deep_profile, :tier) == :reasoning,
        "meeting prep/deep work must route to the reasoning tier"
      )
      |> require_finding(
        Map.get(connector_profile, :request_focus) == :connector_status,
        "connector-status requests must use narrow context/tool focus"
      )

    scenario_result(scenario, findings, %{response: nil, tool_history: []})
  end

  defp run_scenario(%{kind: :static, id: :otp_runtime_contract} = scenario, _env, _opts) do
    findings =
      []
      |> require_finding(
        Process.whereis(Maraithon.TelegramAssistant.ChatRegistry) != nil,
        "per-chat Registry must be supervised"
      )
      |> require_finding(
        Process.whereis(Maraithon.TelegramAssistant.ChatSupervisor) != nil,
        "per-chat DynamicSupervisor must be supervised"
      )
      |> require_finding(
        Process.whereis(Maraithon.TelegramAssistant.LivenessSupervisor) != nil,
        "liveness supervisor must be running for timeout/progress feedback"
      )
      |> require_finding(
        Process.whereis(Maraithon.Runtime.AgentRegistry) != nil,
        "runtime agent Registry must be supervised"
      )
      |> require_finding(
        Process.whereis(Maraithon.Runtime.EffectSupervisor) != nil,
        "runtime Task.Supervisor must isolate effect work"
      )

    scenario_result(scenario, findings, %{response: nil, tool_history: []})
  end

  defp run_scenario(%{kind: :static, id: :context_fault_tolerance} = scenario, _env, _opts) do
    started = System.monotonic_time(:millisecond)

    fetched =
      Context.safe_parallel_fetch(
        [
          {:fast, fn -> "ready" end},
          {:crash, fn -> raise "simulated fetch crash" end},
          {:slow,
           fn ->
             Process.sleep(250)
             "late"
           end}
        ],
        defaults: %{crash: "default", slow: "default"},
        timeout_ms: 25,
        max_concurrency: 3
      )

    elapsed_ms = System.monotonic_time(:millisecond) - started
    diagnostics = Map.get(fetched, :context_fetch, %{})
    failures = Map.get(diagnostics, :failures, [])

    findings =
      []
      |> require_finding(
        Map.get(fetched, :fast) == "ready",
        "context fetch must preserve successful parallel fetches"
      )
      |> require_finding(
        Map.get(fetched, :crash) == "default" and Map.get(fetched, :slow) == "default",
        "context fetch must keep defaults for crashed or timed-out fetches"
      )
      |> require_finding(
        Map.get(diagnostics, :status) == "degraded" and
          Map.get(diagnostics, :failure_count, 0) >= 2,
        "context fetch must report degraded diagnostics for failures"
      )
      |> require_finding(
        Enum.any?(failures, &(Map.get(&1, :reason) == "timeout")) or
          Enum.any?(failures, &(Map.get(&1, :reason) =~ "timeout")),
        "context fetch must kill and report timed-out fetches"
      )
      |> require_finding(
        elapsed_ms < 250,
        "context fetch must return quickly instead of waiting for slow sources"
      )

    scenario_result(scenario, findings, %{response: nil, tool_history: []})
  end

  defp run_scenario(%{kind: :static, id: :linked_routing} = scenario, _env, _opts) do
    attrs = %{text: "Who is this?", reply_to_message_id: "verify-card-1"}
    profile = ModelRouting.profile_for(attrs)
    escalated = ModelRouting.escalated_profile_for(profile)

    findings =
      []
      |> require_finding(
        Map.get(profile, :request_focus) == :linked_item_context,
        "reply-to context questions must route to linked_item_context"
      )
      |> require_finding(
        Keyword.get(Map.get(profile, :llm_opts, []), :tool_scope) == :linked_item_context,
        "linked context profile must narrow tool_scope"
      )
      |> require_finding(
        Keyword.get(Map.get(profile, :llm_opts, []), :model_busy_max_retries, 0) >= 20,
        "linked context profile must carry model busy retries"
      )
      |> require_finding(
        Map.get(escalated, :tier) == :reasoning,
        "escalated profile must switch to reasoning tier"
      )
      |> require_finding(
        Map.get(escalated, :request_focus) == :linked_item_context,
        "escalated profile must preserve linked_item_context"
      )

    scenario_result(scenario, findings, %{response: nil, tool_history: []})
  end

  defp run_scenario(%{} = scenario, env, opts) do
    run_result = run_chat_turn(scenario, env, opts)
    findings = score_chat_scenario(scenario, env, run_result)
    scenario_result(scenario, findings, run_result)
  rescue
    error ->
      scenario_result(scenario, ["raised #{Exception.message(error)}"], %{
        response: nil,
        tool_history: [],
        error: Exception.format(:error, error, __STACKTRACE__)
      })
  end

  defp retry_option_findings do
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    llm_complete = fn _params ->
      Agent.get_and_update(counter, fn count -> {count, count + 1} end)
      |> case do
        count when count < 2 ->
          {:error, {:llm_busy, 0}}

        _count ->
          {:ok,
           %{
             "content" =>
               Jason.encode!(%{
                 "status" => "final",
                 "assistant_message" => "This should not succeed when retry options are honored.",
                 "message_class" => "assistant_reply",
                 "tool_calls" => [],
                 "summary" => "retry check"
               })
           }}
      end
    end

    payload = %{
      current_user_request: %{text: "retry check"},
      request_focus: nil,
      context: %{},
      tools: [],
      tool_history: [],
      runtime_policy: AssistantHarness.runtime_policy(),
      iteration: 1,
      llm_turns: 0,
      tool_steps: 0,
      _llm_opts: [
        llm_complete: llm_complete,
        model_failover_max_attempts: 1,
        model_busy_max_retries: 1,
        model_retry_base_delay_ms: 0,
        model_retry_max_delay_ms: 0
      ]
    }

    findings =
      case LLMJson.next_step(payload) do
        {:error, {:llm_busy, _retry_after}} ->
          []

        {:ok, _response} ->
          ["LLMJson filtered model_busy_max_retries; busy retry option was not honored"]

        {:error, reason} ->
          ["unexpected retry option result: #{inspect(reason)}"]
      end

    Agent.stop(counter)
    findings
  end

  defp run_chat_turn(scenario, env, _opts) do
    text = scenario_text(scenario, env)
    source_message_id = unique_id("verify-user-msg")
    reply_to_message_id = linked_reply_to_message_id(scenario, env)

    {:ok, conversation} =
      TelegramConversations.start_or_continue(env.user_id, env.chat_id, %{
        "reply_to_message_id" => reply_to_message_id,
        "root_message_id" => reply_to_message_id || source_message_id,
        "metadata" => %{"verification_run_id" => env.run_id}
      })

    {:ok, {conversation, _turn}} =
      TelegramConversations.append_turn(conversation, %{
        "role" => "user",
        "telegram_message_id" => source_message_id,
        "reply_to_message_id" => reply_to_message_id,
        "text" => text,
        "turn_kind" => "user_message",
        "origin_type" => "chat",
        "structured_data" => %{"verification_run_id" => env.run_id}
      })

    attrs = %{
      user_id: env.user_id,
      chat_id: env.chat_id,
      source_message_id: source_message_id,
      reply_to_message_id: reply_to_message_id,
      conversation: conversation,
      text: text
    }

    profile = ModelRouting.profile_for(attrs)
    context = ContextEngine.build_context(attrs)

    runtime_context =
      build_runtime_context(env, conversation, context, profile)

    started_monotonic_ms = System.monotonic_time(:millisecond)

    case run_loop(runtime_context, AssistantHarness.initial_loop_state(), started_monotonic_ms) do
      {:ok, response, state} ->
        %{
          attrs: attrs,
          profile: profile,
          context: context,
          response: response,
          tool_history: state.tool_history,
          llm_turns: state.llm_turns,
          tool_steps: state.tool_steps
        }

      {:error, reason, state} ->
        %{
          attrs: attrs,
          profile: profile,
          context: context,
          response: nil,
          tool_history: Map.get(state, :tool_history, []),
          llm_turns: Map.get(state, :llm_turns, 0),
          tool_steps: Map.get(state, :tool_steps, 0),
          error: reason
        }
    end
  end

  defp scenario_text(%{text: text}, env) when is_function(text, 1), do: text.(env)
  defp scenario_text(%{text: text}, _env) when is_binary(text), do: text

  defp build_runtime_context(env, %Conversation{} = conversation, context, profile) do
    defaults = Map.get(context, :defaults) || Map.get(context, "defaults") || %{}

    %{
      run_id: unique_id("verification-loop"),
      user_id: env.user_id,
      chat_id: env.chat_id,
      conversation_id: conversation.id,
      context: context,
      model_tier: Map.get(profile, :tier),
      model_name: Map.get(profile, :model),
      model_reasoning_effort: Map.get(profile, :reasoning_effort),
      llm_opts:
        [
          max_wall_clock_ms: @chat_wall_clock_ms,
          max_llm_turns: @chat_llm_turns,
          max_tool_steps: @chat_tool_steps
        ]
        |> Keyword.merge(Map.get(profile, :llm_opts, [])),
      default_project_id:
        Map.get(defaults, :default_project_id) || Map.get(defaults, "default_project_id"),
      default_project_slug:
        Map.get(defaults, :default_project_slug) || Map.get(defaults, "default_project_slug"),
      default_slack_team_id:
        Map.get(defaults, :default_slack_team_id) || Map.get(defaults, "default_slack_team_id")
    }
  end

  defp run_loop(runtime_context, state, started_monotonic_ms) do
    policy_opts = Map.get(runtime_context, :llm_opts, [])

    case AssistantHarness.guard_loop(state, started_monotonic_ms, policy_opts) do
      {:error, reason} ->
        {:error, reason, state}

      :ok ->
        request_payload =
          runtime_context
          |> Map.put(:tools, ContextEngine.tool_catalog(runtime_context.context))
          |> AssistantHarness.build_loop_request_payload(state, policy_opts)
          |> Map.put(:_llm_opts, policy_opts)

        case TelegramAssistant.client_module().next_step(request_payload) do
          {:ok, %{"status" => "tool_calls"} = response} ->
            tool_calls = Map.get(response, "tool_calls", [])

            case run_tool_calls(runtime_context, tool_calls) do
              {:ok, history_entries} ->
                next_state =
                  state
                  |> Map.update!(:llm_turns, &(&1 + 1))
                  |> Map.update!(:tool_steps, &(&1 + length(history_entries)))
                  |> Map.update!(:sequence, &(&1 + 1 + length(history_entries)))
                  |> Map.update!(:tool_history, fn history -> history ++ history_entries end)

                case AssistantHarness.guard_tool_history(next_state.tool_history, policy_opts) do
                  :ok ->
                    run_loop(
                      runtime_context,
                      %{next_state | iteration: state.iteration + 1},
                      started_monotonic_ms
                    )

                  {:error, reason} ->
                    {:error, reason, next_state}
                end

              {:error, reason} ->
                {:error, reason, state}
            end

          {:ok, response} ->
            {:ok, response, Map.update!(state, :llm_turns, &(&1 + 1))}

          {:error, reason} ->
            {:error, reason, state}
        end
    end
  end

  defp run_tool_calls(runtime_context, tool_calls) when is_list(tool_calls) do
    tool_calls
    |> Enum.reduce_while({:ok, []}, fn tool_call, {:ok, acc} ->
      tool_name = Map.get(tool_call, "tool")
      arguments = Map.get(tool_call, "arguments", %{})

      case Toolbox.execute(tool_name, arguments, runtime_context) do
        {:ok, result} ->
          entry = %{
            "tool" => tool_name,
            "arguments" => arguments,
            "result" => stringify_map(result)
          }

          {:cont, {:ok, acc ++ [entry]}}

        {:error, reason} ->
          entry = %{
            "tool" => tool_name,
            "arguments" => arguments,
            "error" => normalize_error(reason)
          }

          {:cont, {:ok, acc ++ [entry]}}
      end
    end)
  end

  defp run_tool_calls(_runtime_context, _tool_calls), do: {:error, :invalid_tool_calls}

  defp score_chat_scenario(%{id: :general_chat}, _env, run) do
    final_text = final_text(run)

    []
    |> require_success(run)
    |> require_finding(final_text != "", "general chat must return a final answer")
    |> require_finding(
      not fallback_text?(final_text),
      "general chat returned a fallback/system failure"
    )
    |> require_finding(not tool_used?(run, "list_todos"), "general chat should not read todos")
    |> require_finding(not tool_used?(run, "list_people"), "general chat should not read CRM")
  end

  defp score_chat_scenario(%{id: :todo_read}, _env, run) do
    evidence_text = response_evidence_text(run)

    []
    |> require_success(run)
    |> require_tool(run, "list_todos")
    |> require_finding(
      contains_any?(evidence_text, ["dentist", "matthew", "setup", "passport"]),
      "todo read answer must mention actual persisted todo context"
    )
  end

  defp score_chat_scenario(%{id: :todo_create}, env, run) do
    persisted? =
      env.user_id
      |> Todos.list_for_user(query: "passport", statuses: ["open"], limit: 20)
      |> Enum.any?(fn todo ->
        todo
        |> todo_text()
        |> contains_all?(["passport", "renew"])
      end)

    []
    |> require_success(run)
    |> require_tool(run, "upsert_todos")
    |> require_finding(persisted?, "todo create must persist the requested passport renewal todo")
  end

  defp score_chat_scenario(%{id: :todo_resolve_linked}, env, run) do
    todo = Todos.get_for_user(env.user_id, env.resolution_todo.id)

    []
    |> require_success(run)
    |> require_tool(run, "resolve_todo")
    |> require_finding(
      tool_argument_used?(run, "resolve_todo", "todo_id", env.resolution_todo.id),
      "linked todo resolution must use the exact linked todo id"
    )
    |> require_finding(todo && todo.status == "done", "linked todo must be marked done")
  end

  defp score_chat_scenario(%{id: :crm_read}, _env, run) do
    final_text = final_text(run)

    []
    |> require_success(run)
    |> require_finding(
      tool_used?(run, "get_relationship_context") or tool_used?(run, "list_people") or
        contains_any?(final_text, ["automation", "setup", "pricing", "founder"]),
      "CRM read must use CRM tools or answer from loaded CRM context"
    )
    |> require_finding(
      contains_any?(final_text, ["matthew", "raue"]),
      "CRM read must name Matthew Raue"
    )
    |> require_finding(
      contains_any?(final_text, ["automation", "setup", "pricing", "founder"]),
      "CRM read must include relationship/project context"
    )
  end

  defp score_chat_scenario(%{id: :crm_upsert}, env, run) do
    people = Crm.list_people(env.user_id, query: "Priya Shah", limit: 5)

    persisted? =
      Enum.any?(people, fn person ->
        text =
          [
            person.display_name,
            person.relationship,
            person.preferred_communication_method,
            person.notes
          ]
          |> Enum.join(" ")
          |> String.downcase()

        String.contains?(text, "priya") and
          String.contains?(text, "design") and
          String.contains?(text, "slack")
      end)

    []
    |> require_success(run)
    |> require_tool(run, "upsert_person")
    |> require_finding(
      persisted?,
      "CRM upsert must persist Priya Shah with design + Slack context"
    )
  end

  defp score_chat_scenario(%{id: :linked_context}, env, run) do
    final_text = final_text(run)
    linked_todo_id = get_in(run, [:context, :linked_item, :todo, :id])

    []
    |> require_success(run)
    |> require_finding(
      Map.get(run.profile, :request_focus) == :linked_item_context,
      "linked context scenario must use linked_item_context focus"
    )
    |> require_finding(
      linked_todo_id == env.matthew_todo.id,
      "context must hydrate the linked todo"
    )
    |> require_finding(
      contains_any?(final_text, ["matthew", "raue"]),
      "linked answer must identify the person"
    )
    |> require_finding(
      contains_any?(final_text, ["automation", "setup", "pricing", "video", "partner"]),
      "linked answer must include enough company/project context"
    )
    |> require_finding(
      contains_any?(final_text, ["reply", "owe", "next", "ask", "pricing"]),
      "linked answer must say what the user owes or why the card exists"
    )
    |> require_finding(
      not fallback_text?(final_text),
      "linked answer returned a fallback/system failure"
    )
  end

  defp score_chat_scenario(%{id: :connector_status}, _env, run) do
    final_text = final_text(run)

    []
    |> require_success(run)
    |> require_finding(
      tool_used?(run, "list_connected_accounts") or
        contains_any?(final_text, ["telegram", "gmail", "slack"]),
      "connector status must answer from connected account context"
    )
    |> require_finding(
      not tool_used?(run, "list_people"),
      "connector status must not use CRM people tools"
    )
    |> require_finding(
      not tool_used?(run, "upsert_todos"),
      "connector status must not write todos"
    )
  end

  defp score_chat_scenario(%{id: :meeting_prep}, _env, run) do
    evidence_text = response_evidence_text(run)

    []
    |> require_success(run)
    |> require_tool(run, "calendar_events_for_person")
    |> require_finding(
      tool_used?(run, "get_relationship_context") or tool_used?(run, "review_connected_context") or
        contains_any?(evidence_text, ["raue automation", "automation tools"]),
      "meeting prep must combine calendar with CRM/source relationship context"
    )
    |> require_finding(
      contains_all?(evidence_text, ["matthew", "meeting"]) and
        contains_any?(evidence_text, ["setup", "pricing", "eta"]),
      "meeting prep must include who, meeting purpose, and attached commitment context"
    )
    |> require_finding(
      contains_any?(evidence_text, ["next", "ask", "reply", "owner", "eta", "talk"]),
      "meeting prep must include a practical next move or talk track"
    )
  end

  defp score_chat_scenario(%{id: :draft_reply}, _env, run) do
    final_text = final_text(run)

    []
    |> require_success(run)
    |> require_finding(
      contains_any?(final_text, ["hi matthew", "matthew"]),
      "draft reply must address Matthew directly"
    )
    |> require_finding(
      contains_all?(final_text, ["setup", "pricing"]) and
        contains_any?(final_text, ["eta", "by"]),
      "draft reply must cover setup path, pricing owner, and ETA"
    )
    |> require_finding(
      contains_any?(final_text, ["automation", "raue", "owner", "path"]),
      "draft reply must include enough context to be usable"
    )
    |> require_finding(
      not tool_used?(run, "gmail_drafts"),
      "plain draft request should not create a Gmail draft unless asked"
    )
  end

  defp score_chat_scenario(%{id: :memory_write}, env, run) do
    memory_text =
      [
        env.user_id
        |> Memory.list_items(limit: 30)
        |> Enum.map(&memory_item_text/1)
        |> Enum.join("\n"),
        preference_memory_text(env.user_id),
        response_evidence_text(run)
      ]
      |> Enum.join("\n")

    memory_tool_used? = tool_used?(run, "write_memory") or tool_used?(run, "remember_preferences")

    []
    |> require_success(run)
    |> require_finding(
      memory_tool_used?,
      "must call write_memory or remember_preferences for durable learning"
    )
    |> require_finding(
      contains_any?(memory_text, ["family"]) and
        contains_any?(memory_text, ["personal", "calendar"]) and
        contains_any?(memory_text, ["stale", "work", "deliverable", "relationship"]),
      "memory write must persist the chief-of-staff priority preference"
    )
  end

  defp score_chat_scenario(%{id: :scheduled_job}, env, run) do
    task_text =
      env.user_id
      |> ScheduledTasks.list_tasks(status: "active", limit: 20)
      |> Enum.map(&scheduled_task_text/1)
      |> Enum.join("\n")

    []
    |> require_success(run)
    |> require_tool(run, "create_scheduled_task")
    |> require_finding(
      contains_all?(task_text, ["open loops", "calendar"]) and
        contains_any?(task_text, ["crm", "todos", "prep"]),
      "scheduled job must persist the requested open-loop/calendar/CRM/todo review scope"
    )
  end

  defp score_chat_scenario(%{id: :browser_context}, _env, run) do
    evidence_text = response_evidence_text(run)

    []
    |> require_success(run)
    |> require_tool(run, "browser_history_search")
    |> require_finding(
      contains_all?(evidence_text, ["matthew", "setup"]) and
        contains_any?(evidence_text, ["pricing", "raue", "browser"]),
      "browser context answer must use connected browser history evidence"
    )
  end

  defp score_chat_scenario(%{id: :chief_of_staff_priority}, _env, run) do
    evidence_text = response_evidence_text(run)

    []
    |> require_success(run)
    |> require_finding(
      tool_used?(run, "get_open_loops") or tool_used?(run, "list_todos") or
        context_has_open_work?(run),
      "priority review must inspect current open loops/todos or use already-loaded current open-work context"
    )
    |> require_finding(
      contains_any?(evidence_text, ["emma", "dentist", "family", "personal"]),
      "priority review must include personal/family context"
    )
    |> require_finding(
      contains_any?(evidence_text, ["matthew", "setup", "pricing"]),
      "priority review must still include active relationship/business commitments"
    )
    |> require_finding(
      message_class(run) in ["todo_digest", "assistant_reply"],
      "priority review must return a Telegram-ready response class"
    )
  end

  defp score_chat_scenario(scenario, _env, run) do
    []
    |> require_success(run)
    |> require_finding(final_text(run) != "", "#{scenario.id} must return a final answer")
  end

  defp seed_environment(user_id, chat_id, run_id) do
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

    {:ok, _telegram} =
      ConnectedAccounts.upsert_manual(user_id, "telegram", %{
        external_account_id: chat_id,
        metadata: %{"chat_id" => chat_id, "username" => "verification"}
      })

    {:ok, _gmail} =
      ConnectedAccounts.upsert_manual(user_id, "gmail", %{
        external_account_id: "#{run_id}@gmail.example",
        metadata: %{"email" => "#{run_id}@gmail.example", "name" => "Verification Gmail"}
      })

    {:ok, _slack} =
      ConnectedAccounts.upsert_manual(user_id, "slack", %{
        external_account_id: "T-#{run_id}",
        metadata: %{"workspace_name" => "Verification Slack", "team_id" => "T-#{run_id}"}
      })

    now = DateTime.utc_now() |> DateTime.truncate(:second)
    scheduled_job_at = DateTime.add(now, 26 * 60 * 60, :second)
    calendar_device_id = seed_local_calendar(user_id, run_id, now)
    browser_device_id = seed_browser_history(user_id, run_id, now)

    {:ok, matthew} =
      Crm.upsert_person(user_id, %{
        "display_name" => "Matthew Raue",
        "first_name" => "Matthew",
        "last_name" => "Raue",
        "relationship" => "Automation tools contact asking about setup help and pricing",
        "preferred_communication_method" => "email",
        "communication_frequency" => "occasional",
        "relationship_strength" => 42,
        "affinity_score" => 35,
        "notes" =>
          "Matthew is tied to the setup-help/pricing conversation. Kent owes a concrete owner and ETA before this becomes stale.",
        "metadata" => %{"company" => "Raue Automation", "verification_run_id" => run_id}
      })

    {:ok, [matthew_todo, resolution_todo, dentist_todo]} =
      Todos.upsert_many(user_id, [
        %{
          "source" => "telegram_verification",
          "kind" => "relationship_followup",
          "attention_mode" => "act_now",
          "title" => "Reply to Matthew Raue about setup help and pricing",
          "summary" =>
            "Matthew Raue is the automation tools contact who asked about setup help and pricing; he needs a clear owner and ETA.",
          "next_action" =>
            "Send Matthew the recommended setup path, pricing owner, and concrete ETA.",
          "priority" => 80,
          "dedupe_key" => "#{run_id}:matthew-raue-followup",
          "metadata" => %{
            "company" => "Raue Automation",
            "people" => [
              %{"name" => "Matthew Raue", "relationship" => "automation tools contact"}
            ],
            "verification_run_id" => run_id
          }
        },
        %{
          "source" => "telegram_verification",
          "kind" => "personal",
          "attention_mode" => "act_now",
          "title" => "Return the verification library book",
          "summary" => "A linked-card verification todo used to prove exact todo resolution.",
          "next_action" => "Mark this done when the user replies to the card.",
          "priority" => 70,
          "dedupe_key" => "#{run_id}:resolution-linked-todo",
          "metadata" => %{"verification_run_id" => run_id}
        },
        %{
          "source" => "telegram_verification",
          "kind" => "personal",
          "attention_mode" => "act_now",
          "title" => "Book Emma dentist appointment",
          "summary" => "Family/personal todo that should appear in todo reads.",
          "next_action" => "Book Emma's dentist appointment this week.",
          "priority" => 90,
          "dedupe_key" => "#{run_id}:emma-dentist",
          "metadata" => %{"life_domain" => "family", "verification_run_id" => run_id}
        }
      ])

    {:ok, _link} =
      Crm.attach_resource(user_id, matthew.id, %{
        "resource_type" => "todo",
        "resource_id" => matthew_todo.id,
        "resource_source" => "telegram_verification",
        "title" => matthew_todo.title,
        "summary" => matthew_todo.summary,
        "relationship_note" => "Open follow-up attached to Matthew Raue."
      })

    matthew_card_id = create_linked_card(user_id, chat_id, run_id, matthew_todo, "matthew-card")

    resolution_card_id =
      create_linked_card(user_id, chat_id, run_id, resolution_todo, "resolution-card")

    %{
      user_id: user_id,
      chat_id: chat_id,
      run_id: run_id,
      matthew: matthew,
      matthew_todo: matthew_todo,
      matthew_card_id: matthew_card_id,
      resolution_todo: resolution_todo,
      resolution_card_id: resolution_card_id,
      dentist_todo: dentist_todo,
      calendar_device_id: calendar_device_id,
      browser_device_id: browser_device_id,
      scheduled_job_at: scheduled_job_at
    }
  end

  defp seed_local_calendar(user_id, run_id, now) do
    device_id = Ecto.UUID.generate()
    meeting_start = DateTime.add(now, 24 * 60 * 60, :second)
    meeting_end = DateTime.add(meeting_start, 45 * 60, :second)

    {:ok, _summary} =
      LocalCalendar.ingest_batch(user_id, device_id, [
        %{
          "source" => "calendar",
          "guid" => "#{run_id}:matthew-raue-meeting",
          "local_id" => "#{run_id}:matthew-raue-meeting",
          "calendar_name" => "kent.fenwick@gmail.com",
          "calendar_color" => "#2f80ed",
          "title" => "Matthew Raue setup and pricing prep",
          "notes" =>
            "Meeting with Matthew Raue from Raue Automation about the setup path, pricing owner, and ETA. Kent should bring a concrete recommendation and next step.",
          "location" => "Zoom",
          "start_at" => DateTime.to_iso8601(meeting_start),
          "end_at" => DateTime.to_iso8601(meeting_end),
          "organizer_email" => "matthew@raue.example",
          "attendee_emails" => ["matthew@raue.example", user_id],
          "attendees_count" => 2
        }
      ])

    device_id
  end

  defp seed_browser_history(user_id, run_id, now) do
    device_id = Ecto.UUID.generate()

    {:ok, _summary} =
      LocalBrowserHistory.ingest_batch(user_id, device_id, [
        %{
          "source" => "browser_history",
          "browser" => "chrome",
          "guid" => "#{run_id}:raue-setup-pricing",
          "local_id" => "#{run_id}:raue-setup-pricing",
          "url" => "https://raue.example/setup-pricing",
          "host" => "raue.example",
          "title" => "Matthew Raue - Raue Automation setup pricing notes",
          "visit_count" => 2,
          "last_visited_at" => DateTime.to_iso8601(DateTime.add(now, -60 * 60, :second)),
          "is_typed_url" => true
        }
      ])

    device_id
  end

  defp create_linked_card(user_id, chat_id, run_id, %Todo{} = todo, suffix) do
    card_id = unique_id("#{run_id}-#{suffix}")

    {:ok, conversation} =
      TelegramConversations.start_or_continue(user_id, chat_id, %{
        "root_message_id" => card_id,
        "metadata" => %{"verification_run_id" => run_id}
      })

    {:ok, {_conversation, _turn}} =
      TelegramConversations.append_turn(conversation, %{
        "role" => "assistant",
        "telegram_message_id" => card_id,
        "text" => "#{todo.title}\n#{todo.summary}\n#{todo.next_action}",
        "turn_kind" => "assistant_reply",
        "origin_type" => "chat",
        "structured_data" => %{
          "message_class" => "todo_item",
          "linked_todo" => %{"id" => todo.id, "title" => todo.title}
        }
      })

    card_id
  end

  defp linked_reply_to_message_id(%{linked_todo_key: :matthew_todo}, env), do: env.matthew_card_id

  defp linked_reply_to_message_id(%{linked_todo_key: :resolution_todo}, env),
    do: env.resolution_card_id

  defp linked_reply_to_message_id(_scenario, _env), do: nil

  defp cleanup_environment(user_id) do
    Repo.delete_all(from action in Action, where: action.user_id == ^user_id)
    Repo.delete_all(from run in ScheduledTaskRun, where: run.user_id == ^user_id)
    Repo.delete_all(from task in ScheduledTask, where: task.user_id == ^user_id)
    Repo.delete_all(from event in MemoryEvent, where: event.user_id == ^user_id)
    Repo.delete_all(from item in MemoryItem, where: item.user_id == ^user_id)
    Repo.delete_all(from event in PreferenceRuleEvent, where: event.user_id == ^user_id)
    Repo.delete_all(from rule in PreferenceRule, where: rule.user_id == ^user_id)
    Repo.delete_all(from profile in PreferenceProfile, where: profile.user_id == ^user_id)
    Repo.delete_all(from visit in LocalVisit, where: visit.user_id == ^user_id)
    Repo.delete_all(from event in LocalEvent, where: event.user_id == ^user_id)
    Repo.delete_all(from link in PersonLink, where: link.user_id == ^user_id)
    Repo.delete_all(from todo in Todo, where: todo.user_id == ^user_id)

    Repo.delete_all(
      from turn in Turn, join: c in assoc(turn, :conversation), where: c.user_id == ^user_id
    )

    Repo.delete_all(from conversation in Conversation, where: conversation.user_id == ^user_id)
    Repo.delete_all(from account in ConnectedAccount, where: account.user_id == ^user_id)
    Repo.delete_all(from person in Person, where: person.user_id == ^user_id)
    :ok
  rescue
    _error -> :ok
  end

  defp summarize(run_id, user_id, chat_id, attempt, scenario_results) do
    score =
      scenario_results
      |> Enum.map(& &1.score)
      |> Enum.min(fn -> 0 end)

    %{
      status: if(score == 10, do: "10/10", else: "needs_work"),
      score: score,
      run_id: run_id,
      user_id: user_id,
      chat_id: chat_id,
      attempt: attempt,
      scenarios: scenario_results
    }
  end

  defp scenario_result(scenario, findings, run_result) do
    findings = Enum.reject(findings, &is_nil/1)

    %{
      id: Map.fetch!(scenario, :id),
      score: scenario_score(findings),
      findings: findings,
      response: final_text(run_result),
      tools: tool_names(run_result),
      llm_turns: Map.get(run_result, :llm_turns, 0),
      tool_steps: Map.get(run_result, :tool_steps, 0),
      error: Map.get(run_result, :error)
    }
  end

  defp scenario_score([]), do: 10
  defp scenario_score(findings), do: max(0, 10 - length(findings) * 2)

  defp require_success(findings, run) do
    findings
    |> require_finding(
      is_nil(Map.get(run, :error)),
      "chat loop must not error: #{inspect(Map.get(run, :error))}"
    )
    |> require_finding(is_map(Map.get(run, :response)), "chat loop must produce a model response")
    |> require_finding(
      not fallback_text?(final_text(run)),
      "assistant response must not be fallback text"
    )
  end

  defp require_tool(findings, run, tool_name) do
    require_finding(findings, tool_used?(run, tool_name), "must call #{tool_name}")
  end

  defp require_finding(findings, true, _message), do: findings
  defp require_finding(findings, _false, message), do: findings ++ [message]

  defp final_text(%{response: %{} = response}) do
    response
    |> Map.get("assistant_message", "")
    |> to_string()
    |> String.trim()
  end

  defp final_text(_run), do: ""

  defp response_evidence_text(run) do
    tool_text =
      run
      |> Map.get(:tool_history, [])
      |> Enum.map(&inspect/1)
      |> Enum.join("\n")

    [final_text(run), tool_text]
    |> Enum.join("\n")
  end

  defp fallback_text?(text) when is_binary(text) do
    normalized = String.downcase(text)

    Enum.any?(
      [
        "internal issue",
        "ran out of time",
        "try again",
        "ask me for a narrower",
        "model is still busy"
      ],
      &String.contains?(normalized, &1)
    )
  end

  defp fallback_text?(_text), do: false

  defp contains_any?(text, needles) when is_binary(text) and is_list(needles) do
    normalized = String.downcase(text)
    Enum.any?(needles, &String.contains?(normalized, String.downcase(&1)))
  end

  defp contains_any?(_text, _needles), do: false

  defp contains_all?(text, needles) when is_binary(text) and is_list(needles) do
    normalized = String.downcase(text)
    Enum.all?(needles, &String.contains?(normalized, String.downcase(&1)))
  end

  defp contains_all?(_text, _needles), do: false

  defp message_class(%{response: %{} = response}) do
    response
    |> Map.get("message_class", "")
    |> to_string()
  end

  defp message_class(_run), do: ""

  defp context_has_open_work?(%{context: context}) when is_map(context) do
    todos = Map.get(context, :todos) || Map.get(context, "todos") || []
    open_loops = Map.get(context, :open_loops) || Map.get(context, "open_loops") || %{}

    (is_list(todos) and todos != []) or
      open_loop_count(open_loops) > 0
  end

  defp context_has_open_work?(_run), do: false

  defp open_loop_count(open_loops) when is_map(open_loops) do
    open_loops
    |> Map.take([:todos, "todos", :relationships, "relationships", :memory, "memory"])
    |> Map.values()
    |> Enum.map(fn
      value when is_list(value) -> length(value)
      value when is_map(value) -> map_size(value)
      _value -> 0
    end)
    |> Enum.sum()
  end

  defp open_loop_count(_open_loops), do: 0

  defp tool_used?(run, tool_name) do
    run
    |> tool_names()
    |> Enum.member?(tool_name)
  end

  defp tool_argument_used?(run, tool_name, argument_name, expected_value) do
    run
    |> Map.get(:tool_history, [])
    |> Enum.any?(fn entry ->
      Map.get(entry, "tool") == tool_name and
        get_in(entry, ["arguments", argument_name]) == expected_value
    end)
  end

  defp tool_names(%{tool_history: tool_history}) when is_list(tool_history) do
    Enum.map(tool_history, &(Map.get(&1, "tool") || Map.get(&1, :tool)))
    |> Enum.reject(&is_nil/1)
  end

  defp tool_names(_run), do: []

  defp todo_text(%Todo{} = todo) do
    [
      todo.title,
      todo.summary,
      todo.next_action,
      todo.notes,
      inspect(todo.metadata || %{})
    ]
    |> Enum.join(" ")
    |> String.downcase()
  end

  defp memory_item_text(%MemoryItem{} = item) do
    [
      item.title,
      item.content,
      item.summary,
      item.kind,
      inspect(item.tags || []),
      inspect(item.metadata || %{})
    ]
    |> Enum.join(" ")
    |> String.downcase()
  end

  defp preference_memory_text(user_id) do
    (PreferenceMemory.active_rules(user_id) ++ PreferenceMemory.pending_rules(user_id))
    |> Enum.map(&inspect/1)
    |> Enum.join("\n")
    |> String.downcase()
  end

  defp scheduled_task_text(%ScheduledTask{} = task) do
    [
      task.title,
      task.description,
      inspect(task.schedule || %{}),
      inspect(task.command || %{}),
      inspect(task.metadata || %{})
    ]
    |> Enum.join(" ")
    |> String.downcase()
  end

  defp stringify_map(map) when is_map(map) do
    Enum.reduce(map, %{}, fn {key, value}, acc ->
      Map.put(acc, to_string(key), stringify_value(value))
    end)
  end

  defp stringify_value(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp stringify_value(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  defp stringify_value(value) when is_map(value), do: stringify_map(value)
  defp stringify_value(value) when is_list(value), do: Enum.map(value, &stringify_value/1)
  defp stringify_value(value), do: value

  defp normalize_error(reason) when is_binary(reason), do: reason
  defp normalize_error(reason), do: inspect(reason)

  defp unique_id(prefix) do
    "#{prefix}-#{System.system_time(:millisecond)}-#{System.unique_integer([:positive])}"
  end

  defp positive_integer(value, _default) when is_integer(value) and value > 0, do: value

  defp positive_integer(value, default) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, ""} when parsed > 0 -> parsed
      _ -> default
    end
  end

  defp positive_integer(_value, default), do: default
end
