defmodule Maraithon.Delegations.ProposalsTest do
  use Maraithon.DataCase, async: false
  require Phoenix.LiveViewTest
  alias Maraithon.{Accounts, Insights, Repo}
  alias Maraithon.Behaviors.AIChiefOfStaff
  alias Maraithon.ChiefOfStaff.Skills.DelegationProposals, as: Proposals
  alias Maraithon.Delegations.{AssistantIdentity, Delegation, Preferences, Reports}
  alias Maraithon.Todos.Todo

  setup do
    user = "proposals-#{Ecto.UUID.generate()}@example.invalid"
    {:ok, _} = Accounts.get_or_create_user_by_email(user)

    {:ok, agent} =
      Maraithon.Agents.create_agent(%{user_id: user, behavior: "prompt_agent", config: %{}})

    flags = %{
      delegations_enabled: true,
      delegation_user_allowlist: [user],
      delegation_sends_enabled: %{gmail: true, slack: true},
      delegation_eval_only: false
    }

    old = Map.new(flags, fn {key, _} -> {key, Application.get_env(:maraithon, key)} end)
    Enum.each(flags, fn {key, value} -> Application.put_env(:maraithon, key, value) end)

    on_exit(fn ->
      Enum.each(old, fn {key, value} -> Application.put_env(:maraithon, key, value) end)
      Maraithon.ChiefOfStaff.Skills.clear_process_override()
    end)

    account =
      Repo.insert!(%Maraithon.Accounts.ConnectedAccount{
        user_id: user,
        provider: "google:#{user}",
        external_account_id: user,
        status: "connected"
      })

    person = Repo.insert!(%Maraithon.Crm.Person{user_id: user, display_name: "Laura"})

    todo =
      Repo.insert!(%Todo{
        user_id: user,
        owner_user_id: user,
        source: "gmail",
        source_account_id: account.id,
        source_item_id: "abc123",
        counterparty_person_id: person.id,
        title: "Get the delivery date",
        summary: "Laura is arranging delivery for order 4471.",
        next_action: "Ask Laura for the delivery date.",
        dedupe_key: Ecto.UUID.generate()
      })

    source =
      Repo.insert!(%Maraithon.Crm.Observation{
        user_id: user,
        source: "gmail",
        source_account: user,
        source_item_id: "#{account.provider}:abc123",
        direction: "inbound",
        subject: "Delivery",
        excerpt: "Ask me for an updated delivery date.",
        occurred_at: DateTime.utc_now(),
        resolved_person_ids: [person.id],
        participants: [%{"role" => "from", "identifier" => %{"email" => "laura@example.invalid"}}],
        metadata: %{
          "connected_account_id" => account.id,
          "google_provider" => account.provider,
          "thread_id" => "abcdef",
          "labels" => ["INBOX"]
        }
      })

    %{
      user: user,
      todo: todo,
      account: account,
      person: person,
      source: source,
      context: %{user_id: user, agent_id: agent.id, timestamp: DateTime.utc_now()}
    }
  end

  test "one memo ranks a sourced task, creates no duplicate todo, and never delegates", c do
    Maraithon.ChiefOfStaff.Skills.put_process_override(
      skill_modules: %{
        "alpha" => Maraithon.TestSupport.ChiefOfStaffTestSkill
      },
      default_enabled_ids: ["alpha"]
    )

    state = AIChiefOfStaff.init(%{"user_id" => c.user})

    context =
      Map.merge(c.context, %{
        budget: %{llm_calls: 10, tool_calls: 10},
        recent_events: [],
        last_message: nil,
        last_message_metadata: %{},
        last_message_id: nil,
        trigger: nil,
        event: nil
      })

    assert {:effect, {:llm_call, params}, state} = cycle(state, context)
    assert state.pending_effect_skill_id == :cycle_memo
    assert hd(params["messages"])["content"] =~ c.todo.id
    assert length(state.delegation_candidates) == 1

    response = %{
      "content" =>
        Jason.encode!(%{
          "memo" => "Ask Laura for delivery timing.",
          "delegation_proposals" => [decision(c)]
        })
    }

    assert {:emit, {:insights_recorded, payload}, next} =
             AIChiefOfStaff.handle_effect_result({:llm_call, response}, state, context)

    assert payload["count"] == 1

    assert Enum.any?(
             payload["assistant_attention_plan"]["skills"],
             &(&1["skill_id"] == "delegation_proposals")
           )

    assert next.cycle_memory["memo"] == "Ask Laura for delivery timing."
    assert next.delegation_candidates == []
    assert Repo.aggregate(Todo, :count) == 1
    assert Repo.aggregate(Delegation, :count) == 0
    assert Proposals.current(Repo.get!(Todo, c.todo.id))["actor"] == "as_user"
    assert {:idle, _} = cycle(next, context)
  end

  test "another person's work, unverified people, drafts, and changed mailbox are ineligible",
       c do
    assert [_] = Proposals.candidates(c.user)

    for changes <- [
          %{
            workflow: %{
              "state" => "they_own",
              "owner" => %{"kind" => "person", "id" => c.person.id}
            }
          },
          %{next_action: "Record a video explaining the design"},
          %{counterparty_person_id: nil}
        ] do
      Repo.update!(Ecto.Changeset.change(c.todo, changes))
      assert [] = Proposals.candidates(c.user)

      Repo.update!(
        Ecto.Changeset.change(
          Repo.get!(Todo, c.todo.id),
          Map.take(Map.from_struct(c.todo), Map.keys(changes))
        )
      )
    end

    for metadata <- [
          Map.put(c.source.metadata, "labels", ["DRAFT"]),
          Map.put(c.source.metadata, "connected_account_id", c.account.id + 999)
        ] do
      Repo.update!(Ecto.Changeset.change(c.source, metadata: metadata))
      assert [] = Proposals.candidates(c.user)
    end
  end

  test "the assistant's name and scheduling kind survive the public projection", c do
    %AssistantIdentity{user_id: c.user}
    |> AssistantIdentity.changeset(%{
      gmail_connected_account_id: c.account.id,
      gmail_mode: "alias",
      data: %{"display_name" => "October", "gmail_send_as_email" => "october@example.invalid"}
    })
    |> Repo.insert!()

    todo =
      Repo.update!(
        Ecto.Changeset.change(c.todo, next_action: "Offer three times for a meeting with Laura")
      )

    [candidate] = candidates = Proposals.candidates(c.user)
    assert candidate["kind"] == "scheduling"
    assert candidate["actor"] == "as_assistant"
    assert [_] = Proposals.persist(candidates, [decision(c)], c.context)
    json = MaraithonWeb.MobileJSON.todo(Repo.get!(Todo, todo.id))
    assert json.delegation_proposal["label"] == "Delegate to October?"
    assert json.delegation_proposal["kind"] == "scheduling"
    card = Maraithon.ActionCards.for_todo(Repo.get!(Todo, todo.id))
    assert "delegate" in card["available_buttons"]
    assert card["primary_action"]["actor"] == "as_assistant"
  end

  test "a replay cannot duplicate a suggestion, and dismissing it leaves the task open", c do
    candidates = Proposals.candidates(c.user)
    assert [insight] = Proposals.persist(candidates, [decision(c)], c.context)
    assert [] = Proposals.persist(candidates, [decision(c)], c.context)
    assert [] = Proposals.candidates(c.user)
    assert {:ok, _} = Insights.dismiss(c.user, insight.id)
    assert Repo.get!(Todo, c.todo.id).status == "open"
    assert Proposals.current(Repo.get!(Todo, c.todo.id)) == nil
    assert [] = Proposals.candidates(c.user)
  end

  test "task changes while the memo runs cannot publish an old proposal", c do
    candidates = Proposals.candidates(c.user)

    Repo.update!(
      Ecto.Changeset.change(c.todo, next_action: "I must decide on the delivery contract")
    )

    assert [] = Proposals.persist(candidates, [decision(c)], c.context)
    assert Repo.aggregate(Maraithon.Insights.Insight, :count) == 0
  end

  test "source edits and disconnected accounts invalidate a pending memo", c do
    candidates = Proposals.candidates(c.user)
    Repo.update!(Ecto.Changeset.change(c.source, excerpt: "The delivery has been cancelled."))
    assert [] = Proposals.persist(candidates, [decision(c)], c.context)

    candidates = Proposals.candidates(c.user)
    Repo.update!(Ecto.Changeset.change(c.account, status: "disconnected"))
    assert [] = Proposals.persist(candidates, [decision(c)], c.context)
    assert Repo.aggregate(Maraithon.Insights.Insight, :count) == 0
  end

  test "Slack needs the exact workspace and channel and still respects eval-only mode", c do
    account = Repo.update!(Ecto.Changeset.change(c.account, provider: "slack:T123:U456"))

    todo =
      Repo.update!(
        Ecto.Changeset.change(c.todo,
          source: "slack",
          source_item_id: "C123:123.456",
          metadata: %{"team_id" => "T123"}
        )
      )

    Repo.update!(
      Ecto.Changeset.change(c.source,
        source: "slack",
        source_item_id: "T123:C123:123.456",
        metadata: %{"team_id" => "T123", "channel" => "C123", "ts" => "123.456"}
      )
    )

    assert [%{"todo_id" => id}] = Proposals.candidates(c.user)
    assert id == todo.id

    Application.put_env(:maraithon, :delegation_eval_only, true)
    assert [] = Proposals.candidates(c.user)
    Application.put_env(:maraithon, :delegation_eval_only, false)
    Repo.update!(Ecto.Changeset.change(account, provider: "slack:T_OTHER:U456"))
    assert [] = Proposals.candidates(c.user)
  end

  test "copy polishing preserves a suggestion, but another insight cannot stand in for it", c do
    Repo.update!(Ecto.Changeset.change(c.todo, summary: "Summary: Laura is arranging delivery."))
    assert [insight] = Proposals.persist(Proposals.candidates(c.user), [decision(c)], c.context)
    todo = Maraithon.Todos.get_for_user(c.user, c.todo.id)
    refute todo.summary =~ "Summary:"
    assert Proposals.current(todo)
    assert Proposals.insight_current?(insight)

    html =
      Phoenix.LiveViewTest.render_component(MaraithonWeb.DelegationPanel,
        id: "delegation-#{todo.id}",
        todo: todo
      )

    assert html =~ "Delegate to Maraithon?"
    assert html =~ decision(c)["reason"]

    Repo.update!(Ecto.Changeset.change(insight, source_id: Ecto.UUID.generate()))
    assert Proposals.current(todo) == nil
  end

  test "the next review expires a suggestion in task, insight and brief projections", c do
    assert [_] = Proposals.persist(Proposals.candidates(c.user), [decision(c)], c.context)
    now = DateTime.utc_now()
    assert Reports.section(Reports.brief(c.user, now, now)) =~ "Delegation suggestions:"

    todo =
      Repo.get!(Todo, c.todo.id)
      |> Ecto.Changeset.change(last_completion_checked_at: DateTime.truncate(now, :second))
      |> Repo.update!()

    assert Proposals.current(todo) == nil
    assert Insights.list_open_for_user(c.user) == []
    assert Proposals.brief(c.user) == []
  end

  test "preference and rollout gates apply to generation and display", c do
    assert [_] = Proposals.persist(Proposals.candidates(c.user), [decision(c)], c.context)
    assert {:ok, _} = Preferences.put(c.user, %{"proposals_enabled" => false})
    assert Proposals.candidates(c.user) == []
    assert Proposals.current(Repo.get!(Todo, c.todo.id)) == nil
    assert {:ok, _} = Preferences.put(c.user, %{"proposals_enabled" => true})
    Application.put_env(:maraithon, :delegation_sends_enabled, %{gmail: false, slack: false})
    assert Proposals.current(Repo.get!(Todo, c.todo.id)) == nil
  end

  test "unknown IDs and malformed rankings cannot write a proposal", c do
    candidates = Proposals.candidates(c.user)

    assert [] =
             Proposals.persist(
               candidates,
               [nil, %{"todo_id" => Ecto.UUID.generate(), "reason" => "yes"}],
               c.context
             )

    assert [] =
             Proposals.persist(
               candidates,
               [%{"todo_id" => c.todo.id, "reason" => ["wrong"]}],
               c.context
             )

    assert Repo.aggregate(Maraithon.Insights.Insight, :count) == 0
  end

  defp cycle(state, context) do
    case AIChiefOfStaff.handle_wakeup(state, context) do
      {:continue, next} -> cycle(next, context)
      result -> result
    end
  end

  defp decision(c),
    do: %{
      "todo_id" => c.todo.id,
      "reason" => "The delivery date can be obtained directly from Laura."
    }
end
