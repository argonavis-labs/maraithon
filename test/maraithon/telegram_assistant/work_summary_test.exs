defmodule Maraithon.TelegramAssistant.WorkSummaryTest do
  use ExUnit.Case, async: true

  alias Maraithon.TelegramAssistant.{Run, Step, WorkSummary}
  alias Maraithon.TelegramConversations.Turn

  test "completed run headline names the concrete work item instead of the check" do
    run = %Run{
      status: "completed",
      model_name: "gpt-test",
      result_summary: %{"tool_steps" => 1},
      steps: [
        tool_step("list_todos", %{"todos" => [%{"title" => "Send update"}]})
      ]
    }

    summary = WorkSummary.for_run(run)

    assert summary["headline"] == "Open work: Send update"

    assert [
             %{
               "tool" => "open_work",
               "label" => "Open work",
               "summary" => "1 work item: Send update"
             }
           ] =
             summary["tool_calls"]

    assert [%{"title" => "Checked open work"}] = summary["steps"]
    refute inspect(summary) =~ "Returned 1 todo"
    refute inspect(summary) =~ "1 todo"
    refute Map.has_key?(summary, "model_name")
    refute Map.has_key?(summary, "model_tier")
    refute Map.has_key?(summary, "model_reasoning_effort")
    refute Map.has_key?(summary, "task_class")
    refute Map.has_key?(summary, "route_reason")
    refute Map.has_key?(summary, "llm_turns")
    refute Map.has_key?(summary, "tool_steps")
  end

  test "empty open-work tool summaries avoid all-clear language" do
    run = %Run{
      status: "completed",
      model_name: "gpt-test",
      result_summary: %{"tool_steps" => 1},
      steps: [
        tool_step("list_todos", %{"todos" => []})
      ]
    }

    summary = WorkSummary.for_run(run)

    assert summary["headline"] == "Checked open work and replied"

    assert [
             %{
               "tool" => "open_work",
               "label" => "Open work",
               "summary" => "No open work matched this request."
             }
           ] = summary["tool_calls"]

    assert inspect(summary) =~ "No open work matched this request."
    refute inspect(summary) =~ "No open work found"
    refute inspect(summary) =~ "surfaced"
    refute inspect(summary) =~ "all clear"
    refute inspect(summary) =~ "needs attention"
  end

  test "legacy no-open-work summaries are scoped to the current check" do
    run = %Run{
      status: "completed",
      model_name: "gpt-test",
      result_summary: %{"tool_steps" => 1},
      steps: [
        tool_step("get_open_work_summary", %{"summary" => "No open work found."})
      ]
    }

    summary = WorkSummary.for_run(run)

    assert [%{"summary" => "No open work matched this request."}] = summary["tool_calls"]
    refute inspect(summary) =~ "No open work found"
    refute inspect(summary) =~ "surfaced"
    refute inspect(summary) =~ "all clear"
  end

  test "list tool summaries name the returned work instead of only counting it" do
    turn = %Turn{
      structured_data: %{
        "tool_history" => [
          %{
            "tool" => "list_todos",
            "result" => %{
              "todos" => [
                %{
                  "title" => "Investor reply",
                  "next_action" => "Send the revised terms today."
                },
                %{"title" => "Ops review"},
                %{"title" => "School registration"}
              ]
            }
          }
        ]
      }
    }

    summary = WorkSummary.for_message(turn)

    assert [
             %{
               "tool" => "open_work",
               "label" => "Open work",
               "summary" =>
                 "3 work items: Investor reply - Send the revised terms today.; Ops review; and 1 more"
             }
           ] = summary["tool_calls"]

    refute inspect(summary) =~ "Returned 3 todos"
    refute inspect(summary) =~ "3 todos"
  end

  test "work summaries strip model-scoring prose from returned work items" do
    turn = %Turn{
      structured_data: %{
        "tool_history" => [
          %{
            "tool" => "list_todos",
            "result" => %{
              "todos" => [
                %{
                  "title" => "90% confidence: board packet follow-up",
                  "next_action" =>
                    "Model score says this should interrupt. Reply with the owner and timing.",
                  "summary" => "The user needs to reply to Alex."
                },
                %{"title" => "Ops review"}
              ]
            }
          }
        ]
      }
    }

    summary = WorkSummary.for_message(turn)

    assert [
             %{
               "tool" => "open_work",
               "label" => "Open work",
               "summary" => "2 work items: Reply with the owner and timing.; Ops review"
             }
           ] = summary["tool_calls"]

    visible_text = inspect(summary)
    refute visible_text =~ "confidence"
    refute visible_text =~ "Model score"
    refute visible_text =~ "The user"
  end

  test "work update and relationship context tools use customer-facing names" do
    turn = %Turn{
      structured_data: %{
        "tool_history" => [
          %{
            "tool" => "upsert_todos",
            "result" => %{"summary" => "Updated 2 todos."}
          },
          %{
            "tool" => "get_relationship_context",
            "result" => %{"summary" => "Found context in CRM."}
          }
        ]
      }
    }

    summary = WorkSummary.for_message(turn)

    assert summary["headline"] == "Updated open work, checked relationship context, and replied"

    assert [
             %{
               "tool" => "work_update",
               "label" => "Work update",
               "summary" => "Updated 2 work items."
             },
             %{
               "tool" => "relationship_context",
               "label" => "Relationship context",
               "summary" => "Found context in relationship data."
             }
           ] = summary["tool_calls"]

    visible_text = inspect(summary)
    refute visible_text =~ "todo"
    refute visible_text =~ "CRM"
    refute visible_text =~ "crm_context"
    refute visible_text =~ "todo_update"
  end

  test "follow-through tools do not expose internal loop language" do
    turn = %Turn{
      structured_data: %{
        "tool_history" => [
          %{
            "tool" => "get_open_loops",
            "result" => %{"summary" => "Reviewed current follow-through."}
          },
          %{
            "tool" => "inspect_open_insight",
            "result" => %{"summary" => "Checked selected work."}
          },
          %{
            "tool" => "learn_relationship_context",
            "result" => %{"message" => "Updated relationship notes."}
          }
        ]
      }
    }

    summary = WorkSummary.for_message(turn)

    assert summary["headline"] ==
             "Reviewed follow-through, checked the selected item, updated relationship notes, and replied"

    assert [
             %{"tool" => "open_loops", "label" => "Follow-through"},
             %{"tool" => "linked_item", "label" => "Selected item"},
             %{"tool" => "relationship_learning", "label" => "Relationship notes"}
           ] = summary["tool_calls"]

    visible_text = inspect(summary)
    refute visible_text =~ "Open loops"
    refute visible_text =~ "Linked item"
    refute visible_text =~ "Relationship learning"
  end

  test "completed message work summary names the concrete source result" do
    turn = %Turn{
      structured_data: %{
        "tool_history" => [
          %{
            "tool" => "review_connected_context",
            "result" => %{"summary" => "Found Matthew in Gmail and CRM."}
          }
        ],
        "summary" => "Answered from connected context."
      }
    }

    summary = WorkSummary.for_message(turn)

    assert summary["headline"] ==
             "Connected sources: Found Matthew in Gmail and relationship data"

    assert [%{"tool" => "connected_sources", "label" => "Connected sources"}] =
             summary["tool_calls"]
  end

  test "common chief of staff tools do not collapse to supporting work" do
    turn = %Turn{
      structured_data: %{
        "tool_history" => [
          %{
            "tool" => "list_people",
            "result" => %{"people" => [%{"name" => "Dana Chen"}]}
          },
          %{
            "tool" => "forget_memory",
            "result" => %{"message" => "Removed outdated context."}
          },
          %{
            "tool" => "messages_search",
            "result" => %{"messages" => [%{"sender" => "Alex", "subject" => "Board prep"}]}
          },
          %{
            "tool" => "slack_get_thread_context",
            "result" => %{"summary" => "Found the launch thread."}
          },
          %{
            "tool" => "list_connected_accounts",
            "result" => %{
              "connected_accounts" => [
                %{"account_label" => "kent@example.com", "status" => "connected"},
                %{"account_label" => "Executive Ops", "status" => "connected"}
              ]
            }
          }
        ]
      }
    }

    summary = WorkSummary.for_message(turn)

    assert summary["headline"] ==
             "Checked people, updated memory, checked Messages, and 2 more checks before replying"

    assert [
             %{"tool" => "people", "label" => "People", "summary" => "1 person: Dana Chen"},
             %{
               "tool" => "memory_update",
               "label" => "Memory update",
               "summary" => "Removed outdated context."
             },
             %{
               "tool" => "messages",
               "label" => "Messages",
               "summary" => "1 message: Alex: Board prep"
             },
             %{"tool" => "slack", "label" => "Slack", "summary" => "Found the launch thread."},
             %{
               "tool" => "connected_accounts",
               "label" => "Connected accounts",
               "summary" => "2 connected accounts: kent@example.com; Executive Ops"
             }
           ] = summary["tool_calls"]

    refute inspect(summary) =~ "Supporting work"
    refute inspect(summary) =~ "slack_get_thread_context"
    refute inspect(summary) =~ "messages_search"
  end

  test "list summaries translate raw status codes before display" do
    turn = %Turn{
      structured_data: %{
        "tool_history" => [
          %{
            "tool" => "list_connected_accounts",
            "result" => %{
              "connected_accounts" => [
                %{"account_label" => "kent@example.com", "status" => "needs_refresh"},
                %{"account_label" => "Calendar", "status" => "missing_scope"}
              ]
            }
          },
          %{
            "tool" => "list_agents",
            "result" => %{
              "agents" => [
                %{"name" => "Morning brief", "status" => "setup_required"},
                %{"name" => "Deep research", "status" => "in_progress"}
              ]
            }
          }
        ]
      }
    }

    summary = WorkSummary.for_message(turn)

    assert [
             %{
               "tool" => "connected_accounts",
               "label" => "Connected accounts",
               "summary" =>
                 "2 connected accounts: kent@example.com (reconnect needed); Calendar (needs permission)"
             },
             %{
               "tool" => "automations",
               "label" => "Automations",
               "summary" =>
                 "2 automations: Morning brief (not ready); Deep research (in progress)"
             }
           ] = summary["tool_calls"]

    visible_text = inspect(summary)
    refute visible_text =~ "needs_refresh"
    refute visible_text =~ "missing_scope"
    refute visible_text =~ "setup_required"
    refute visible_text =~ "setup needed"
    refute visible_text =~ "in_progress"
  end

  test "empty connected-context summaries stay scoped to the request" do
    turn = %Turn{
      structured_data: %{
        "tool_history" => [
          %{
            "tool" => "list_connected_accounts",
            "result" => %{"connected_accounts" => []}
          },
          %{
            "tool" => "review_connected_context",
            "result" => %{"providers" => []}
          },
          %{
            "tool" => "list_connected_accounts",
            "result" => %{"summary" => "No connected accounts found."}
          }
        ]
      }
    }

    summary = WorkSummary.for_message(turn)

    assert [
             %{
               "tool" => "connected_accounts",
               "label" => "Connected accounts",
               "summary" => "No connected accounts were available for this request."
             },
             %{
               "tool" => "connected_sources",
               "label" => "Connected sources",
               "summary" => "No connected sources were available for this request."
             },
             %{
               "tool" => "connected_accounts",
               "label" => "Connected accounts",
               "summary" => "No connected accounts were available for this request."
             }
           ] = summary["tool_calls"]

    visible_text = inspect(summary)
    refute visible_text =~ "available yet"
    refute visible_text =~ "No connected accounts found"
    refute visible_text =~ "No connected sources found"
  end

  test "empty source list summaries stay scoped to the current check" do
    turn = %Turn{
      structured_data: %{
        "tool_history" => [
          %{
            "tool" => "messages_search",
            "result" => %{"messages" => []}
          },
          %{
            "tool" => "calendar_events_around",
            "result" => %{"events" => []}
          },
          %{
            "tool" => "list_people",
            "result" => %{"people" => []}
          }
        ]
      }
    }

    summary = WorkSummary.for_message(turn)

    assert summary["headline"] ==
             "Checked Messages, checked calendar, checked people, and replied"

    assert [
             %{
               "tool" => "messages",
               "label" => "Messages",
               "summary" => "This check did not return any messages."
             },
             %{
               "tool" => "calendar",
               "label" => "Calendar",
               "summary" => "This check did not return any calendar events."
             },
             %{
               "tool" => "people",
               "label" => "People",
               "summary" => "This check did not return any people."
             }
           ] = summary["tool_calls"]

    visible_text = inspect(summary)
    refute visible_text =~ "No messages found"
    refute visible_text =~ "No events found"
    refute visible_text =~ "No people found"
    refute visible_text =~ "all clear"
  end

  test "pre-normalized public tool keys keep specific labels" do
    turn = %Turn{
      structured_data: %{
        "tool_history" => [
          %{
            "tool" => "messages",
            "result" => %{"messages" => [%{"sender" => "Alex", "subject" => "Board prep"}]}
          }
        ]
      }
    }

    summary = WorkSummary.for_message(turn)

    assert summary["headline"] == "Messages: Alex: Board prep"

    assert [
             %{
               "tool" => "messages",
               "label" => "Messages",
               "summary" => "1 message: Alex: Board prep"
             }
           ] = summary["tool_calls"]

    refute inspect(summary) =~ "Supporting work"
  end

  test "operating lists summarize named items instead of raw counts" do
    turn = %Turn{
      structured_data: %{
        "tool_history" => [
          %{
            "tool" => "list_projects",
            "result" => %{
              "projects" => [
                %{"name" => "Board prep", "status" => "active"},
                %{"name" => "Pricing launch", "status" => "paused"}
              ]
            }
          },
          %{
            "tool" => "list_agents",
            "result" => %{
              "agents" => [
                %{
                  "name" => "Morning brief",
                  "status" => "running",
                  "project_name" => "Board prep"
                }
              ]
            }
          },
          %{
            "tool" => "list_scheduled_tasks",
            "result" => %{
              "tasks" => [
                %{"title" => "Friday investor update", "status" => "active"}
              ]
            }
          },
          %{
            "tool" => "list_implementation_runs",
            "result" => %{
              "implementation_runs" => [
                %{"repo_full_name" => "bliss/maraithon", "status" => "running"}
              ]
            }
          }
        ]
      }
    }

    summary = WorkSummary.for_message(turn)

    assert summary["headline"] ==
             "Checked projects, checked automations, reviewed scheduled follow-ups, and 1 more check before replying"

    assert [
             %{
               "tool" => "projects",
               "label" => "Projects",
               "summary" => "2 projects: Board prep (active); Pricing launch (paused)"
             },
             %{
               "tool" => "automations",
               "label" => "Automations",
               "summary" => "1 automation: Morning brief (running) - Board prep"
             },
             %{
               "tool" => "scheduled_followups",
               "label" => "Scheduled follow-ups",
               "summary" => "1 scheduled follow-up: Friday investor update (active)"
             },
             %{
               "tool" => "project_run",
               "label" => "Project runs",
               "summary" => "1 project run: bliss/maraithon (running)"
             }
           ] = summary["tool_calls"]

    refute inspect(summary) =~ "Found 2 results"
    refute inspect(summary) =~ "Found 1 result"
    refute inspect(summary) =~ "1 more checks"
  end

  test "preference and memory lists name the retained context" do
    turn = %Turn{
      structured_data: %{
        "tool_history" => [
          %{
            "tool" => "list_preferences",
            "result" => %{
              "active_rules" => [
                %{"label" => "Keep morning briefs concise"},
                %{"label" => "Do not interrupt weekends"}
              ],
              "pending_rules" => []
            }
          },
          %{
            "tool" => "list_memories",
            "result" => %{
              "memories" => [
                %{"title" => "School notices matter"},
                %{"title" => "Investor prefers short updates"}
              ]
            }
          }
        ]
      }
    }

    summary = WorkSummary.for_message(turn)

    assert summary["headline"] == "Checked preferences, checked memory, and replied"

    assert [
             %{
               "tool" => "preferences",
               "label" => "Preferences",
               "summary" =>
                 "2 preferences: Keep morning briefs concise; Do not interrupt weekends"
             },
             %{
               "tool" => "memory_check",
               "label" => "Memory",
               "summary" => "2 memories: School notices matter; Investor prefers short updates"
             }
           ] = summary["tool_calls"]

    refute inspect(summary) =~ "Found 2 results"
  end

  test "empty preference summaries explain the default behavior" do
    turn = %Turn{
      structured_data: %{
        "tool_history" => [
          %{
            "tool" => "list_preferences",
            "result" => %{
              "active_rules" => [],
              "pending_rules" => [],
              "active_count" => 0,
              "pending_count" => 0
            }
          }
        ]
      }
    }

    summary = WorkSummary.for_message(turn)

    assert summary["headline"] ==
             "Preferences: Using confirmed context until you save a standing preference"

    assert [
             %{
               "tool" => "preferences",
               "label" => "Preferences",
               "summary" => "Using confirmed context until you save a standing preference."
             }
           ] = summary["tool_calls"]

    refute inspect(summary) =~ "No preferences saved yet"
    refute inspect(summary) =~ "source-backed"
  end

  test "open work tool summaries prefer executive summary copy over raw counts" do
    turn = %Turn{
      structured_data: %{
        "tool_history" => [
          %{
            "tool" => "get_open_work_summary",
            "result" => %{
              "summary" =>
                "Open work: 1 todo. Start with Send investor update. Inbox-backed follow-up is not fully covered because Gmail is not connected.",
              "todos" => [%{"title" => "Send investor update"}]
            }
          }
        ]
      }
    }

    summary = WorkSummary.for_message(turn)

    assert summary["headline"] == "Open work: Send investor update"

    assert [
             %{
               "tool" => "open_work_review",
               "label" => "Open work",
               "summary" =>
                 "Open work: 1 work item. Start here: Send investor update. Inbox-backed follow-up is not fully covered because Gmail is not connected."
             }
           ] = summary["tool_calls"]

    refute inspect(summary) =~ "Returned 1 todo"
    refute inspect(summary) =~ "1 todo"
    refute inspect(summary) =~ "Start with"
  end

  test "open work headlines name insight-backed next moves" do
    turn = %Turn{
      structured_data: %{
        "tool_history" => [
          %{
            "tool" => "get_open_work_summary",
            "result" => %{
              "summary" =>
                "Open work: 1 insight. Start with Reply in the old thread. Gmail has newer mail than this summary; search Gmail before treating inbox-backed follow-up as complete.",
              "top_insights" => [%{"title" => "Old Gmail insight"}],
              "todos" => []
            }
          }
        ]
      }
    }

    summary = WorkSummary.for_message(turn)

    assert summary["headline"] == "Open work: Reply in the old thread"

    assert [%{"tool" => "open_work_review", "summary" => tool_summary}] =
             summary["tool_calls"]

    assert String.starts_with?(
             tool_summary,
             "Open work: 1 priority item. Start here: Reply in the old thread."
           )

    refute summary["headline"] =~ "Open work: 1 insight"
    refute summary["headline"] =~ "Gmail has newer mail"
    refute tool_summary =~ "1 insight"
    refute tool_summary =~ "Start with"
    refute inspect(summary) =~ "1 insight"
  end

  test "running tool headline is action-oriented" do
    run = %Run{
      status: "running",
      model_name: "gpt-test",
      steps: [
        %Step{
          sequence: 1,
          step_type: "tool_call",
          status: "running",
          request_payload: %{"tool" => "get_relationship_context"}
        }
      ]
    }

    assert WorkSummary.for_run(run)["headline"] == "Checking relationship context"
  end

  test "running tool headlines avoid internal workflow language" do
    headline_for = fn tool ->
      run = %Run{
        status: "running",
        model_name: "gpt-test",
        steps: [
          %Step{
            sequence: 1,
            step_type: "tool_call",
            status: "running",
            request_payload: %{"tool" => tool}
          }
        ]
      }

      WorkSummary.for_run(run)["headline"]
    end

    headlines = [
      headline_for.("get_open_loops"),
      headline_for.("inspect_open_insight"),
      headline_for.("learn_relationship_context"),
      headline_for.("llm_trace_debug")
    ]

    assert headlines == [
             "Reviewing follow-through",
             "Checking the selected item",
             "Updating relationship notes",
             "Working"
           ]

    visible_text = Enum.join(headlines, " ")
    refute visible_text =~ "open loops"
    refute visible_text =~ "linked item"
    refute visible_text =~ "Learning relationship"
    refute visible_text =~ "supporting work"
    refute visible_text =~ "llm_trace_debug"
  end

  test "direct answer steps avoid model implementation jargon" do
    run = %Run{
      status: "completed",
      model_name: "gpt-test",
      steps: [
        %Step{sequence: 1, step_type: "llm_request", status: "completed"},
        %Step{
          sequence: 2,
          step_type: "llm_response",
          status: "completed",
          response_payload: %{"status" => "final"}
        }
      ]
    }

    summary = WorkSummary.for_run(run)

    assert summary["headline"] == "Answered directly"

    assert [
             %{"type" => "answer_preparation", "title" => "Prepared the answer"},
             %{"type" => "reply", "title" => "Wrote the reply"}
           ] = summary["steps"]

    visible_text = inspect(summary)
    refute visible_text =~ "llm"
    refute visible_text =~ "model"
    refute visible_text =~ "Model"
  end

  test "tool planning step is phrased as user-visible work" do
    run = %Run{
      status: "running",
      model_name: "gpt-test",
      steps: [
        %Step{
          sequence: 1,
          step_type: "llm_response",
          status: "completed",
          response_payload: %{"status" => "tool_calls"}
        }
      ]
    }

    summary = WorkSummary.for_run(run)

    assert [%{"type" => "supporting_plan", "title" => "Planned supporting checks"}] =
             summary["steps"]

    refute inspect(summary) =~ "llm_response"
    refute inspect(summary) =~ "Model chose tools"
  end

  test "unknown step types do not become visible implementation labels" do
    run = %Run{
      status: "completed",
      steps: [
        %Step{
          sequence: 1,
          step_type: "implementation_run_metadata",
          status: "completed"
        }
      ]
    }

    summary = WorkSummary.for_run(run)

    assert [%{"type" => "supporting_work", "title" => "Updated progress"}] = summary["steps"]

    visible_text = inspect(summary)
    refute visible_text =~ "implementation"
    refute visible_text =~ "metadata"
  end

  test "failed run tool details do not expose raw internal errors" do
    run = %Run{
      status: "completed",
      steps: [
        %Step{
          sequence: 1,
          step_type: "tool_call",
          status: "failed",
          request_payload: %{"tool" => "gmail_search_messages"},
          error: "** (Req.TransportError) connection refused for token abc123"
        }
      ]
    }

    summary = WorkSummary.for_run(run)

    assert summary["headline"] == "Could not complete the requested check"

    assert [
             %{
               "tool" => "gmail",
               "label" => "Gmail",
               "status" => "failed",
               "summary" => "Gmail check could not finish."
             }
           ] =
             summary["tool_calls"]

    assert [%{"detail" => "Gmail check could not finish."}] = summary["steps"]

    visible_text = inspect(summary)
    refute visible_text =~ "Req.TransportError"
    refute visible_text =~ "connection refused"
    refute visible_text =~ "abc123"
    refute visible_text =~ "Failed:"
  end

  test "failed message tool history sanitizes error details" do
    turn = %Turn{
      structured_data: %{
        "tool_history" => [
          %{
            "tool" => "review_connected_context",
            "error" => "clientError(status: 500, body: %{secret: true})"
          }
        ]
      }
    }

    summary = WorkSummary.for_message(turn)

    assert summary["headline"] == "Could not complete the requested check"

    assert [
             %{
               "tool" => "connected_sources",
               "label" => "Connected sources",
               "status" => "failed",
               "summary" => "Connected sources check could not finish."
             }
           ] = summary["tool_calls"]

    visible_text = inspect(summary)
    refute visible_text =~ "clientError"
    refute visible_text =~ "500"
    refute visible_text =~ "secret"
    refute visible_text =~ "Failed:"
  end

  test "completed result summaries do not expose internal traces or secrets" do
    turn = %Turn{
      structured_data: %{
        "tool_history" => [
          %{
            "tool" => "review_connected_context",
            "result" => %{
              "summary" =>
                "Req.TransportError stacktrace token=sk-proj-12345678901234567890 model=gpt-5 route_reason=tool_loop"
            }
          }
        ],
        "summary" => "model=gpt-5 route_reason=debug"
      }
    }

    summary = WorkSummary.for_message(turn)

    assert [
             %{
               "tool" => "connected_sources",
               "label" => "Connected sources",
               "summary" => "Completed the check."
             }
           ] = summary["tool_calls"]

    refute Map.has_key?(summary, "summary")

    visible_text = inspect(summary)
    refute visible_text =~ "Req.TransportError"
    refute visible_text =~ "stacktrace"
    refute visible_text =~ "sk-proj"
    refute visible_text =~ "model"
    refute visible_text =~ "route_reason"
  end

  test "completed result messages remove credentials without dropping useful copy" do
    turn = %Turn{
      structured_data: %{
        "tool_history" => [
          %{
            "tool" => "learn_relationship_context",
            "result" => %{
              "message" =>
                "Updated Matthew's relationship notes. Authorization: Bearer abcdef123456"
            }
          }
        ]
      }
    }

    summary = WorkSummary.for_message(turn)

    assert [
             %{
               "tool" => "relationship_learning",
               "label" => "Relationship notes",
               "summary" => "Updated Matthew's relationship notes."
             }
           ] = summary["tool_calls"]

    visible_text = inspect(summary)
    refute visible_text =~ "Authorization"
    refute visible_text =~ "Bearer"
    refute visible_text =~ "abcdef123456"
  end

  test "unknown tool names do not become visible implementation labels" do
    turn = %Turn{
      structured_data: %{
        "tool_history" => [
          %{
            "tool" => "llm_trace_debug",
            "result" => %{"count" => 1}
          }
        ]
      }
    }

    summary = WorkSummary.for_message(turn)

    assert summary["headline"] == "Completed supporting work and replied"

    assert [
             %{
               "tool" => "supporting_work",
               "label" => "Supporting work",
               "summary" => "Found 1 result."
             }
           ] =
             summary["tool_calls"]

    visible_text = inspect(summary)
    refute visible_text =~ "Returned"
    refute visible_text =~ "llm"
    refute visible_text =~ "trace"
    refute visible_text =~ "debug"
    refute visible_text =~ "Model"
  end

  test "zero-count summaries are scoped to the current check" do
    turn = %Turn{
      structured_data: %{
        "tool_history" => [
          %{
            "tool" => "search_result_metadata",
            "result" => %{"count" => 0}
          }
        ]
      }
    }

    summary = WorkSummary.for_message(turn)

    assert [
             %{
               "tool" => "supporting_work",
               "label" => "Supporting work",
               "summary" => "This check did not return any results."
             }
           ] =
             summary["tool_calls"]

    visible_text = inspect(summary)
    refute visible_text =~ "No results found"
    refute visible_text =~ "search_result_metadata"
  end

  test "unknown failed tool names use generic recovery copy" do
    turn = %Turn{
      structured_data: %{
        "tool_history" => [
          %{
            "tool" => "implementation_run_metadata",
            "error" => "stacktrace token abc"
          }
        ]
      }
    }

    summary = WorkSummary.for_message(turn)

    assert summary["headline"] == "Could not complete the requested check"

    assert [
             %{
               "tool" => "supporting_work",
               "label" => "Supporting work",
               "status" => "failed",
               "summary" => "Supporting check could not finish."
             }
           ] = summary["tool_calls"]

    visible_text = inspect(summary)
    refute visible_text =~ "implementation"
    refute visible_text =~ "metadata"
    refute visible_text =~ "stacktrace"
    refute visible_text =~ "abc"
  end

  defp tool_step(tool, response_payload) do
    %Step{
      sequence: 1,
      step_type: "tool_call",
      status: "completed",
      request_payload: %{"tool" => tool},
      response_payload: response_payload
    }
  end
end
