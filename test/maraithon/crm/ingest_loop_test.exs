defmodule Maraithon.Crm.IngestLoopTest do
  @moduledoc """
  End-to-end test of the CRM ingestion loop.

  Builds an `Observation` from a Gmail-shaped parsed message, runs it through
  `Crm.Ingest.observe/2` and the `relationship_ingestion` background job, and
  asserts that the durable trail (observation row, person, relationship
  link, operator event) all show up — using mocked LLM passes so the test
  is hermetic.
  """

  use Maraithon.DataCase, async: false

  import Ecto.Query

  alias Maraithon.Accounts
  alias Maraithon.Crm
  alias Maraithon.Crm.Ingest
  alias Maraithon.Crm.Ingest.Window
  alias Maraithon.Crm.Observation
  alias Maraithon.OperatorEvents.OperatorEvent
  alias Maraithon.Repo
  alias Maraithon.Runtime.BackgroundJob
  alias Maraithon.Runtime.BackgroundJobHandler

  setup do
    user_id = "ingest-loop-#{System.unique_integer([:positive])}@example.com"
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

    Application.put_env(:maraithon, :relationship_intelligence,
      llm_complete: fn _params ->
        {:ok,
         %{
           content:
             ~s|{"summary":"learned charlie","people":[{"display_name":"Charlie","contact_details":{"emails":["charlie@example.com"]}}],"memories":[],"links":[]}|
         }}
      end
    )

    Application.put_env(:maraithon, :open_loop_reconciliation,
      llm_complete: fn _params ->
        {:ok, %{content: ~s|{"candidates":[]}|}}
      end
    )

    on_exit(fn ->
      Application.delete_env(:maraithon, :relationship_intelligence)
      Application.delete_env(:maraithon, :open_loop_reconciliation)
    end)

    %{user_id: user_id}
  end

  test "Gmail observation flows through dedupe, window, job, and operator event",
       %{user_id: user_id} do
    changeset =
      Observation.new(%{
        "user_id" => user_id,
        "source" => "gmail",
        "source_account" => user_id,
        "source_item_id" => "gmail-msg-1",
        "occurred_at" => DateTime.utc_now(),
        "direction" => "inbound",
        "participants" => [
          %{
            "role" => "from",
            "identifier" => %{"email" => "charlie@example.com"},
            "display_name" => "Charlie Smith"
          },
          %{
            "role" => "to",
            "identifier" => %{"email" => user_id},
            "display_name" => nil
          }
        ],
        "subject" => "Re: kickoff next week",
        "excerpt" => "Hey Kent, can you confirm Tuesday at 2pm?",
        "metadata" => %{"thread_id" => "thread-1"}
      })

    assert {:ok, :buffered, observation_id} = Ingest.observe(user_id, changeset)
    observation = Repo.get!(Observation, observation_id)

    # Synchronous CRM update happened immediately
    assert length(observation.resolved_person_ids) == 2
    [charlie] = Crm.list_people(user_id, query: "charlie")
    assert charlie.display_name == "Charlie Smith"
    assert charlie.interaction_count == 1
    assert charlie.last_interaction_at != nil

    # No flush yet — single observation under the size threshold
    refute Repo.exists?(from(j in BackgroundJob, where: j.user_id == ^user_id))

    # Force the flush, run the job, and confirm the durable trail
    {:ok, :flushed, job_id} = Ingest.flush_pending(user_id, "gmail")
    job = Repo.get!(BackgroundJob, job_id)
    assert {:ok, %{source: "crm_ingest"}} = BackgroundJobHandler.execute(job)

    window = Repo.get!(Window, observation.window_id)
    assert window.status == "completed"
    assert window.completed_at != nil

    reloaded = Repo.get!(Observation, observation.id)
    assert reloaded.learned_at != nil

    [event] =
      Repo.all(
        from e in OperatorEvent,
          where: e.user_id == ^user_id and e.event_type == "crm_ingest.completed"
      )

    assert event.dedupe_key == "crm_ingest:completed:#{window.id}"
    assert get_in(event.payload, ["window_id"]) == window.id
    assert get_in(event.payload, ["observations_count"]) == 1
  end

  test "duplicate Gmail observation is a no-op", %{user_id: user_id} do
    changeset =
      Observation.new(%{
        "user_id" => user_id,
        "source" => "gmail",
        "source_account" => user_id,
        "source_item_id" => "gmail-dup",
        "occurred_at" => DateTime.utc_now(),
        "direction" => "inbound",
        "participants" => [
          %{"role" => "from", "identifier" => %{"email" => "dana@example.com"}}
        ]
      })

    assert {:ok, :buffered, _id} = Ingest.observe(user_id, changeset)

    duplicate =
      Observation.new(%{
        "user_id" => user_id,
        "source" => "gmail",
        "source_account" => user_id,
        "source_item_id" => "gmail-dup",
        "occurred_at" => DateTime.utc_now(),
        "direction" => "inbound",
        "participants" => [
          %{"role" => "from", "identifier" => %{"email" => "dana@example.com"}}
        ]
      })

    assert {:ok, :duplicate} = Ingest.observe(user_id, duplicate)

    [dana] = Crm.list_people(user_id, query: "dana")
    assert dana.interaction_count == 1
  end
end
