defmodule Maraithon.Tools.CalendarSemanticSearchTest do
  use Maraithon.DataCase, async: true

  alias Maraithon.Accounts
  alias Maraithon.Capabilities
  alias Maraithon.LocalCalendar
  alias Maraithon.Tools

  defp seed_user(label) do
    email = "cal-sem-#{label}-#{System.unique_integer([:positive])}@example.com"
    {:ok, user} = Accounts.get_or_create_user_by_email(email)
    {user.id, Ecto.UUID.generate()}
  end

  defp sample_event(guid, overrides \\ %{}) do
    Map.merge(
      %{
        "local_id" => "evt:#{guid}",
        "guid" => guid,
        "calendar_name" => "Home",
        "title" => "Coffee",
        "notes" => "",
        "location" => "Cafe",
        "start_at" => "2026-05-12T15:00:00Z",
        "end_at" => "2026-05-12T15:30:00Z",
        "is_all_day" => false,
        "is_recurring" => false,
        "attendee_emails" => []
      },
      overrides
    )
  end

  describe "registration" do
    test "registered read-only with required user_id + query" do
      descriptor = Capabilities.tool_descriptor("calendar_semantic_search")
      assert descriptor.description =~ "Semantic search of the user's mirrored macOS Calendar"
      schema = descriptor.input_schema
      assert Enum.sort(schema["required"]) == ["query", "user_id"]

      policy = Tools.policy_metadata_for("calendar_semantic_search")
      assert policy.read_only? == true
    end
  end

  describe "execute/1" do
    test "ranks semantically-similar event first" do
      {user_id, device_id} = seed_user("rank")

      {:ok, _} =
        LocalCalendar.ingest_batch(user_id, device_id, [
          sample_event("e1", %{
            "title" => "Product launch review",
            "notes" => "go/no-go decision launch readiness checklist marketing rollout"
          }),
          sample_event("e2", %{
            "title" => "Dentist checkup",
            "notes" => "annual cleaning"
          })
        ])

      assert {:ok, result} =
               Tools.execute("calendar_semantic_search", %{
                 "user_id" => user_id,
                 "query" => "launch readiness marketing rollout checklist"
               })

      assert result.source == "local_calendar"
      assert result.search_mode == "semantic"
      assert result.count >= 1
      [top | _] = result.events
      assert top.title == "Product launch review"
    end

    test "rejects missing query" do
      {user_id, _device_id} = seed_user("mq")

      assert {:error, message} =
               Tools.execute("calendar_semantic_search", %{"user_id" => user_id})

      assert message =~ "query is required"
    end
  end
end
