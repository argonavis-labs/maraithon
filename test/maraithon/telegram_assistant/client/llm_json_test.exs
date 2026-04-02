defmodule Maraithon.TelegramAssistantLLMJsonClientTest do
  use ExUnit.Case, async: true

  alias Maraithon.TelegramAssistant.Client.LLMJson

  test "returns source health tool call for live inbox triage questions" do
    assert {:ok, response} =
             LLMJson.next_step(payload("What are the emails to triage today?"))

    assert response["status"] == "tool_calls"

    assert response["tool_calls"] == [
             %{"tool" => "get_open_work_summary", "arguments" => %{"limit" => 5}}
           ]
  end

  test "requests a live Gmail search after source health is loaded" do
    assert {:ok, response} =
             LLMJson.next_step(
               payload(
                 "What are the emails to triage today?",
                 [
                   %{
                     "tool" => "get_open_work_summary",
                     "result" => %{
                       "source_health" => %{
                         "gmail" => %{
                           "status" => "ok",
                           "insights_stale" => true,
                           "freshest_visible_email_at" => "2026-04-02T01:21:45Z"
                         }
                       }
                     }
                   }
                 ]
               )
             )

    assert response["status"] == "tool_calls"

    assert response["tool_calls"] == [
             %{
               "tool" => "gmail_search_messages",
               "arguments" => %{
                 "query" => "in:inbox newer_than:14d -category:promotions -category:social",
                 "max_results" => 15
               }
             }
           ]
  end

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
    assert prompt =~ "\"todo_digest\""
    assert prompt =~ "one Telegram message per todo"
    assert prompt =~ "call `list_todos` with a narrow `query` first"
    assert prompt =~ "Handled the billing, what else?"
    assert prompt =~ "\"tool\":\"list_todos\""
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

  test "returns the latest visible email when asked directly" do
    tool_history = [
      %{
        "tool" => "get_open_work_summary",
        "result" => %{
          "source_health" => %{
            "gmail" => %{
              "status" => "ok",
              "insights_stale" => true,
              "freshest_visible_email_at" => "2026-04-02T01:21:45Z"
            }
          }
        }
      },
      %{
        "tool" => "gmail_search_messages",
        "result" => %{
          "messages" => [
            %{
              "message_id" => "msg-invoice",
              "thread_id" => "thread-invoice",
              "from" => "Google Payments <payments-noreply@google.com>",
              "subject" => "Google Cloud Platform & APIs: Your invoice is available",
              "snippet" => "Your invoice is available for this month.",
              "internal_date" => "2026-04-02T01:21:45Z",
              "labels" => ["INBOX"],
              "google_account_email" => "kent.fenwick@gmail.com"
            }
          ]
        }
      }
    ]

    assert {:ok, response} =
             LLMJson.next_step(payload("What is the latest email you can see?", tool_history))

    assert response["status"] == "final"
    assert response["assistant_message"] =~ "latest visible email"
    assert response["assistant_message"] =~ "Google Payments [kent.fenwick@gmail.com]"
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
