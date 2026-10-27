defmodule Maraithon.Todos.WorkflowReviewTest do
  use Maraithon.DataCase, async: true

  alias Maraithon.{Accounts, Todos}
  alias Maraithon.ChiefOfStaff.SourceBundle
  alias Maraithon.Crm.Person
  alias Maraithon.Todos.{CrossSourceCompletion, Todo, Workflow}

  @now ~U[2099-06-27 14:00:00Z]
  @cases [
    {"Resolve the supplier balance", "The invoice dispute is with collections for review.",
     "waiting", "person", "Review the disputed invoice", "The balance is settled in full."},
    {"Give the recruiter edit access", "The invitation is sent; acceptance is still needed.",
     "they_own", "person", "Accept the invitation and verify edit access",
     "I accepted and verified that I can edit the priority sheet."},
    {"Restore the service after server errors",
     "The patch is deployed; recovery checks are running.", "working", "user",
     "Verify the service is healthy",
     "Recovery checks passed and the affected service is healthy."},
    {"Send the requested page URL", "I found the exact page URL and am preparing the reply.",
     "working", "user", "Send the requested page URL",
     "I sent the requested page URL in this thread."},
    {"Deliver the promised draft", "I finished the outline; the draft still needs the examples.",
     "working", "user", "Finish the examples and deliver the draft",
     "I sent the complete promised draft with its examples."},
    {"Monitor outreach replies and arrange meetings",
     "One prospect replied and their meeting is booked.", "waiting", "user",
     "Monitor the remaining outreach conversations", nil},
    {"Fill all open staffing positions", "One position is filled; fifteen remain open.",
     "working", "user", "Staff the remaining fifteen positions", nil}
  ]

  for {title, progress, state, kind, next, completion} <- @cases,
      channel <- ~w(gmail slack) do
    @scenario {title, progress, state, kind, next, completion, channel}
    test "#{channel}: #{title} preserves its outcome through progress" do
      {title, progress, state, kind, next, completion, channel} = @scenario
      {todo, person} = tracked_todo!(title, channel)

      owner =
        if kind == "person", do: %{"kind" => kind, "id" => person.id}, else: %{"kind" => kind}

      proposal = progress_resolution(todo, progress, state, owner, next)

      assert %{checked: 1, completed: 0} = review(todo, [{progress, @now}], fn _ -> proposal end)
      current = Todos.get_for_user(todo.user_id, todo.id)
      assert current.status == "open"
      assert current.workflow["state"] == state
      assert current.workflow["owner"]["kind"] == kind
      assert current.workflow["outcome"] == title
      assert current.next_action == next
      assert current.workflow["revision"] == 2

      if completion do
        resolution = %{
          "todo_id" => todo.id,
          "completed" => true,
          "outcome_confirmed" => true,
          "evidence_channel" => channel,
          "evidence_quote" => completion,
          "confidence" => 0.99
        }

        assert %{completed: 1} =
                 review(current, [{completion, DateTime.add(@now, 60)}], fn _ -> resolution end)

        assert Todos.get_for_user(todo.user_id, todo.id).workflow["state"] == "done"
      else
        assert Workflow.ball_label(Workflow.current(current)) in [
                 "Your move",
                 "You own follow-up"
               ]
      end
    end
  end

  test "exact account review keeps a valid handoff when another chunk claims unconfirmed completion" do
    {todo, _} = tracked_todo!("Resolve the supplier balance", "gmail")
    old = "I will pay tomorrow."
    fresh = "The dispute needs your invoice reference before we can resolve it."
    padding = String.duplicate(" background", 16_000)

    assert %{completed: 0, model_calls: calls} =
             review(
               todo,
               [{old <> padding, DateTime.add(@now, -60)}, {fresh, @now}],
               fn activity ->
                 if Enum.any?(activity, &String.contains?(&1["text"] || "", fresh)) do
                   progress_resolution(
                     todo,
                     fresh,
                     "you_own",
                     %{"kind" => "user"},
                     "Send the invoice reference"
                   )
                 else
                   %{
                     "todo_id" => todo.id,
                     "completed" => true,
                     "evidence_channel" => "gmail",
                     "evidence_quote" => old,
                     "confidence" => 0.99
                   }
                 end
               end
             )

    assert calls > 1
    current = Todos.get_for_user(todo.user_id, todo.id)
    assert current.status == "open"
    assert current.workflow["state"] == "you_own"
    assert current.next_action == "Send the invoice reference"
  end

  test "multi-chunk progress follows source chronology instead of input order" do
    {todo, person} = tracked_todo!("Grant access to the priority sheet", "gmail")
    old = "The invitation is sent; please accept it."
    fresh = "I accepted, but you still need to enable editing."
    padding = String.duplicate(" background", 16_000)

    assert %{completed: 0, model_calls: calls} =
             review(
               todo,
               [{old <> padding, DateTime.add(@now, -60)}, {fresh, @now}],
               fn activity ->
                 if Enum.any?(activity, &String.contains?(&1["text"] || "", fresh)) do
                   progress_resolution(
                     todo,
                     fresh,
                     "you_own",
                     %{"kind" => "user"},
                     "Enable editing"
                   )
                 else
                   progress_resolution(
                     todo,
                     old,
                     "they_own",
                     %{"kind" => "person", "id" => person.id},
                     "Accept the invitation"
                   )
                 end
               end
             )

    assert calls > 1
    current = Todos.get_for_user(todo.user_id, todo.id)
    assert current.workflow["state"] == "you_own"
    assert current.next_action == "Enable editing"
  end

  test "unverified people and uncited transitions do not change ownership" do
    {todo, _} = tracked_todo!("Resolve the supplier balance", "slack")
    quote = "Collections will review the disputed invoice."

    for {owner, cited} <- [
          {%{"kind" => "person", "id" => Ecto.UUID.generate()}, quote},
          {%{"kind" => "user"}, "Invented evidence absent from the source"}
        ] do
      assert %{completed: 0} =
               review(todo, [{quote, @now}], fn _ ->
                 progress_resolution(todo, cited, "waiting", owner, "Review the invoice")
               end)

      assert Todos.get_for_user(todo.user_id, todo.id).workflow == todo.workflow
    end
  end

  test "conflicting owners supported at the same source time leave the current owner intact" do
    {todo, person} = tracked_todo!("Resolve access to the priority sheet", "gmail")
    first = "I sent the invitation and need you to accept it."
    second = "I accepted and need you to enable editing."
    padding = String.duplicate(" background", 16_000)

    assert %{completed: 0, model_calls: calls} =
             review(todo, [{first <> padding, @now}, {second, @now}], fn activity ->
               if Enum.any?(activity, &String.contains?(&1["text"] || "", second)) do
                 progress_resolution(
                   todo,
                   second,
                   "you_own",
                   %{"kind" => "user"},
                   "Enable editing"
                 )
               else
                 progress_resolution(
                   todo,
                   first,
                   "they_own",
                   %{"kind" => "person", "id" => person.id},
                   "Accept the invitation"
                 )
               end
             end)

    assert calls > 1
    assert Todos.get_for_user(todo.user_id, todo.id).workflow == todo.workflow
  end

  test "waiting on a named responder returns follow-up to the user when review is due" do
    {todo, person} = tracked_todo!("Get feedback on the update format", "slack")
    due = DateTime.add(DateTime.utc_now(), -60)

    attrs = %{
      "state" => "waiting",
      "owner" => %{"kind" => "person", "id" => person.id},
      "expected_revision" => 1,
      "next_action" => "Provide feedback on the update format",
      "reason" => "The responder supplied this review date",
      "waiting_until" => DateTime.to_iso8601(due)
    }

    assert {:ok, waiting} = Todos.transition_workflow(todo.user_id, todo.id, attrs)
    assert Workflow.ball_label(Workflow.current(waiting)) == "Responder owns follow-up"
    Todos.review_waiting_workflows(todo.user_id, DateTime.utc_now())
    current = Todos.get_for_user(todo.user_id, todo.id)
    assert current.status == "open"
    assert Workflow.ball_label(Workflow.current(current)) == "Your move"
  end

  defp tracked_todo!(title, source) do
    user_id = "workflow-review-#{Ecto.UUID.generate()}@example.invalid"
    {:ok, _} = Accounts.get_or_create_user_by_email(user_id)
    person = Repo.insert!(%Person{user_id: user_id, display_name: "Responder"})

    todo =
      Repo.insert!(%Todo{
        user_id: user_id,
        owner_user_id: user_id,
        source: source,
        source_item_id:
          if(source == "gmail", do: "review-thread", else: "C-review:4000000000.000001"),
        source_occurred_at: ~U[2099-06-20 12:00:00.000000Z],
        kind: "general",
        title: title,
        summary: title,
        next_action: title,
        dedupe_key: Ecto.UUID.generate(),
        status: "open"
      })

    {:ok, todo} =
      Todos.transition_workflow(user_id, todo.id, %{
        "state" => "working",
        "owner" => %{"kind" => "user"},
        "expected_revision" => 0,
        "reason" => "The user started this outcome",
        "outcome" => title,
        "next_action" => title
      })

    {todo, person}
  end

  defp progress_resolution(todo, quote, state, owner, next) do
    %{
      "todo_id" => todo.id,
      "completed" => false,
      "confidence" => 0.99,
      "evidence_channel" => todo.source,
      "evidence_quote" => quote,
      "workflow_transition" => %{"state" => state, "owner" => owner, "next_action" => next}
    }
  end

  defp review(todo, evidence, decide) do
    {bundle, refs} = source_bundle(todo.source, evidence)

    CrossSourceCompletion.run_for_user(todo.user_id,
      now: DateTime.add(@now, 120),
      source_bundle: bundle,
      exact_source_delta: true,
      exhaustive_completion: true,
      todo_ids: [todo.id],
      source_item_refs: refs,
      llm_complete: fn prompt ->
        assert prompt =~ "completed work, workflow transitions and acknowledged_only replies"
        assert prompt =~ "workflow outcome describes is completion"
        [_, json] = Regex.run(~r/RECENT_ACTIVITY_JSON:\n([^\n]+)/, prompt)
        result = decide.(Jason.decode!(json))
        {:ok, %{content: Jason.encode!(%{"resolutions" => [result]})}}
      end
    )
  end

  defp source_bundle("gmail", evidence) do
    messages =
      Enum.with_index(evidence, fn {text, at}, index ->
        %{
          "message_id" => "evidence-#{index}",
          "thread_id" => "review-thread",
          "google_provider" => "google:gmail:review",
          "subject" => "Outcome progress",
          "from" => "responder@example.invalid",
          "body_text" => text,
          "internal_date" => DateTime.to_iso8601(at),
          "labels" => ["INBOX"]
        }
      end)

    bundle =
      SourceBundle.empty(%{timestamp: @now})
      |> SourceBundle.put_gmail(%{
        "status" => "ready",
        "fetched_at" => @now,
        "messages" => messages,
        "inbox_messages" => messages,
        "sent_messages" => []
      })

    {bundle, Enum.map(messages, &("gmail:google:gmail:review:" <> &1["message_id"]))}
  end

  defp source_bundle("slack", evidence) do
    messages =
      Enum.map(evidence, fn {text, at} ->
        %{
          "ts" => "#{DateTime.to_unix(at)}.000002",
          "thread_ts" => "4000000000.000001",
          "user" => "U-responder",
          "text" => text
        }
      end)

    bundle =
      SourceBundle.empty(%{timestamp: @now})
      |> SourceBundle.put_slack(%{
        "status" => "ready",
        "fetched_at" => @now,
        "workspaces" => [
          %{
            "team_id" => "T-review",
            "channels" => [%{"id" => "C-review", "messages" => messages}]
          }
        ]
      })

    {bundle, Enum.map(messages, &("slack:T-review:C-review:" <> &1["ts"]))}
  end
end
