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
  alias Maraithon.Repo
  alias Maraithon.TelegramAssistant
  alias Maraithon.TelegramAssistant.{Client.LLMJson, ModelRouting, Toolbox}
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
      }
    ]
  end

  defp run_scenario(%{kind: :static, id: :retry_options} = scenario, _env, _opts) do
    findings = retry_option_findings()
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
    text = Map.fetch!(scenario, :text)
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
      |> Todos.list_for_user(query: "verification passport", statuses: ["open"], limit: 10)
      |> Enum.any?()

    []
    |> require_success(run)
    |> require_tool(run, "upsert_todos")
    |> require_finding(persisted?, "todo create must persist the requested passport todo")
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
      dentist_todo: dentist_todo
    }
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
