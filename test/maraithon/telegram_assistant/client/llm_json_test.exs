defmodule Maraithon.TelegramAssistantLLMJsonClientTest do
  use ExUnit.Case, async: true

  alias Maraithon.TelegramAssistant.Client.LLMJson

  test "build_prompt instructs the model to persist and resolve todos" do
    prompt =
      LLMJson.build_prompt(
        payload(
          "Handled the billing, what else?",
          [
            %{
              "tool" => "list_todos",
              "result" => %{
                "todos" => [
                  %{
                    "id" => "todo-billing",
                    "title" => "Billing account past due",
                    "status" => "open"
                  }
                ]
              }
            }
          ]
        )
      )

    assert prompt =~ "Persist actionable work as todos."
    assert prompt =~ "do not infer from the sender, subject, snippet"
    assert prompt =~ "Only summarize or explain an email after `gmail_get_message`"
    assert prompt =~ "\"todo_digest\""
    assert prompt =~ "one Telegram message per todo"
    assert prompt =~ "call `list_todos` with a narrow `query` first"
    assert prompt =~ "Handled the billing, what else?"
    assert prompt =~ "\"tool\":\"list_todos\""
  end

  test "build_prompt instructs the model to use CRM relationship tools" do
    prompt = LLMJson.build_prompt(payload("What do I owe Justin?"))

    assert prompt =~ "The built-in CRM is the durable relationship layer"
    assert prompt =~ "get_open_loops"
    assert prompt =~ "get_relationship_context"
    assert prompt =~ "upsert_person"
    assert prompt =~ "link_person_data"
    assert prompt =~ "review_connected_context"
    assert prompt =~ "Do not stop with `I don't have Charlie in your CRM`"
    assert prompt =~ "what do I owe Justin?"
  end

  test "build_prompt instructs the model to use deep memory tools" do
    prompt = LLMJson.build_prompt(payload("That VC newsletter is not relevant to me."))

    assert prompt =~ "Deep memory is the general built-in memory database"
    assert prompt =~ "recall_memory"
    assert prompt =~ "write_memory"
    assert prompt =~ "record_memory_feedback"
    assert prompt =~ "not relevant"
  end

  test "build_prompt instructs the model to sound like a chief of staff" do
    prompt = LLMJson.build_prompt(payload("What should I do next?"))

    assert prompt =~ "Voice contract"
    assert prompt =~ "smart, capable chief of staff"
    assert prompt =~ "Avoid report labels"
    assert prompt =~ "Never mention internal priority scores"
    assert prompt =~ "relationship questions"
    assert prompt =~ "actionable chief-of-staff note"
  end

  test "build_prompt instructs the model to capture manual todos and return itemized todo lists" do
    prompt =
      LLMJson.build_prompt(payload("Add renew the domain this week to my todo list."))

    assert prompt =~ "store it as a durable todo"
    assert prompt =~ "source: \"telegram\""
    assert prompt =~ "kind: \"general\""
    assert prompt =~ "what's on my todo list?"
    assert prompt =~ "one individual todo card per item"
  end

  test "build_prompt instructs the model to answer review questions with the full todo digest" do
    prompt = LLMJson.build_prompt(payload("What should I review?"))

    assert String.contains?(String.downcase(prompt), "what should i review?")
    assert String.contains?(String.downcase(prompt), "what should i work on?")
    assert String.contains?(prompt, "get_open_loops")
    assert String.contains?(prompt, "do not offer to send the full list later")
    assert String.contains?(prompt, "do not stop at a short top-3 or top-5 summary")
    assert String.contains?(prompt, "full actionable todo digest")
    assert String.contains?(prompt, "\"todo_digest\"")
  end

  test "build_prompt instructs the model to update briefing schedules in local time" do
    prompt =
      LLMJson.build_prompt(%{
        context: %{
          "briefing_schedule" => %{
            "configured" => true,
            "local_timezone" => "UTC-04:00",
            "morning" => %{"hour_local" => 9, "time_local" => "09:00"}
          },
          "recent_turns" => [
            %{"role" => "assistant", "text" => "Earlier reply"},
            %{
              "role" => "user",
              "text" => "Can you send my morning briefings at 10 instead of 9?"
            }
          ]
        },
        tool_history: []
      })

    assert prompt =~ "update_briefing_schedule"
    assert prompt =~ "10 instead of 9"
    assert prompt =~ "10:00 AM"
    assert prompt =~ "current local timezone"
  end

  test "next_step applies explicit model routing options from the runner payload" do
    parent = self()

    payload =
      payload("What should I do next?")
      |> Map.put(
        :_llm_opts,
        chat_model: "reasoning-tier",
        reasoning_effort: "high",
        max_tokens: 6_000,
        llm_complete: fn params ->
          send(parent, {:llm_params, params})

          {:ok,
           %{
             content:
               Jason.encode!(%{
                 "status" => "final",
                 "assistant_message" => "Start with the most time-sensitive open loop.",
                 "message_class" => "assistant_reply",
                 "tool_calls" => [],
                 "summary" => "Answered from the routed request."
               })
           }}
        end
      )

    assert {:ok, response} = LLMJson.next_step(payload)
    assert response["status"] == "final"

    assert_receive {:llm_params, params}
    assert params["model"] == "reasoning-tier"
    assert params["reasoning_effort"] == "high"
    assert params["max_tokens"] == 6_000
  end

  test "build_prompt instructs the model to persist and remove durable preferences" do
    prompt =
      LLMJson.build_prompt(
        payload("Don't surface receipt emails unless they imply follow-up work.")
      )

    assert prompt =~ "remember_preferences"
    assert prompt =~ "list_preferences"
    assert prompt =~ "forget_preference"
    assert prompt =~ "durable preference"
    assert prompt =~ "receipt emails"
  end

  defp payload(message, tool_history \\ []) do
    %{
      context: %{
        "recent_turns" => [
          %{"role" => "assistant", "text" => "Earlier reply"},
          %{"role" => "user", "text" => message}
        ]
      },
      tool_history: tool_history
    }
  end
end
