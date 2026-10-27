defmodule Maraithon.Tools.RecallAnywhereBlendedTest do
  @moduledoc """
  Tests for the v5 blended-score semantics on `recall_anywhere`. Verifies:

    * the weight slate is the documented 0.5 / 0.3 / 0.15 / 0.05
    * `score_hit/2` blends semantic_score into the final score
    * `merge_hits/2` joins substring + semantic results without
      double-counting

  The `:recall_anywhere_sources` override seam lets us pin synthetic
  hits without booting OpenAI or pgvector.
  """

  use ExUnit.Case, async: false

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

  defp now_dt, do: DateTime.utc_now()

  describe "weight slate" do
    test "documents the new 0.5 / 0.3 / 0.15 / 0.05 weights" do
      weights = RecallAnywhereHelpers.weights()
      assert weights.semantic == 0.5
      assert weights.substring_quality == 0.3
      assert weights.recency == 0.15
      assert weights.source_trust == 0.05
    end

    test "weights sum to 1.0" do
      weights = RecallAnywhereHelpers.weights()

      total =
        weights.semantic + weights.substring_quality + weights.recency + weights.source_trust

      assert_in_delta total, 1.0, 0.0001
    end
  end

  describe "score_hit/2 with semantic_score" do
    test "high semantic_score dominates over weak substring match" do
      now = now_dt()

      strong_semantic = %{
        source: "local_messages",
        id: "a",
        title: "anything",
        snippet: "x",
        timestamp: now,
        match_field: :none,
        semantic_score: 1.0
      }

      weak_substring = %{
        source: "local_messages",
        id: "b",
        title: "anything",
        snippet: "x",
        timestamp: now,
        match_field: :title,
        semantic_score: 0.0
      }

      a = RecallAnywhereHelpers.score_hit(strong_semantic, now)
      b = RecallAnywhereHelpers.score_hit(weak_substring, now)

      # semantic 1.0 + substring floor (0.2) + recency 1.0 + trust 1.0
      #   = 0.5*1.0 + 0.3*0.2 + 0.15*1.0 + 0.05*1.0 = 0.76
      # substring title (1.0) + semantic 0 + recency 1.0 + trust 1.0
      #   = 0.5*0.0 + 0.3*1.0 + 0.15*1.0 + 0.05*1.0 = 0.5
      assert a.score > b.score
      assert_in_delta a.score, 0.76, 0.01
      assert_in_delta b.score, 0.5, 0.01
    end

    test "missing semantic_score defaults to 0.0" do
      now = now_dt()

      hit = %{
        source: "local_messages",
        id: "a",
        title: "x",
        snippet: nil,
        timestamp: now,
        match_field: :title
      }

      scored = RecallAnywhereHelpers.score_hit(hit, now)
      assert scored.semantic_score == 0.0
    end

    test "semantic_score is clamped to [0,1]" do
      now = now_dt()

      over = %{
        source: "local_notes",
        id: "a",
        title: "x",
        snippet: nil,
        timestamp: now,
        match_field: :none,
        semantic_score: 1.5
      }

      under = %{
        source: "local_notes",
        id: "b",
        title: "x",
        snippet: nil,
        timestamp: now,
        match_field: :none,
        semantic_score: -0.7
      }

      assert RecallAnywhereHelpers.score_hit(over, now).semantic_score == 1.0
      assert RecallAnywhereHelpers.score_hit(under, now).semantic_score == 0.0
    end
  end

  describe "merge_hits/2" do
    test "merges substring + semantic hits by (source, id) and preserves match_field" do
      substring = [
        %{source: "local_messages", id: "a", title: "t", snippet: "s", match_field: :title}
      ]

      semantic = [
        %{
          source: "local_messages",
          id: "a",
          title: "t",
          snippet: "s",
          match_field: :none,
          semantic_score: 0.9
        }
      ]

      [merged] = RecallAnywhereHelpers.merge_hits(substring, semantic)

      assert merged.match_field == :title
      assert merged.semantic_score == 0.9
    end

    test "semantic-only hits keep their semantic_score and default match_field" do
      substring = []

      semantic = [
        %{
          source: "local_messages",
          id: "b",
          title: "t",
          snippet: "s",
          semantic_score: 0.7
        }
      ]

      [merged] = RecallAnywhereHelpers.merge_hits(substring, semantic)
      assert merged.semantic_score == 0.7
      assert merged.match_field == :none
    end

    test "substring-only hits get semantic_score: 0.0 floor" do
      substring = [
        %{source: "local_notes", id: "c", title: "t", snippet: "s", match_field: :snippet}
      ]

      semantic = []

      [merged] = RecallAnywhereHelpers.merge_hits(substring, semantic)
      assert merged.semantic_score == 0.0
      assert merged.match_field == :snippet
    end

    test "different ids stay distinct" do
      substring = [
        %{source: "local_messages", id: "a", title: "t", snippet: "s", match_field: :title}
      ]

      semantic = [
        %{
          source: "local_messages",
          id: "b",
          title: "t",
          snippet: "s",
          semantic_score: 0.8
        }
      ]

      merged = RecallAnywhereHelpers.merge_hits(substring, semantic)
      assert length(merged) == 2
      assert Enum.find(merged, &(&1.id == "a")).match_field == :title
      assert Enum.find(merged, &(&1.id == "b")).semantic_score == 0.8
    end
  end

  describe "Tools.execute/2 — semantic_score reaches the final ranking" do
    test "a semantic-only hit can outrank a substring-only hit at the same recency/trust" do
      ts = DateTime.utc_now()

      install_sources(%{
        "local_messages" => fn _u, _q, _o ->
          [
            %{
              source: "local_messages",
              id: "sem",
              title: "irrelevant",
              snippet: "irrelevant",
              timestamp: ts,
              # not a substring match
              match_field: :none,
              semantic_score: 1.0
            },
            %{
              source: "local_messages",
              id: "sub",
              title: "x",
              snippet: nil,
              timestamp: ts,
              match_field: :title,
              semantic_score: 0.0
            }
          ]
        end
      })

      {:ok, result} =
        Tools.execute("recall_anywhere", %{
          "user_id" => "u@example.com",
          "query" => "anything",
          "sources" => ["local_messages"]
        })

      ids = Enum.map(result.results, & &1.id)
      assert ids == ["sem", "sub"]
    end

    test "results include the semantic_score component breakdown" do
      install_sources(%{
        "local_messages" => fn _, _, _ ->
          [
            %{
              source: "local_messages",
              id: "a",
              title: "t",
              snippet: "s",
              timestamp: DateTime.utc_now(),
              match_field: :title,
              semantic_score: 0.5
            }
          ]
        end
      })

      {:ok, %{results: [hit]}} =
        Tools.execute("recall_anywhere", %{
          "user_id" => "u@example.com",
          "query" => "q",
          "sources" => ["local_messages"]
        })

      assert hit.semantic_score == 0.5
      assert hit.substring_quality == 1.0
    end
  end
end
