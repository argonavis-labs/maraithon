defmodule Maraithon.TelegramAssistant.ActionReconciliationTest do
  use Maraithon.DataCase, async: false

  alias Maraithon.{Accounts, AssistantChat, ConnectedAccounts, TelegramAssistant}
  alias Maraithon.AssistantChat.Execution
  alias Maraithon.TelegramAssistant.{ActionReconciliation, PreparedAction, Runner}
  alias Maraithon.Runtime.BackgroundJob
  alias Maraithon.TodoBrowser.Command

  setup do
    original = Application.get_env(:maraithon, :telegram_assistant, [])
    reconciliation = Application.get_env(:maraithon, ActionReconciliation, [])

    Application.put_env(
      :maraithon,
      :telegram_assistant,
      Keyword.put(
        original,
        :prepared_action_executor,
        Maraithon.TestSupport.ActionReconciliationExecutor
      )
    )

    on_exit(fn ->
      Application.put_env(:maraithon, :telegram_assistant, original)
      Application.put_env(:maraithon, ActionReconciliation, reconciliation)
      Application.delete_env(:maraithon, :action_reconciliation_executor)
    end)

    user_id = "reconciliation-#{System.unique_integer([:positive])}@example.com"
    {:ok, _} = Accounts.get_or_create_user_by_email(user_id)

    {:ok, account} =
      ConnectedAccounts.upsert_manual(user_id, "google", %{
        external_account_id: "controlled-mailbox"
      })

    {:ok, conversation} =
      AssistantChat.create_thread(user_id, %{"title" => "Controlled action recovery"})

    {:ok, run} =
      TelegramAssistant.start_run(%{
        user_id: user_id,
        chat_id: conversation.chat_id,
        surface: "mobile",
        conversation_id: conversation.id,
        trigger_type: "inbound_message",
        status: "completed",
        started_at: DateTime.utc_now(),
        model_provider: "test",
        model_name: "test",
        prompt_snapshot: %{},
        result_summary: %{}
      })

    pid = self()

    executor(fn action ->
      send(pid, {:provider_entered, action.id})
      {:error, :timeout}
    end)

    %{user_id: user_id, account: account, conversation: conversation, run: run}
  end

  test "lost Gmail response settles from exact Sent evidence without a second send", ctx do
    action = unknown(ctx)
    assert_received {:provider_entered, _}
    identity = action.payload["_maraithon_reconciliation_identity"]
    assert identity["account_id"] == ctx.account.id
    assert identity["message_id"] == "<maraithon.#{action.id}@maraithon.com>"

    job =
      Repo.get_by!(BackgroundJob, dedupe_key: "action-reconciliation:#{action.id}")
      |> BackgroundJob.hydrate_payloads()

    assert job.queue == "runtime_provider_account"

    assert job.payload["confirmed_payload_hash"] ==
             action.payload["_maraithon_confirmed_payload_sha256"]

    mail = sent_mail(action)
    gmail(mail)
    assert {:ok, settled, :executed} = TelegramAssistant.reconcile_prepared_action(action)
    proof = settled.payload["_maraithon_reconciliation_receipt"]
    assert proof["message_id"] == "sent-controlled"
    assert proof["confirmed_payload_hash"] == job.payload["confirmed_payload_hash"]
    assert {:ok, _, :executed} = TelegramAssistant.reconcile_prepared_action(action)
    refute_received {:provider_entered, _}

    assert Repo.aggregate(
             from(j in BackgroundJob, where: j.dedupe_key == ^job.dedupe_key),
             :count
           ) == 1
  end

  test "absent, duplicate, mismatched and non-Sent messages remain uncertain", ctx do
    action = unknown(ctx)
    assert_received {:provider_entered, _}

    for response <- [
          %{},
          %{"messages" => [%{"id" => "one"}, %{"id" => "two"}]},
          %{"messages" => [%{"id" => "one"}], "nextPageToken" => "more"}
        ] do
      Application.put_env(:maraithon, ActionReconciliation,
        gmail_request: fn _, _ -> {:ok, response} end
      )

      assert {:pending, :sent_message_not_proven} =
               TelegramAssistant.reconcile_prepared_action(action)
    end

    for mail <- [
          put_in(sent_mail(action), ["payload", "headers"], []),
          Map.put(sent_mail(action), "labelIds", ["DRAFT"])
        ] do
      gmail(mail)

      assert {:pending, :sent_message_not_proven} =
               TelegramAssistant.reconcile_prepared_action(action)
    end

    assert reload(action).status == "execution_unknown"
    refute_received {:provider_entered, _}
  end

  test "a pre-existing draft must match its frozen MIME content", ctx do
    payload =
      mail_payload(ctx)
      |> Map.put("draft_id", "draft-controlled")
      |> Map.put("_maraithon_draft_message_id", "<draft@example.com>")

    message =
      sent_mail(%{
        payload: %{
          "_maraithon_reconciliation_identity" => %{"message_id" => "<draft@example.com>"}
        }
      })

    payload =
      Map.put(
        payload,
        "_maraithon_draft_fingerprint",
        ActionReconciliation.draft_fingerprint(message)
      )

    action = unknown(ctx, "gmail_draft_send", payload)

    gmail(
      put_in(message, ["payload", "body", "data"], Base.url_encode64("edited after approval"))
    )

    assert {:pending, :sent_message_not_proven} =
             TelegramAssistant.reconcile_prepared_action(action)

    gmail(message)
    assert {:ok, _, :executed} = TelegramAssistant.reconcile_prepared_action(action)
  end

  test "account replacement blocks provider lookup and original execution", ctx do
    action = unknown(ctx)
    assert_received {:provider_entered, _}

    {:ok, _} =
      ConnectedAccounts.upsert_manual(ctx.user_id, "google", %{
        external_account_id: "different-mailbox"
      })

    Application.put_env(:maraithon, ActionReconciliation,
      gmail_request: fn _, _ -> flunk("must not read another account") end
    )

    assert {:pending, :connected_account_changed} =
             TelegramAssistant.reconcile_prepared_action(action)

    assert {:error, :connected_account_changed} = Runner.execute_prepared_action(action)
    refute_received {:provider_entered, _}
  end

  test "the approval hash covers internal reconciliation identity", ctx do
    action = unknown(ctx)

    payload =
      put_in(
        action.payload,
        ["_maraithon_reconciliation_identity", "message_id"],
        "<forged@example.com>"
      )

    {:ok, action} = TelegramAssistant.update_prepared_action(action, %{payload: payload})

    Application.put_env(:maraithon, ActionReconciliation,
      gmail_request: fn _, _ -> flunk("tampered approval") end
    )

    assert {:error, :prepared_action_payload_tampered} =
             TelegramAssistant.reconcile_prepared_action(action)
  end

  test "calendar evidence recovers a booking even after its original start time", ctx do
    payload = %{
      "user_id" => ctx.user_id,
      "title" => "Controlled meeting",
      "description" => "Approved agenda",
      "start_at" => "2026-01-01T10:00:00Z",
      "end_at" => "2026-01-01T11:00:00Z",
      "timezone" => "UTC"
    }

    action = unknown(ctx, "calendar_create_event", payload)
    assert_received {:provider_entered, _}
    id = ActionReconciliation.calendar_event_id(action.id)

    event = %{
      event_id: id,
      summary: payload["title"],
      description: payload["description"],
      start: ~U[2026-01-01 10:00:00Z],
      end: ~U[2026-01-01 11:00:00Z],
      status: "confirmed",
      private_properties: %{
        "maraithon_managed" => "true",
        "maraithon_todo_id" => "",
        "maraithon_client_key" => id
      }
    }

    calendar(Map.put(event, :description, "Different agenda"))

    assert {:pending, :calendar_change_not_proven} =
             TelegramAssistant.reconcile_prepared_action(action)

    calendar(Map.put(event, :start, "invalid"))

    assert {:pending, :calendar_change_not_proven} =
             TelegramAssistant.reconcile_prepared_action(action)

    calendar(event)
    assert {:ok, recovered, :executed} = TelegramAssistant.reconcile_prepared_action(action)
    assert recovered.payload["_maraithon_reconciliation_receipt"]["event_id"] == id
    refute_received {:provider_entered, _}
  end

  test "browser completion requires exact command scope and arguments", ctx do
    todo_id = todo(ctx).id

    device =
      Repo.insert!(%Maraithon.Companion.Device{
        user_id: ctx.user_id,
        device_id: Ecto.UUID.generate(),
        token_hash: Ecto.UUID.generate()
      })

    payload = %{
      "user_id" => ctx.user_id,
      "todo_id" => todo_id,
      "operation" => "click",
      "element_id" => "reviewed-button"
    }

    action = unknown(ctx, "browser_interact", payload)
    assert_received {:provider_entered, _}

    command =
      Repo.insert!(%Command{
        id: action.id,
        user_id: ctx.user_id,
        device_id: device.id,
        todo_id: todo_id,
        operation: "click",
        payload: %{"element_id" => "different-button"},
        status: "completed",
        result: %{"title" => "Completed page", "text" => "Receipt"},
        expires_at: DateTime.add(DateTime.utc_now(), 60)
      })

    assert {:pending, :browser_command_mismatch} =
             TelegramAssistant.reconcile_prepared_action(action)

    command
    |> Ecto.Changeset.change(payload: %{"element_id" => "reviewed-button"})
    |> Repo.update!()

    assert {:ok, _, :executed} = TelegramAssistant.reconcile_prepared_action(action)
    refute_received {:provider_entered, _}
  end

  test "active sender is left alone, expired sender is observed but never replayed", ctx do
    action = unknown(ctx)
    assert_received {:provider_entered, _}

    payload =
      action.payload
      |> Map.put("_maraithon_execution_token", Ecto.UUID.generate())
      |> Map.put(
        "_maraithon_execution_lease_until",
        DateTime.to_iso8601(DateTime.add(DateTime.utc_now(), 60))
      )

    {:ok, active} =
      TelegramAssistant.update_prepared_action(action, %{status: "confirmed", payload: payload})

    Application.put_env(:maraithon, ActionReconciliation,
      gmail_request: fn _, _ -> {:ok, %{}} end
    )

    assert {:pending, :prepared_action_execution_in_progress} =
             TelegramAssistant.reconcile_prepared_action(active)

    payload =
      Map.put(
        payload,
        "_maraithon_execution_lease_until",
        DateTime.to_iso8601(DateTime.add(DateTime.utc_now(), -60))
      )

    {:ok, expired} = TelegramAssistant.update_prepared_action(active, %{payload: payload})

    assert {:pending, :sent_message_not_proven} =
             TelegramAssistant.reconcile_prepared_action(expired)

    assert reload(action).status == "execution_unknown"
    refute_received {:provider_entered, _}
  end

  test "approval committed before first claim can enter once, then resumes its receipt", ctx do
    action = unknown(ctx)
    assert_received {:provider_entered, _}
    payload = action.payload |> Map.put("_maraithon_execution_attempts", 0)

    {:ok, unentered} =
      TelegramAssistant.update_prepared_action(action, %{status: "confirmed", payload: payload})

    pid = self()

    executor(fn a ->
      send(pid, {:recovered_entry, a.id})
      {:ok, %{message: "Controlled success"}}
    end)

    assert {:ok, _, :executed} = TelegramAssistant.reconcile_prepared_action(unentered)
    assert_received {:recovered_entry, _}
    assert {:ok, _, :executed} = TelegramAssistant.reconcile_prepared_action(unentered)
    refute_received {:recovered_entry, _}
    assert reload(action).payload["_maraithon_execution_attempts"] == 1
  end

  test "stale background authority cannot settle a positive provider result", ctx do
    action = unknown(ctx)
    gmail(sent_mail(action))

    stale = %BackgroundJob{
      id: Ecto.UUID.generate(),
      user_id: ctx.user_id,
      claim_token: Ecto.UUID.generate(),
      payload: %{"conversation_id" => ctx.conversation.id}
    }

    assert {:error, _} =
             Execution.with_authority(stale, fn ->
               TelegramAssistant.reconcile_prepared_action(action)
             end)

    assert reload(action).status == "execution_unknown"
  end

  test "Message-ID headers are safe and survive MIME construction" do
    id = "<maraithon.controlled@maraithon.com>"

    raw =
      Maraithon.Tools.GmailApiHelpers.raw_message("controlled@example.com", "Agenda", "Body",
        message_id_header: id
      )

    assert Base.url_decode64!(raw, padding: false) =~ "Message-ID: #{id}\r\n"

    assert Maraithon.Tools.GmailApiHelpers.message_id_header(
             "<bad@example.com>\r\nBcc: other@example.com"
           ) == nil
  end

  test "a server error after Gmail entry stays unknown instead of retrying", ctx do
    pid = self()

    executor(fn action ->
      send(pid, {:provider_entered, action.id})
      {:error, {:http_status, 503, "lost provider outcome"}}
    end)

    action = unknown(ctx)
    assert_received {:provider_entered, _}

    assert {:error, _, _, :manual_reconciliation} =
             TelegramAssistant.confirm_and_execute(action, durable: true)

    refute_received {:provider_entered, _}
  end

  test "reconciled supporting action applies its handoff once and keeps the outcome open", ctx do
    todo = todo(ctx)

    {:ok, payload} =
      Maraithon.Todos.ActionHandoff.prepare(
        ctx.user_id,
        "gmail_send",
        mail_payload(ctx)
        |> Map.put("todo_id", todo.id)
        |> Map.put("keep_todo_open", true)
        |> Map.put("workflow_transition", %{
          "state" => "waiting",
          "owner" => %{"kind" => "user"},
          "expected_revision" => 0,
          "reason" => "Wait for availability after the approved email.",
          "next_action" => "Follow up on availability",
          "outcome" => "The meeting happens"
        })
      )

    action = unknown(ctx, "gmail_send", payload)
    gmail(sent_mail(action))
    assert {:ok, _, :executed} = TelegramAssistant.reconcile_prepared_action(action)
    current = Maraithon.Todos.get_for_user(ctx.user_id, todo.id)
    assert current.status == "open"
    assert current.workflow["state"] == "waiting"
    assert current.workflow["revision"] == 1
    assert current.workflow["outcome"] == "The meeting happens"
    assert reload(action).workflow_handoff_state == "applied"
    assert {:ok, _, :executed} = TelegramAssistant.reconcile_prepared_action(action)
    assert Maraithon.Todos.get_for_user(ctx.user_id, todo.id).workflow["revision"] == 1
  end

  test "edited draft send carries its frozen MIME and identity in the same provider request" do
    args = %{
      "draft_id" => "controlled-draft",
      "to" => "controlled@example.com",
      "subject" => "Approved agenda",
      "body" => "Frozen body",
      "send_frozen_content" => true,
      "message_id_header" => "<maraithon.controlled@maraithon.com>"
    }

    assert {:ok, %{id: "controlled-draft", message: %{raw: raw}}} =
             Maraithon.Tools.GmailDrafts.send_body(args)

    mime = Base.url_decode64!(raw, padding: false)
    assert mime =~ "Subject: Approved agenda"
    assert mime =~ "Message-ID: <maraithon.controlled@maraithon.com>"
    assert String.ends_with?(mime, "Frozen body")

    assert {:ok, %{id: "controlled-draft"} = unchanged} =
             Maraithon.Tools.GmailDrafts.send_body(Map.put(args, "send_frozen_content", false))

    refute Map.has_key?(unchanged, :message)
  end

  defp todo(ctx) do
    Repo.insert!(%Maraithon.Todos.Todo{
      user_id: ctx.user_id,
      owner_user_id: ctx.user_id,
      source: "controlled_recovery",
      kind: "general",
      title: "The meeting happens",
      summary: "Controlled outcome verification",
      next_action: "Coordinate availability",
      dedupe_key: Ecto.UUID.generate(),
      status: "open"
    })
  end

  defp unknown(ctx, type \\ "gmail_send", payload \\ nil) do
    {:ok, action} =
      TelegramAssistant.create_prepared_action(%{
        user_id: ctx.user_id,
        chat_id: ctx.conversation.chat_id,
        conversation_id: ctx.conversation.id,
        run_id: ctx.run.id,
        surface: "mobile",
        action_type: type,
        target_type: "controlled",
        target_id: "controlled",
        payload: payload || mail_payload(ctx),
        preview_text: "Controlled action",
        status: "awaiting_confirmation",
        expires_at: DateTime.add(DateTime.utc_now(), 600)
      })

    # Calendar replay-safe errors release a finished claim. Turn the persisted
    # intent into an unknown outcome to exercise observation rather than retry.
    case TelegramAssistant.confirm_and_execute(action, durable: true) do
      {:error, current, _, :manual_reconciliation} ->
        current

      {:error, current, _} ->
        {:ok, unknown} =
          TelegramAssistant.update_prepared_action(current, %{status: "execution_unknown"})

        unknown
    end
  end

  defp mail_payload(ctx),
    do: %{
      "user_id" => ctx.user_id,
      "to" => "controlled@example.com",
      "subject" => "Agenda",
      "body" => "Body"
    }

  defp executor(fun), do: Application.put_env(:maraithon, :action_reconciliation_executor, fun)

  defp reload(action),
    do: Repo.get!(PreparedAction, action.id) |> PreparedAction.hydrate_payload()

  defp sent_mail(action) do
    %{
      "id" => "sent-controlled",
      "threadId" => "controlled-thread",
      "labelIds" => ["SENT"],
      "payload" => %{
        "mimeType" => "text/plain",
        "body" => %{"data" => Base.url_encode64("Body")},
        "headers" => [
          %{"name" => "Message-ID", "value" => ActionReconciliation.message_id(action)},
          %{"name" => "To", "value" => "controlled@example.com"},
          %{"name" => "Subject", "value" => "Agenda"}
        ]
      }
    }
  end

  defp gmail(mail) do
    Application.put_env(:maraithon, ActionReconciliation,
      gmail_request: fn _, path ->
        if String.contains?(path, "/messages?"),
          do: {:ok, %{"messages" => [%{"id" => mail["id"]}]}},
          else: {:ok, mail}
      end
    )
  end

  defp calendar(event),
    do:
      Application.put_env(:maraithon, ActionReconciliation,
        calendar_get: fn _, _ -> {:ok, event} end
      )
end
