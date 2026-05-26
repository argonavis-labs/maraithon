defmodule MaraithonWeb.EventControllerTest do
  use MaraithonWeb.ConnCase, async: true

  alias Maraithon.Agents

  describe "POST /api/v1/events" do
    test "publishes event to topic", %{conn: conn} do
      conn =
        post(conn, "/api/v1/events", %{
          topic: "test_topic",
          payload: %{foo: "bar"}
        })

      response = json_response(conn, 202)
      assert response["status"] == "published"
      assert response["topic"] == "test_topic"
    end

    test "returns error when topic is missing", %{conn: conn} do
      conn = post(conn, "/api/v1/events", %{payload: %{foo: "bar"}})

      assert json_response(conn, 400)["error"] == "topic is required"
    end

    test "returns error when topic is empty string", %{conn: conn} do
      conn = post(conn, "/api/v1/events", %{topic: "", payload: %{}})

      assert json_response(conn, 400)["error"] == "topic is required"
    end

    test "uses empty payload when not provided", %{conn: conn} do
      conn = post(conn, "/api/v1/events", %{topic: "test_topic"})

      response = json_response(conn, 202)
      assert response["status"] == "published"
    end
  end

  describe "GET /api/v1/events/topics" do
    test "returns active subscriber topic summaries", %{conn: conn} do
      {:ok, first_agent} =
        Agents.create_agent(%{
          behavior: "prompt_agent",
          config: %{
            "name" => "calendar watcher",
            "prompt" => "Watch calendar events.",
            "subscribe" => ["calendar:primary", "gmail:inbox"]
          },
          status: "running"
        })

      {:ok, second_agent} =
        Agents.create_agent(%{
          behavior: "prompt_agent",
          config: %{
            "name" => "calendar helper",
            "prompt" => "Also watch calendar events.",
            "subscribe" => ["calendar:primary"]
          },
          status: "running"
        })

      conn = get(conn, "/api/v1/events/topics")

      response = json_response(conn, 200)
      assert response["count"] == 2

      calendar_topic = Enum.find(response["topics"], &(&1["topic"] == "calendar:primary"))
      gmail_topic = Enum.find(response["topics"], &(&1["topic"] == "gmail:inbox"))

      assert calendar_topic["subscriber_count"] == 2
      assert first_agent.id in calendar_topic["agent_ids"]
      assert second_agent.id in calendar_topic["agent_ids"]
      assert is_binary(calendar_topic["updated_at"])

      assert gmail_topic["subscriber_count"] == 1
      assert first_agent.id in gmail_topic["agent_ids"]
    end
  end
end
