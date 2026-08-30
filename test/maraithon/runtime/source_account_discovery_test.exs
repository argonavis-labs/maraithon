defmodule Maraithon.Runtime.SourceAccountDiscoveryTest do
  use Maraithon.DataCase, async: false

  alias Maraithon.Accounts
  alias Maraithon.Agents
  alias Maraithon.ChiefOfStaff.SourceBundle
  alias Maraithon.ConnectedAccounts
  alias Maraithon.Connectors.SourceCursors
  alias Maraithon.Runtime.SourceAccountDiscovery

  test "empty account delta advances without a model handoff" do
    {account, agent} = discovery_identity("empty")
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    bundle = SourceBundle.empty(%{trigger: %{type: :wakeup}, timestamp: now})

    acquisition = fn user_id, ["followthrough"], _configs, context ->
      assert user_id == account.user_id
      assert context.source_watermark_role == "discovery"
      assert context.defer_watermark_advance

      {bundle, %{},
       [
         %{
           account: account,
           kind: "gmail_discovery_watermark",
           value: "1700000000"
         }
       ]}
    end

    assert {:ok,
            %{
              outcome: "empty_delta",
              source_items: 0,
              model_calls: 0,
              advanced_watermarks: 1
            }} =
             SourceAccountDiscovery.acquire(account, agent,
               acquisition: acquisition,
               now: now
             )

    assert %{value: "1700000000"} =
             SourceCursors.get(account.id, "gmail_discovery_watermark")
  end

  test "non-empty delta stays sealed until reasoning settles then advances quietly" do
    {account, agent} = discovery_identity("sealed")
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    bundle =
      %{trigger: %{type: :wakeup}, timestamp: now}
      |> SourceBundle.empty()
      |> SourceBundle.put_gmail(%{
        "messages" => [routine_message(now)],
        "inbox_messages" => [routine_message(now)],
        "sent_messages" => [],
        "status" => "ready",
        "fetched_at" => now
      })

    acquisition = fn _user_id, _skills, _configs, _context ->
      {bundle, %{},
       [
         %{
           account: account,
           kind: "gmail_discovery_watermark",
           value: "1700000100"
         }
       ]}
    end

    assert {:ok, %{outcome: "handoff_ready", handoff: handoff, source_items: 1}} =
             SourceAccountDiscovery.acquire(account, agent,
               acquisition: acquisition,
               acquisition_job_id: "acquisition-job",
               now: now
             )

    refute SourceCursors.get(account.id, "gmail_discovery_watermark")
    caller = self()

    assert {:ok, %{model_calls: 0, advanced_watermarks: 1}} =
             SourceAccountDiscovery.reason(account, agent, handoff,
               now: now,
               llm_complete: fn _params ->
                 send(caller, :model_called)
                 {:error, :unexpected_model_call}
               end
             )

    refute_received :model_called

    assert %{value: "1700000100"} =
             SourceCursors.get(account.id, "gmail_discovery_watermark")
  end

  defp discovery_identity(suffix) do
    user_id =
      "source-account-discovery-#{suffix}-#{System.unique_integer([:positive])}@example.com"

    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

    {:ok, account} =
      ConnectedAccounts.upsert_manual(user_id, "google:#{user_id}", %{
        metadata: %{"account_email" => user_id, "services" => ["gmail"]}
      })

    {:ok, agent} =
      Agents.create_agent(%{
        user_id: user_id,
        behavior: "ai_chief_of_staff",
        config: %{},
        status: "running"
      })

    {account, agent}
  end

  defp routine_message(now) do
    %{
      "id" => "routine-message",
      "thread_id" => "routine-thread",
      "subject" => "Newsletter",
      "snippet" => "A routine informational update with no request.",
      "body" => "A routine informational update with no request.",
      "from" => "newsletter@example.com",
      "to" => ["owner@example.com"],
      "label_ids" => ["INBOX"],
      "internal_date" => DateTime.to_unix(now, :millisecond)
    }
  end
end
