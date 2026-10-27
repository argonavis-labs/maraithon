defmodule Maraithon.Tools.RecallAnywhereTest do
  use ExUnit.Case, async: false

  alias Maraithon.Capabilities
  alias Maraithon.Tools
  alias Maraithon.Tools.RecallAnywhereHelpers

  @app_key :recall_anywhere_sources

  setup do
    previous = Application.get_env(:maraithon, @app_key)
    on_exit(fn -> reset_env(previous) end)
    :ok
  end

  defp reset_env(nil), do: Application.delete_env(:maraithon, @app_key)
  defp reset_env(value), do: Application.put_env(:maraithon, @app_key, value)

  defp install_sources(map) do
    Application.put_env(:maraithon, @app_key, map)
  end

  defp days_ago(days) when is_integer(days) and days >= 0 do
    DateTime.utc_now()
    |> DateTime.add(-days * 86_400, :second)
  end

  defp hit(source, id, opts \\ []) do
    %{
      source: source,
      id: id,
      title: Keyword.get(opts, :title, "title-#{id}"),
      snippet: Keyword.get(opts, :snippet, "snippet-#{id}"),
      timestamp: Keyword.get(opts, :timestamp, days_ago(0)),
      match_field: Keyword.get(opts, :match_field, :title)
    }
  end

  describe "registration" do
    test "registered in capabilities with required schema and read-only policy" do
      descriptor = Capabilities.tool_descriptor("recall_anywhere")
      assert descriptor.description =~ "Search every local + remote source"
      schema = descriptor.input_schema
      assert "query" in schema["required"]
      assert "user_id" in schema["required"]
      assert schema["properties"]["sources"]["type"] == "array"

      policy = Tools.policy_metadata_for("recall_anywhere")
      assert policy.read_only? == true
      assert policy.destructive? == false
    end
  end

  describe "execute/1 happy path" do
    test "fans out to every default source and returns ranked hits" do
      install_sources(%{
        "local_messages" => fn _u, _q, _o -> [hit("local_messages", "m1")] end,
        "local_notes" => fn _u, _q, _o -> [hit("local_notes", "n1")] end,
        "local_voice_memos" => fn _u, _q, _o -> [hit("local_voice_memos", "v1")] end,
        "local_calendar" => fn _u, _q, _o -> [hit("local_calendar", "c1")] end,
        "local_reminders" => fn _u, _q, _o -> [hit("local_reminders", "r1")] end,
        "local_files" => fn _u, _q, _o -> [hit("local_files", "f1")] end,
        "local_browser_history" => fn _u, _q, _o -> [hit("local_browser_history", "b1")] end,
        "maraithon_memory" => fn _u, _q, _o -> [hit("maraithon_memory", "mem1")] end,
        "crm_people" => fn _u, _q, _o -> [hit("crm_people", "p1")] end
      })

      assert {:ok, result} =
               Tools.execute("recall_anywhere", %{
                 "user_id" => "user@example.com",
                 "query" => "wedding"
               })

      assert result.source == "recall_anywhere"
      assert result.query == "wedding"
      assert result.count == 9
      assert Enum.sort(result.sources_searched) == Enum.sort(RecallAnywhereHelpers.all_sources())
      assert result.partial_sources == []

      ids = Enum.map(result.results, & &1.id) |> Enum.sort()
      assert ids == ~w(b1 c1 f1 m1 mem1 n1 p1 r1 v1)
    end

    test "results carry the uniform shape and score in [0,1]" do
      install_sources(%{
        "local_messages" => fn _, _, _ -> [hit("local_messages", "m1")] end
      })

      assert {:ok, result} =
               Tools.execute("recall_anywhere", %{
                 "user_id" => "u@example.com",
                 "query" => "anything",
                 "sources" => ["local_messages"]
               })

      assert [
               %{
                 source: "local_messages",
                 id: "m1",
                 title: title,
                 snippet: snippet,
                 timestamp: %DateTime{},
                 score: score
               }
             ] = result.results

      assert is_binary(title)
      assert is_binary(snippet)
      assert score >= 0.0 and score <= 1.0
    end
  end

  describe "ranking" do
    test "recency dominates: newer beats older when source-trust ties" do
      install_sources(%{
        "local_messages" => fn _, _, _ ->
          [
            hit("local_messages", "today", timestamp: days_ago(0)),
            hit("local_messages", "old", timestamp: days_ago(80))
          ]
        end
      })

      {:ok, result} =
        Tools.execute("recall_anywhere", %{
          "user_id" => "u@example.com",
          "query" => "x",
          "sources" => ["local_messages"]
        })

      assert Enum.map(result.results, & &1.id) == ["today", "old"]
    end

    test "title hits beat snippet hits when recency and trust tie" do
      ts = days_ago(0)

      install_sources(%{
        "local_messages" => fn _, _, _ ->
          [
            hit("local_messages", "snippet-only", timestamp: ts, match_field: :snippet),
            hit("local_messages", "title-hit", timestamp: ts, match_field: :title)
          ]
        end
      })

      {:ok, result} =
        Tools.execute("recall_anywhere", %{
          "user_id" => "u@example.com",
          "query" => "x",
          "sources" => ["local_messages"]
        })

      assert Enum.map(result.results, & &1.id) == ["title-hit", "snippet-only"]
    end

    test "source-trust breaks ties when recency and substring match are equal" do
      ts = days_ago(0)

      install_sources(%{
        # User-authored source: trust 1.0
        "local_messages" => fn _, _, _ ->
          [hit("local_messages", "msg", timestamp: ts, match_field: :title)]
        end,
        # Lower-trust source: 0.5
        "local_browser_history" => fn _, _, _ ->
          [hit("local_browser_history", "visit", timestamp: ts, match_field: :title)]
        end
      })

      {:ok, result} =
        Tools.execute("recall_anywhere", %{
          "user_id" => "u@example.com",
          "query" => "x",
          "sources" => ["local_messages", "local_browser_history"]
        })

      assert Enum.map(result.results, & &1.id) == ["msg", "visit"]
    end
  end

  describe "limit handling" do
    test "clamps to max 50 even when many hits are returned" do
      install_sources(%{
        "local_messages" => fn _, _, _ ->
          for i <- 1..200, do: hit("local_messages", "m#{i}", timestamp: days_ago(rem(i, 90)))
        end
      })

      {:ok, result} =
        Tools.execute("recall_anywhere", %{
          "user_id" => "u@example.com",
          "query" => "x",
          "limit" => 999,
          "sources" => ["local_messages"]
        })

      assert result.count == 50
    end

    test "honors caller-supplied limit when below max" do
      install_sources(%{
        "local_messages" => fn _, _, _ ->
          for i <- 1..10, do: hit("local_messages", "m#{i}")
        end
      })

      {:ok, result} =
        Tools.execute("recall_anywhere", %{
          "user_id" => "u@example.com",
          "query" => "x",
          "limit" => 3,
          "sources" => ["local_messages"]
        })

      assert result.count == 3
    end
  end

  describe "source filtering" do
    test "restricts the fan-out to the requested subset" do
      parent = self()

      install_sources(%{
        "local_messages" => fn _, _, _ ->
          send(parent, :ran_messages)
          [hit("local_messages", "m1")]
        end,
        "local_notes" => fn _, _, _ ->
          send(parent, :ran_notes)
          [hit("local_notes", "n1")]
        end
      })

      {:ok, result} =
        Tools.execute("recall_anywhere", %{
          "user_id" => "u@example.com",
          "query" => "x",
          "sources" => ["local_messages"]
        })

      assert result.sources_searched == ["local_messages"]
      assert Enum.map(result.results, & &1.id) == ["m1"]

      assert_received :ran_messages
      refute_received :ran_notes
    end

    test "ignores unknown source names while keeping the valid ones" do
      install_sources(%{
        "local_messages" => fn _, _, _ -> [hit("local_messages", "m1")] end,
        "local_notes" => fn _, _, _ -> [hit("local_notes", "n1")] end
      })

      {:ok, result} =
        Tools.execute("recall_anywhere", %{
          "user_id" => "u@example.com",
          "query" => "x",
          "sources" => ["local_messages", "nonsense_source"]
        })

      # `nonsense_source` is dropped; only `local_messages` is searched.
      assert result.sources_searched == ["local_messages"]
      assert Enum.map(result.results, & &1.id) == ["m1"]
    end
  end

  describe "3-second source budget" do
    test "drops slow sources after the budget and reports them in partial_sources" do
      install_sources(%{
        "local_messages" => fn _, _, _ -> [hit("local_messages", "fast")] end,
        "local_notes" => fn _, _, _ ->
          # Exceed the 3s budget — task will be killed.
          Process.sleep(4_000)
          [hit("local_notes", "slow")]
        end
      })

      started = System.monotonic_time(:millisecond)

      {:ok, result} =
        Tools.execute("recall_anywhere", %{
          "user_id" => "u@example.com",
          "query" => "x",
          "sources" => ["local_messages", "local_notes"]
        })

      elapsed = System.monotonic_time(:millisecond) - started

      assert "local_messages" in result.sources_searched
      assert "local_notes" in result.partial_sources
      assert Enum.map(result.results, & &1.id) == ["fast"]

      # The whole call should complete within ~3.5s — proves the budget was
      # enforced and a slow source did not block the response indefinitely.
      assert elapsed < 3_800
    end

    @tag :slow
    test "a crashing source does not bring the whole call down" do
      install_sources(%{
        "local_messages" => fn _, _, _ -> [hit("local_messages", "ok")] end,
        "local_notes" => fn _, _, _ -> raise "boom" end
      })

      {:ok, result} =
        Tools.execute("recall_anywhere", %{
          "user_id" => "u@example.com",
          "query" => "x",
          "sources" => ["local_messages", "local_notes"]
        })

      assert Enum.map(result.results, & &1.id) == ["ok"]
      assert "local_messages" in result.sources_searched
    end
  end

  describe "argument validation" do
    test "rejects missing query" do
      assert {:error, message} =
               Tools.execute("recall_anywhere", %{"user_id" => "u@example.com"})

      assert message =~ "query is required"
    end

    test "rejects missing user_id" do
      assert {:error, _} = Tools.execute("recall_anywhere", %{"query" => "x"})
    end
  end

  describe "telemetry" do
    test "emits [:maraithon, :tools, :recall_anywhere] with expected measurements" do
      install_sources(%{
        "local_messages" => fn _, _, _ -> [hit("local_messages", "m1")] end
      })

      test_pid = self()
      handler_id = "recall-anywhere-test-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler_id,
        [:maraithon, :tools, :recall_anywhere],
        fn _event, measurements, metadata, _config ->
          send(test_pid, {:telemetry, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      _ =
        Tools.execute("recall_anywhere", %{
          "user_id" => "u@example.com",
          "query" => "abcdef",
          "sources" => ["local_messages"]
        })

      assert_receive {:telemetry, measurements, metadata}, 1_000

      assert measurements.query_length == 6
      assert measurements.result_count == 1
      assert is_integer(measurements.latency_ms)
      assert metadata.user_id == "u@example.com"
      assert "local_messages" in metadata.sources_searched
    end
  end
end
