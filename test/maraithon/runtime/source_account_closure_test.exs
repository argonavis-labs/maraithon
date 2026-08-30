defmodule Maraithon.Runtime.SourceAccountClosureTest do
  use Maraithon.DataCase, async: false

  alias Maraithon.Accounts
  alias Maraithon.ChiefOfStaff.SourceBundle
  alias Maraithon.ConnectedAccounts
  alias Maraithon.Connectors.SourceCursors
  alias Maraithon.Runtime.SourceAccountClosure
  alias Maraithon.Todos

  test "empty closure delta advances without a model handoff" do
    account = closure_account("empty")
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    bundle = SourceBundle.empty(%{trigger: %{type: :wakeup}, timestamp: now})
    proposals = [closure_watermark(account, "1700000200")]

    assert {:ok,
            %{
              outcome: "empty_delta",
              source_items: 0,
              model_calls: 0,
              advanced_watermarks: 1
            }} =
             SourceAccountClosure.acquire(account,
               source_bundle: bundle,
               proposed_watermarks: proposals
             )

    assert %{value: "1700000200"} =
             SourceCursors.get(account.id, "gmail_closure_watermark")
  end

  test "non-empty closure delta stays sealed until account reasoning settles" do
    account = closure_account("sealed")
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    {:ok, [_todo]} =
      Todos.upsert_many(account.user_id, [
        %{
          "source" => "gmail",
          "kind" => "gmail_triage",
          "title" => "Reply to the account thread",
          "summary" => "This stays open without exact completion evidence.",
          "next_action" => "Reply to the thread.",
          "priority" => 85,
          "source_account_id" => account.id,
          "source_item_id" => "closure-thread",
          "dedupe_key" => "source-account-closure:sealed"
        }
      ])

    message = %{
      "id" => "new-incoming-message",
      "thread_id" => "other-thread",
      "subject" => "Routine update",
      "snippet" => "An update with no completion evidence.",
      "body" => "An update with no completion evidence.",
      "from" => "sender@example.com",
      "to" => [account.user_id],
      "label_ids" => ["INBOX"],
      "internal_date" => DateTime.to_unix(now, :millisecond)
    }

    bundle =
      %{trigger: %{type: :wakeup}, timestamp: now}
      |> SourceBundle.empty()
      |> SourceBundle.put_gmail(%{
        "messages" => [message],
        "inbox_messages" => [message],
        "sent_messages" => [],
        "status" => "ready",
        "fetched_at" => now
      })

    assert {:ok, %{outcome: "handoff_ready", handoff: handoff, source_items: 1}} =
             SourceAccountClosure.acquire(account,
               source_bundle: bundle,
               proposed_watermarks: [closure_watermark(account, "1700000300")],
               acquisition_job_id: "closure-acquisition"
             )

    refute SourceCursors.get(account.id, "gmail_closure_watermark")
    caller = self()

    llm_complete = fn _prompt ->
      send(caller, :model_called)
      {:ok, %{content: Jason.encode!(%{"resolutions" => []})}}
    end

    assert {:ok, %{outcome: "evaluated", account_id: account_id}} =
             SourceAccountClosure.reason(account, handoff,
               now: now,
               llm_complete: llm_complete
             )

    assert account_id == account.id
    refute_received :model_called

    assert %{value: "1700000300"} =
             SourceCursors.get(account.id, "gmail_closure_watermark")
  end

  defp closure_account(suffix) do
    user_id = "source-closure-#{suffix}-#{System.unique_integer([:positive])}@example.com"
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

    {:ok, account} =
      ConnectedAccounts.upsert_manual(user_id, "google:#{user_id}", %{
        metadata: %{"account_email" => user_id, "services" => ["gmail"]}
      })

    account
  end

  defp closure_watermark(account, value) do
    %{account: account, kind: "gmail_closure_watermark", value: value}
  end
end
