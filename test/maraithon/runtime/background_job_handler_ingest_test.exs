defmodule Maraithon.Runtime.BackgroundJobHandlerIngestTest do
  use Maraithon.DataCase, async: false

  alias Maraithon.Accounts
  alias Maraithon.Crm.Ingest
  alias Maraithon.Crm.Ingest.Window
  alias Maraithon.Crm.Observation
  alias Maraithon.OperatorEvents.OperatorEvent
  alias Maraithon.Repo
  alias Maraithon.Runtime.BackgroundJob
  alias Maraithon.Runtime.BackgroundJobHandler

  setup do
    user_id = "ingest-handler-#{System.unique_integer([:positive])}@example.com"
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

    on_exit(fn ->
      Application.delete_env(:maraithon, :relationship_intelligence)
      Application.delete_env(:maraithon, :open_loop_reconciliation)
    end)

    %{user_id: user_id}
  end

  defp install_relationship_stub(response) do
    Application.put_env(:maraithon, :relationship_intelligence,
      llm_complete: fn _params -> {:ok, %{content: response}} end
    )
  end

  defp install_open_loop_stub(response) do
    Application.put_env(:maraithon, :open_loop_reconciliation,
      llm_complete: fn _params -> {:ok, %{content: response}} end
    )
  end

  defp seed_window_with_observation(user_id) do
    changeset =
      Observation.new(%{
        "user_id" => user_id,
        "source" => "gmail",
        "source_account" => "primary",
        "source_item_id" => "msg-#{System.unique_integer([:positive])}",
        "occurred_at" => DateTime.utc_now(),
        "direction" => "inbound",
        "participants" => [
          %{
            "role" => "from",
            "identifier" => %{"email" => "charlie@example.com"},
            "display_name" => "Charlie"
          }
        ],
        "subject" => "Hello",
        "excerpt" => "Hi Kent, can you send the deck by Friday?"
      })

    {:ok, :buffered, _id} = Ingest.observe(user_id, changeset)
    {:ok, :flushed, job_id} = Ingest.flush_pending(user_id, "gmail")
    Repo.get!(BackgroundJob, job_id)
  end

  test "completes the window after both passes succeed", %{user_id: user_id} do
    install_relationship_stub(
      ~s|{"summary":"learned charlie","people":[],"memories":[],"links":[]}|
    )

    install_open_loop_stub(~s|{"candidates":[]}|)

    job = seed_window_with_observation(user_id)

    assert {:ok, result} = BackgroundJobHandler.execute(job)

    assert result.source == "crm_ingest"
    window = Repo.get!(Window, result.window_id)
    assert window.status == "completed"
    assert window.completed_at != nil

    assert observations = Repo.all(Observation)
    assert Enum.all?(observations, &(&1.learned_at != nil))

    assert [event] =
             Repo.all(
               from e in OperatorEvent,
                 where: e.user_id == ^user_id and e.event_type == "crm_ingest.completed"
             )

    assert event.dedupe_key == "crm_ingest:completed:#{window.id}"
    assert get_in(event.payload, ["window_id"]) == window.id
    assert get_in(event.payload, ["people_touched"]) == 1
  end

  test "marks the window failed and surfaces an error when relationship pass blows up",
       %{user_id: user_id} do
    Application.put_env(:maraithon, :relationship_intelligence,
      llm_complete: fn _params -> {:error, :stub_failure} end
    )

    install_open_loop_stub(~s|{"candidates":[]}|)

    job = seed_window_with_observation(user_id)

    assert {:error, :stub_failure} = BackgroundJobHandler.execute(job)

    window = Repo.get!(Window, job.payload["window_id"])
    assert window.status == "failed"
    assert is_binary(window.last_error)
    assert window.last_error =~ "relationship_pass"
  end

  test "rerunning a completed window is a no-op", %{user_id: user_id} do
    install_relationship_stub(~s|{"summary":"x","people":[],"memories":[],"links":[]}|)
    install_open_loop_stub(~s|{"candidates":[]}|)

    job = seed_window_with_observation(user_id)
    {:ok, _} = BackgroundJobHandler.execute(job)

    assert {:ok, %{skipped: "already_completed"}} = BackgroundJobHandler.execute(job)
  end
end
