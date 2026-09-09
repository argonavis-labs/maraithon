defmodule Maraithon.AssistantChat.AcceptanceRoutingTest do
  use Maraithon.DataCase, async: false
  alias Maraithon.{Accounts, AssistantChat, TelegramAssistant}
  alias Maraithon.Runtime.BackgroundJob
  alias Maraithon.TelegramAssistant.{Run, Runner}

  test "new and duplicate acceptance use no model, then the durable request routes once" do
    original = Application.get_env(:maraithon, :telegram_assistant, [])
    engine = Application.get_env(:maraithon, Maraithon.ContextEngine, [])

    on_exit(fn ->
      Application.put_env(:maraithon, :telegram_assistant, original)
      Application.put_env(:maraithon, Maraithon.ContextEngine, engine)
    end)

    pid = self()

    Application.put_env(
      :maraithon,
      :telegram_assistant,
      Keyword.merge(original,
        client_module: Maraithon.TestSupport.TelegramAssistantClientStub,
        routing_classifier_complete: fn _ ->
          send(pid, :routed)
          {:ok, ~s({"focus":"none"})}
        end,
        next_step: fn _ ->
          send(pid, :model_called)

          {:ok,
           %{
             "status" => "final",
             "message_class" => "assistant_reply",
             "assistant_message" => "Controlled response."
           }}
        end
      )
    )

    Application.put_env(:maraithon, Maraithon.ContextEngine,
      engine: Maraithon.TestSupport.ContinuationContextEngine
    )

    user_id = "acceptance-routing-#{System.unique_integer([:positive])}@example.com"
    {:ok, _} = Accounts.get_or_create_user_by_email(user_id)
    {:ok, thread} = AssistantChat.create_thread(user_id, %{"title" => "Controlled routing cost"})

    attrs = %{
      "body" => "I could use a fresh perspective on the situation.",
      "client_message_id" => Ecto.UUID.generate()
    }

    assert {:ok, accepted} = AssistantChat.send_message(user_id, thread.id, attrs)
    assert accepted.run.status == "queued"
    assert accepted.run.result_summary["model_tier"] == "pending"
    assert {:ok, duplicate} = AssistantChat.send_message(user_id, thread.id, attrs)
    assert duplicate.run.id == accepted.run.id
    assert duplicate.message.id == accepted.message.id
    assert duplicate.duplicate?

    assert {:error, :client_message_id_conflict} =
             AssistantChat.send_message(
               user_id,
               thread.id,
               Map.put(attrs, "body", "Different request")
             )

    refute_received :routed
    refute_received :model_called

    assert Repo.aggregate(
             from(j in BackgroundJob,
               where: j.user_id == ^user_id and j.job_type == "assistant_chat_request"
             ),
             :count
           ) == 1

    assert :ok = AssistantChat.execute_request(accepted.run, thread, accepted.message)
    assert_received :routed
    refute_received :routed
    assert_received :model_called
    run = Repo.get!(Run, accepted.run.id) |> Run.hydrate_payloads()
    assert run.status == "completed"
    assert run.result_summary["llm_turns"] == 1
    assert {:ok, duplicate} = AssistantChat.send_message(user_id, thread.id, attrs)
    assert duplicate.run.id == run.id
    refute_received :routed
    refute_received :model_called
    # Final checkpoint recovery likewise does not reclassify a completed request.
    assert {:error, :request_not_resumable} = Runner.resume_request(%{run: run})
    refute_received :routed
    refute_received :model_called
  end
end
