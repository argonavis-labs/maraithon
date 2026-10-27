defmodule Maraithon.TelegramAssistant.RunReaperTest do
  use Maraithon.DataCase, async: true

  alias Maraithon.Accounts
  alias Maraithon.Repo
  alias Maraithon.TelegramAssistant.Run
  alias Maraithon.TelegramAssistant.RunReaper

  setup do
    user_id = "run-reaper-test@example.com"
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)
    %{user_id: user_id}
  end

  defp insert_run(user_id, status, started_at) do
    %Run{}
    |> Run.changeset(%{
      user_id: user_id,
      chat_id: "chat-#{System.unique_integer([:positive])}",
      trigger_type: "inbound_message",
      status: status,
      model_provider: "openai",
      model_name: "gpt-test",
      prompt_snapshot: %{},
      started_at: started_at
    })
    |> Repo.insert!()
  end

  test "reaps runs stuck in :running past the stale timeout", %{user_id: user_id} do
    stale_started = DateTime.add(DateTime.utc_now(), -3600, :second)
    orphan = insert_run(user_id, "running", stale_started)

    assert RunReaper.reap_stale_runs(600_000) == 1

    reaped = Repo.get!(Run, orphan.id)
    assert reaped.status == "degraded"
    assert reaped.error == "run_reaper_orphaned"
    assert reaped.finished_at != nil
  end

  test "leaves recent running runs and already-finished runs alone", %{user_id: user_id} do
    recent = insert_run(user_id, "running", DateTime.utc_now())

    completed =
      insert_run(user_id, "completed", DateTime.add(DateTime.utc_now(), -3600, :second))

    assert RunReaper.reap_stale_runs(600_000) == 0

    assert Repo.get!(Run, recent.id).status == "running"
    assert Repo.get!(Run, completed.id).status == "completed"
  end
end
