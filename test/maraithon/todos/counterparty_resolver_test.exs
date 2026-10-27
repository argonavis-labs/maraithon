defmodule Maraithon.Todos.CounterpartyResolverTest do
  use Maraithon.DataCase, async: true

  alias Maraithon.Accounts
  alias Maraithon.Crm
  alias Maraithon.Todos
  alias Maraithon.Todos.CounterpartyBackfill
  alias Maraithon.Todos.CounterpartyResolver

  setup do
    user_id = "counterparty-#{System.unique_integer([:positive])}@example.com"
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)
    %{user_id: user_id}
  end

  describe "resolve_person/3" do
    test "resolves an exact single-candidate label", %{user_id: user_id} do
      {:ok, charlie} = Crm.create_person(user_id, %{"display_name" => "Charlie Ndegwa"})
      {:ok, _other} = Crm.create_person(user_id, %{"display_name" => "Dana Lang"})

      assert {:ok, person} = CounterpartyResolver.resolve_person(user_id, "Charlie")
      assert person.id == charlie.id

      assert {:ok, person} = CounterpartyResolver.resolve_person(user_id, "Charlie Ndegwa")
      assert person.id == charlie.id
    end

    test "two name-compatible candidates return :ambiguous", %{user_id: user_id} do
      {:ok, _one} = Crm.create_person(user_id, %{"display_name" => "Sam Altieri"})
      {:ok, _two} = Crm.create_person(user_id, %{"display_name" => "Sam Bourke"})

      assert CounterpartyResolver.resolve_person(user_id, "Sam") == :ambiguous
    end

    test "zero candidates return :not_found", %{user_id: user_id} do
      {:ok, _person} = Crm.create_person(user_id, %{"display_name" => "Dana Lang"})

      assert CounterpartyResolver.resolve_person(user_id, "Zebulon") == :not_found
    end

    test "never falls back to the first result on incompatible names", %{user_id: user_id} do
      # list_people's substring search would match "Dan" against notes or
      # contact details of unrelated people; the name-compatibility filter
      # must reject those instead of picking the first row.
      {:ok, _person} =
        Crm.create_person(user_id, %{
          "display_name" => "Priya Patel",
          "notes" => "Introduced by Dan at the runner meetup."
        })

      assert CounterpartyResolver.resolve_person(user_id, "Dan") == :not_found
    end

    test "merged people are excluded from candidates", %{user_id: user_id} do
      {:ok, survivor} = Crm.create_person(user_id, %{"display_name" => "Dan Bourke"})
      {:ok, duplicate} = Crm.create_person(user_id, %{"display_name" => "Dan Bourke Jr"})

      assert CounterpartyResolver.resolve_person(user_id, "Dan") == :ambiguous

      {:ok, _result} = Crm.merge_people(user_id, survivor.id, duplicate.id)

      assert {:ok, person} = CounterpartyResolver.resolve_person(user_id, "Dan")
      assert person.id == survivor.id
    end
  end

  describe "upsert-time counterparty resolution (SPEC 04 R2/R2a/R3)" do
    test "a todo written with a single-match label gets the FK stamped", %{user_id: user_id} do
      {:ok, charlie} = Crm.create_person(user_id, %{"display_name" => "Charlie Ndegwa"})

      {:ok, [todo]} =
        Todos.upsert_many(user_id, [
          owed_todo_attrs("thread-owe-charlie", "Send Charlie the deck",
            direction: "owed_by_me",
            counterparty_label: "Charlie"
          )
        ])

      assert todo.counterparty_person_id == charlie.id
      assert todo.counterparty_label == "Charlie"
    end

    test "an ambiguous label leaves the FK nil", %{user_id: user_id} do
      {:ok, _one} = Crm.create_person(user_id, %{"display_name" => "Sam Altieri"})
      {:ok, _two} = Crm.create_person(user_id, %{"display_name" => "Sam Bourke"})

      {:ok, [todo]} =
        Todos.upsert_many(user_id, [
          owed_todo_attrs("thread-owe-sam", "Send Sam the notes",
            direction: "owed_by_me",
            counterparty_label: "Sam"
          )
        ])

      assert is_nil(todo.counterparty_person_id)
      assert todo.counterparty_label == "Sam"
    end

    test "an explicit counterparty_person_id always wins over the resolver", %{user_id: user_id} do
      {:ok, _charlie} = Crm.create_person(user_id, %{"display_name" => "Charlie Ndegwa"})
      {:ok, pinned} = Crm.create_person(user_id, %{"display_name" => "Priya Patel"})

      {:ok, [todo]} =
        Todos.upsert_many(user_id, [
          owed_todo_attrs("thread-owe-explicit", "Send Charlie the deck",
            direction: "owed_by_me",
            counterparty_label: "Charlie",
            counterparty_person_id: pinned.id
          )
        ])

      assert todo.counterparty_person_id == pinned.id
    end

    test "re-upsert does not clobber a human-set FK", %{user_id: user_id} do
      {:ok, _charlie} = Crm.create_person(user_id, %{"display_name" => "Charlie Ndegwa"})
      {:ok, pinned} = Crm.create_person(user_id, %{"display_name" => "Priya Patel"})

      {:ok, [todo]} =
        Todos.upsert_many(user_id, [
          owed_todo_attrs("thread-owe-keep", "Send Charlie the deck",
            direction: "owed_by_me",
            counterparty_label: "Charlie",
            counterparty_person_id: pinned.id
          )
        ])

      assert todo.counterparty_person_id == pinned.id

      # Webhook redelivery of the same item, this time without the explicit
      # FK attr: the resolver would pick Charlie, but the existing value must
      # be preserved.
      {:ok, [reupserted]} =
        Todos.upsert_many(user_id, [
          owed_todo_attrs("thread-owe-keep", "Send Charlie the deck",
            direction: "owed_by_me",
            counterparty_label: "Charlie"
          )
        ])

      assert reupserted.id == todo.id
      assert reupserted.counterparty_person_id == pinned.id
    end

    test "a later re-upsert may flip :not_found to resolved once the person exists", %{
      user_id: user_id
    } do
      {:ok, [todo]} =
        Todos.upsert_many(user_id, [
          owed_todo_attrs("thread-owe-late", "Send Charlie the deck",
            direction: "owed_by_me",
            counterparty_label: "Charlie"
          )
        ])

      assert is_nil(todo.counterparty_person_id)

      {:ok, charlie} = Crm.create_person(user_id, %{"display_name" => "Charlie Ndegwa"})

      {:ok, [reupserted]} =
        Todos.upsert_many(user_id, [
          owed_todo_attrs("thread-owe-late", "Send Charlie the deck",
            direction: "owed_by_me",
            counterparty_label: "Charlie"
          )
        ])

      assert reupserted.id == todo.id
      assert reupserted.counterparty_person_id == charlie.id
    end

    test "fyi todos are not resolved", %{user_id: user_id} do
      {:ok, _charlie} = Crm.create_person(user_id, %{"display_name" => "Charlie Ndegwa"})

      {:ok, [todo]} =
        Todos.upsert_many(user_id, [
          owed_todo_attrs("thread-fyi", "FYI about Charlie",
            direction: "fyi",
            counterparty_label: "Charlie"
          )
        ])

      assert is_nil(todo.counterparty_person_id)
    end
  end

  describe "list_owed_by_me/list_owed_to_me person filter (SPEC 04 R4)" do
    test "person_id scopes owed items to one counterparty", %{user_id: user_id} do
      {:ok, charlie} = Crm.create_person(user_id, %{"display_name" => "Charlie Ndegwa"})
      {:ok, dana} = Crm.create_person(user_id, %{"display_name" => "Dana Lang"})

      {:ok, _todos} =
        Todos.upsert_many(user_id, [
          owed_todo_attrs("thread-owe-1", "Send Charlie the deck",
            direction: "owed_by_me",
            counterparty_label: "Charlie"
          ),
          owed_todo_attrs("thread-owe-2", "Send Dana the invoice",
            direction: "owed_by_me",
            counterparty_label: "Dana"
          ),
          owed_todo_attrs("thread-wait-1", "Waiting on Charlie's numbers",
            direction: "owed_to_me",
            counterparty_label: "Charlie"
          )
        ])

      all_owed = Todos.list_owed_by_me(user_id)
      assert length(all_owed) == 2

      charlie_owed = Todos.list_owed_by_me(user_id, person_id: charlie.id)
      assert [%{title: "Send Charlie the deck"}] = charlie_owed
      assert hd(charlie_owed).counterparty_person_id == charlie.id

      dana_owed = Todos.list_owed_by_me(user_id, counterparty_person_id: dana.id)
      assert [%{title: "Send Dana the invoice"}] = dana_owed

      charlie_waiting = Todos.list_owed_to_me(user_id, person_id: charlie.id)
      assert [%{title: "Waiting on Charlie's numbers"}] = charlie_waiting
    end

    test "snapshot threads person_id through to the owed query (SPEC 04 R5)", %{
      user_id: user_id
    } do
      {:ok, charlie} = Crm.create_person(user_id, %{"display_name" => "Charlie Ndegwa"})
      {:ok, _dana} = Crm.create_person(user_id, %{"display_name" => "Dana Lang"})

      {:ok, _todos} =
        Todos.upsert_many(user_id, [
          owed_todo_attrs("thread-snap-1", "Send Charlie the deck",
            direction: "owed_by_me",
            counterparty_label: "Charlie"
          ),
          owed_todo_attrs("thread-snap-2", "Send Dana the invoice",
            direction: "owed_by_me",
            counterparty_label: "Dana"
          )
        ])

      unfiltered = Maraithon.OpenLoops.snapshot(user_id, direction: "owed_by_me")

      filtered =
        Maraithon.OpenLoops.snapshot(user_id, direction: "owed_by_me", person_id: charlie.id)

      assert unfiltered.totals.open_todos == 2
      assert filtered.totals.open_todos == 1
    end
  end

  describe "CounterpartyBackfill (SPEC 04 R6/R6a)" do
    test "deterministically resolves label-only rows and stamps markers", %{user_id: user_id} do
      {:ok, charlie} = Crm.create_person(user_id, %{"display_name" => "Charlie Ndegwa"})

      {:ok, [todo]} = Todos.upsert_many(user_id, [legacy_label_only_attrs("bf-1", "Charlie")])
      assert is_nil(todo.counterparty_person_id)

      assert {:ok, summary} = CounterpartyBackfill.run(user_id, model_pass?: false)
      assert summary.resolved_deterministic == 1

      resolved = Todos.get_for_user(user_id, todo.id)
      assert resolved.counterparty_person_id == charlie.id
      assert %{"result" => "resolved"} = resolved.metadata["counterparty_resolution"]
    end

    test "marks not_found rows and does not re-escalate unchanged ambiguous rows", %{
      user_id: user_id
    } do
      {:ok, _one} = Crm.create_person(user_id, %{"display_name" => "Sam Altieri"})
      {:ok, _two} = Crm.create_person(user_id, %{"display_name" => "Sam Bourke"})

      {:ok, [ambiguous_todo]} =
        Todos.upsert_many(user_id, [legacy_label_only_attrs("bf-ambig", "Sam")])

      {:ok, [missing_todo]} =
        Todos.upsert_many(user_id, [legacy_label_only_attrs("bf-missing", "Zebulon")])

      llm_calls = :counters.new(1, [])

      unsure_llm = fn _params ->
        :counters.add(llm_calls, 1, 1)
        {:ok, %{content: ~s({"resolutions": []})}}
      end

      assert {:ok, first} = CounterpartyBackfill.run(user_id, llm_complete: unsure_llm)
      assert first.ambiguous_unresolved == 1
      assert first.not_found == 1
      assert :counters.get(llm_calls, 1) == 1

      marked = Todos.get_for_user(user_id, ambiguous_todo.id)
      assert %{"result" => "ambiguous_unresolved"} = marked.metadata["counterparty_resolution"]

      missing = Todos.get_for_user(user_id, missing_todo.id)
      assert %{"result" => "not_found"} = missing.metadata["counterparty_resolution"]

      # Second run with an unchanged candidate set: the deterministic pass
      # reruns (cheap), but the model must NOT be called again for the same
      # permanently-ambiguous "Sam".
      assert {:ok, second} = CounterpartyBackfill.run(user_id, llm_complete: unsure_llm)
      assert second.skipped_unchanged_ambiguous == 1
      assert :counters.get(llm_calls, 1) == 1
    end

    test "model-gated pass resolves an ambiguous row on a single confident pick", %{
      user_id: user_id
    } do
      {:ok, sam_a} = Crm.create_person(user_id, %{"display_name" => "Sam Altieri"})
      {:ok, _sam_b} = Crm.create_person(user_id, %{"display_name" => "Sam Bourke"})

      {:ok, [todo]} = Todos.upsert_many(user_id, [legacy_label_only_attrs("bf-model", "Sam")])

      confident_llm = fn params ->
        content = get_in(params, ["messages", Access.at(0), "content"])
        assert content =~ "COUNTERPARTY_RESOLUTION_JSON_V1"
        assert content =~ sam_a.id

        {:ok,
         %{
           content:
             Jason.encode!(%{
               "resolutions" => [
                 %{"todo_id" => todo.id, "person_id" => sam_a.id, "confidence" => 0.9}
               ]
             })
         }}
      end

      assert {:ok, summary} = CounterpartyBackfill.run(user_id, llm_complete: confident_llm)
      assert summary.resolved_model == 1

      resolved = Todos.get_for_user(user_id, todo.id)
      assert resolved.counterparty_person_id == sam_a.id

      assert %{"result" => "resolved", "resolved_by" => "model"} =
               resolved.metadata["counterparty_resolution"]
    end

    test "a low-confidence or out-of-candidate-set pick never stamps the FK", %{
      user_id: user_id
    } do
      {:ok, sam_a} = Crm.create_person(user_id, %{"display_name" => "Sam Altieri"})
      {:ok, _sam_b} = Crm.create_person(user_id, %{"display_name" => "Sam Bourke"})
      {:ok, outsider} = Crm.create_person(user_id, %{"display_name" => "Priya Patel"})

      {:ok, [low_todo]} = Todos.upsert_many(user_id, [legacy_label_only_attrs("bf-low", "Sam")])

      low_llm = fn _params ->
        {:ok,
         %{
           content:
             Jason.encode!(%{
               "resolutions" => [
                 %{"todo_id" => low_todo.id, "person_id" => sam_a.id, "confidence" => 0.4}
               ]
             })
         }}
      end

      assert {:ok, summary} = CounterpartyBackfill.run(user_id, llm_complete: low_llm)
      assert summary.resolved_model == 0
      assert is_nil(Todos.get_for_user(user_id, low_todo.id).counterparty_person_id)

      {:ok, [rogue_todo]} =
        Todos.upsert_many(user_id, [legacy_label_only_attrs("bf-rogue", "Sam")])

      # The out-of-set person id is confidently picked, but it is not one of
      # the label's candidates so it must be discarded. A fresh person makes
      # the candidate-set-changed check re-escalate the previously marked
      # rows too, so scope the assertion to the rogue todo.
      rogue_llm = fn _params ->
        {:ok,
         %{
           content:
             Jason.encode!(%{
               "resolutions" => [
                 %{"todo_id" => rogue_todo.id, "person_id" => outsider.id, "confidence" => 0.95}
               ]
             })
         }}
      end

      assert {:ok, _summary} = CounterpartyBackfill.run(user_id, llm_complete: rogue_llm)
      assert is_nil(Todos.get_for_user(user_id, rogue_todo.id).counterparty_person_id)
    end
  end

  defp owed_todo_attrs(thread_id, title, overrides) do
    defaults = %{
      "source" => "gmail",
      "kind" => "gmail_triage",
      "title" => title,
      "summary" => "Open loop with a counterparty.",
      "next_action" => "Close the loop.",
      "priority" => 70,
      "source_item_id" => thread_id,
      "dedupe_key" => "gmail:gmail_triage:#{thread_id}",
      "metadata" => %{"thread_id" => thread_id}
    }

    overrides
    |> Map.new(fn {key, value} -> {to_string(key), value} end)
    |> then(&Map.merge(defaults, &1))
  end

  defp legacy_label_only_attrs(thread_id, label) do
    # Rows the SPEC 05 writers created before SPEC 04: label present, FK nil.
    # counterparty_person_id is explicitly nil'd via a direction the resolver
    # skips at write time — the backfill is what should resolve them.
    owed_todo_attrs(thread_id, "Owed item for #{label}",
      direction: "owed_by_me",
      counterparty_label: label,
      counterparty_person_id: nil
    )
  end
end
