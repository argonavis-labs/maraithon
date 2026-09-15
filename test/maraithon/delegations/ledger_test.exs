defmodule Maraithon.Delegations.LedgerTest do
  use Maraithon.DataCase, async: false
  alias Maraithon.{Accounts, OAuth, Repo}
  alias Maraithon.Delegations.{Delegation, GmailSource, Ledger, Policy, Toolbox}

  setup do
    user = "ledger-#{Ecto.UUID.generate()}@example.invalid"
    {:ok, _} = Accounts.get_or_create_user_by_email(user)

    {:ok, _} =
      OAuth.store_tokens(user, "google:ledger", %{
        access_token: "memory-mailbox",
        expires_in: 3600
      })

    account = Maraithon.ConnectedAccounts.get(user, "google:ledger")

    todo =
      Repo.insert!(%Maraithon.Todos.Todo{
        user_id: user,
        owner_user_id: user,
        title: "Remember the project details",
        summary: "Get the project colour and delivery date",
        source: "manual",
        next_action: "Ask",
        dedupe_key: Ecto.UUID.generate()
      })

    d =
      %Delegation{user_id: user}
      |> Delegation.changeset(%{
        todo_id: todo.id,
        connected_account_id: account.id,
        provider: "gmail",
        provider_thread_id: "aabbcc",
        state: "deciding",
        data: %{}
      })
      |> Repo.insert!()

    message = %{
      "message_id" => "aa11",
      "thread_id" => "aabbcc",
      "from" => "kent.fenwick@gmail.com",
      "to" => "kent@runner.now",
      "subject" => "Project details",
      "labels" => ["INBOX"],
      "internet_message_id" => "<colour@example.invalid>",
      "text_body" => "The project colour is indigo. Delivery is not decided yet.",
      "internal_date" => "2026-03-15T14:00:00Z"
    }

    {:ok, source} = GmailSource.snapshot([message], account.id, message["thread_id"])

    context = %{
      delegation: d,
      turn: %{source_revision: 0, wake_reason: "reply"},
      grant: %{
        data: %{
          "scope" => %{
            "identity" => %{"email" => "kent@runner.now"},
            "to" => ["kent.fenwick@gmail.com"],
            "cc" => []
          }
        }
      },
      run: %{prompt_snapshot: %{"sources" => source}}
    }

    decision = %{
      "kind" => "send",
      "body" => "What is the delivery date?",
      "reason" => "Ask for the remaining detail",
      "evidence" => [message["message_id"]],
      "facts" => [
        %{
          "key" => "project_colour",
          "text" => "The counterparty says the project colour is indigo.",
          "evidence" => [message["message_id"]]
        }
      ]
    }

    bypass = Bypass.open()
    old = Application.get_env(:maraithon, :gmail, [])
    Application.put_env(:maraithon, :gmail, api_base_url: "http://localhost:#{bypass.port}")
    on_exit(fn -> Application.put_env(:maraithon, :gmail, old) end)
    %{context: context, message: message, decision: decision, bypass: bypass}
  end

  test "a stored fact survives 180 days and a Gmail thread change, and only its cited source is read",
       c do
    later = later_context(c)
    decision = c.decision |> Map.put("kind", "complete") |> Map.put("facts", [])
    assert Ledger.prompt(later)["facts"]["project_colour"]["evidence"] == ["aa11"]
    refute Enum.any?(Ledger.messages(later), &(&1["message_id"] == "aa11"))
    serve(c, c.message)
    assert {:ok, [recalled]} = Toolbox.read(later, decision)
    assert recalled["reference"]["account_id"] == c.context.delegation.connected_account_id
    assert recalled["message"]["text_body"] == c.message["text_body"]

    later = put_in(later, [:run, :prompt_snapshot, "recalled_sources"], [recalled])
    assert {:ok, [^recalled]} = Toolbox.read(later, decision)
    assert {:ok, _} = Policy.validate(later, decision)
    [_, review] = Policy.messages(later, decision)
    data = Jason.decode!(review["content"])["context"]
    assert length(data["last_messages"]) == 6
    assert length(data["older_messages"]) == 1
    assert hd(data["older_messages"])["message_id"] == "aa11"

    refute Policy.approved?(decision, %{
             "allowed" => true,
             "reason" => "Not proven",
             "outcome_proven" => false
           })
  end

  test "current corrected facts replace the same key without losing other facts", c do
    {:ok, ledger} = Ledger.merge(c.context, c.decision, ~U[2026-03-15 14:01:00Z])
    ledger = put_in(ledger, ["facts", "other_detail"], ledger["facts"]["project_colour"])
    context = put_in(c.context, [:run, :prompt_snapshot, "fact_ledger"], ledger)

    context =
      put_in(
        context,
        [:run, :prompt_snapshot, "sources", "messages", Access.at(0), "text_body"],
        "Correction: the colour is violet."
      )

    decision =
      put_in(
        c.decision,
        ["facts", Access.at(0), "text"],
        "The counterparty corrected the colour to violet."
      )

    assert {:ok, updated} = Ledger.merge(context, decision, ~U[2026-09-15 14:01:00Z])
    assert updated["facts"]["other_detail"] == ledger["facts"]["other_detail"]
    assert updated["facts"]["project_colour"]["text"] =~ "violet"

    refute updated["facts"]["project_colour"]["evidence"] ==
             ledger["facts"]["project_colour"]["evidence"]

    assert c.context.grant == context.grant
  end

  test "unknown evidence, new destinations, drafts and self-authored claims cannot become memory",
       c do
    for decision <- [
          put_in(c.decision, ["facts", Access.at(0), "evidence"], ["fake"]),
          put_in(c.decision, ["facts", Access.at(0), "to"], "someone@example.invalid"),
          Map.put(c.decision, "forget_facts", ["missing"])
        ] do
      assert {:error, _} = Ledger.merge(c.context, decision, DateTime.utc_now())
    end

    for changed <- [
          %{"labels" => ["DRAFT"]},
          %{"from" => "kent@runner.now"},
          %{"cc" => "stranger@example.invalid"}
        ] do
      context =
        update_in(c.context, [:run, :prompt_snapshot, "sources", "messages"], fn [m] ->
          [Map.merge(m, changed)]
        end)

      assert {:error, :unverified_fact} = Ledger.merge(context, c.decision, DateTime.utc_now())
    end
  end

  test "older evidence cannot cross mailbox, thread or provider boundaries", c do
    later = later_context(c)
    decision = Map.put(c.decision, "facts", [])

    for changed <- [
          %{"account_id" => 999_999},
          %{"thread_id" => "ffffee"},
          %{"provider" => "slack"}
        ] do
      context =
        update_in(
          later,
          [:run, :prompt_snapshot, "fact_ledger", "facts", "project_colour", "evidence"],
          fn [ref] -> [Map.merge(ref, changed)] end
        )

      assert {:error, :recalled_evidence_changed} = Toolbox.read(context, decision)
    end

    assert {:error, :unverified_evidence} =
             Toolbox.read(later, %{decision | "evidence" => ["unknown"]})
  end

  test "changed original evidence cannot pass recall or the final send check", c do
    later = later_context(c)
    decision = Map.put(c.decision, "facts", [])
    serve(c, c.message)
    assert {:ok, recalled} = Toolbox.read(later, decision)
    later = put_in(later, [:run, :prompt_snapshot, "recalled_sources"], recalled)
    serve(c, Map.put(c.message, "text_body", "The colour is now violet."))
    assert {:error, :recalled_evidence_changed} = Toolbox.verify_before_send(later)
  end

  test "an ID in another mailbox cannot masquerade as a current message", c do
    {:ok, ledger} = Ledger.merge(c.context, c.decision, DateTime.utc_now())

    ledger =
      update_in(ledger, ["facts", "project_colour", "evidence"], fn [ref] ->
        [Map.put(ref, "account_id", ref["account_id"] + 1)]
      end)

    context = put_in(c.context, [:run, :prompt_snapshot, "fact_ledger"], ledger)
    assert {:error, :unverified_evidence} = Toolbox.read(context, c.decision)
  end

  test "facts not cited by the current decision cause no history reads", c do
    later = later_context(c)
    assert {:ok, []} = Toolbox.read(later, %{"evidence" => [], "facts" => []})

    Bypass.expect_once(c.bypass, "GET", "/users/me/messages/aa11", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(404, ~s({"error":"not found"}))
    end)

    assert {:error, _} = Toolbox.read(later, Map.put(c.decision, "facts", []))
  end

  test "mailbox labels do not invalidate unchanged evidence", c do
    later = later_context(c)
    serve(c, Map.put(c.message, "labels", ["IMPORTANT"]))
    assert {:ok, [_]} = Toolbox.read(later, Map.put(c.decision, "facts", []))
  end

  test "memory stays bounded without truncating facts or discarding them silently", c do
    {:ok, ledger} = Ledger.merge(c.context, c.decision, DateTime.utc_now())
    fact = Map.put(ledger["facts"]["project_colour"], "text", String.duplicate("a", 800))
    facts = Map.new(1..32, &{"fact_#{&1}", fact})
    context = put_in(c.context, [:run, :prompt_snapshot, "fact_ledger"], %{"facts" => facts})
    assert {:error, :fact_ledger_full} = Ledger.merge(context, c.decision, DateTime.utc_now())
    refute Ledger.valid_storage?(%{"facts" => String.duplicate("a", 32_769)})

    changeset =
      Delegation.changeset(c.context.delegation, %{
        data: %{"ledger" => %{"oversized" => String.duplicate("a", 33_000)}}
      })

    refute changeset.valid?
    assert length(c.decision["facts"]) == 1
  end

  test "forgetting is explicit and can be reviewed alongside a replacement", c do
    {:ok, ledger} = Ledger.merge(c.context, c.decision, DateTime.utc_now())
    context = put_in(c.context, [:run, :prompt_snapshot, "fact_ledger"], ledger)
    decision = c.decision |> Map.put("facts", []) |> Map.put("forget_facts", ["project_colour"])
    assert {:ok, %{"facts" => %{}}} = Ledger.merge(context, decision, DateTime.utc_now())

    assert {:error, :invalid_fact_update} =
             Ledger.merge(
               context,
               Map.put(c.decision, "forget_facts", ["project_colour"]),
               DateTime.utc_now()
             )
  end

  defp later_context(c) do
    {:ok, ledger} = Ledger.merge(c.context, c.decision, ~U[2026-03-15 14:01:00Z])

    d =
      c.context.delegation
      |> Delegation.changeset(%{
        provider_thread_id: "ddeeff",
        data: %{"gmail_threads" => ["aabbcc", "ddeeff"], "ledger" => ledger}
      })
      |> Repo.update!()

    d = Repo.get!(Delegation, d.id) |> Delegation.hydrate()

    messages =
      for n <- 1..6,
          do:
            Map.merge(c.message, %{
              "message_id" => "bb#{n}",
              "thread_id" => "ddeeff",
              "text_body" => "Delivery discussion #{n}",
              "internal_date" => "2026-09-15T14:00:0#{n}Z"
            })

    {:ok, source} = GmailSource.snapshot(messages, d.connected_account_id, "ddeeff")

    %{
      c.context
      | delegation: d,
        run: %{prompt_snapshot: %{"sources" => source, "fact_ledger" => d.data["ledger"]}}
    }
  end

  defp serve(c, message) do
    Bypass.expect_once(c.bypass, "GET", "/users/me/messages/#{message["message_id"]}", fn conn ->
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer memory-mailbox"]
      {:ok, date, _} = DateTime.from_iso8601(message["internal_date"])

      raw = %{
        "id" => message["message_id"],
        "threadId" => message["thread_id"],
        "labelIds" => message["labels"],
        "internalDate" => Integer.to_string(DateTime.to_unix(date, :millisecond)),
        "payload" => %{
          "mimeType" => "text/plain",
          "headers" => [
            %{"name" => "From", "value" => message["from"]},
            %{"name" => "To", "value" => message["to"]},
            %{"name" => "Subject", "value" => message["subject"]},
            %{"name" => "Message-ID", "value" => message["internet_message_id"]}
          ],
          "body" => %{"data" => Base.url_encode64(message["text_body"], padding: false)}
        }
      }

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(raw))
    end)
  end
end
