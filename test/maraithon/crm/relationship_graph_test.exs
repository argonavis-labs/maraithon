defmodule Maraithon.Crm.RelationshipGraphTest do
  use ExUnit.Case, async: true

  alias Maraithon.Crm.RelationshipGraph

  # The rooted construction: the user is a node, direct interactions are
  # user↔person edges, and the walk teleports back to the user.
  defp rooted_ranks(direct, person_edges) do
    user_edges = Map.new(direct, fn {person_id, mass} -> {{:user, person_id}, mass} end)
    edges = Map.merge(person_edges, user_edges)

    %{user: 1.0}
    |> RelationshipGraph.pagerank(edges)
    |> Map.delete(:user)
  end

  test "empty graph is a no-op" do
    assert RelationshipGraph.pagerank(%{}, %{}) == %{}
  end

  test "mass is conserved" do
    ranks =
      RelationshipGraph.pagerank(
        %{user: 1.0},
        %{{:user, "a"} => 5.0, {:user, "b"} => 1.0, {"a", "b"} => 2.0}
      )

    total = ranks |> Map.values() |> Enum.sum()
    assert_in_delta total, 1.0, 1.0e-6
  end

  test "direct interaction dominates a single shared thread" do
    ranks =
      rooted_ranks(
        %{"close_friend" => 10.0, "acquaintance" => 1.0},
        %{{"acquaintance", "close_friend"} => 3.0}
      )

    assert ranks["close_friend"] > ranks["acquaintance"]
  end

  test "network position lifts a hub over an equal-direct leaf" do
    ranks =
      rooted_ranks(
        %{"anchor" => 10.0, "hub" => 1.0, "leaf" => 1.0},
        %{{"anchor", "hub"} => 3.0, {"hub", "leaf"} => 1.0}
      )

    assert ranks["hub"] > ranks["leaf"]
  end

  test "a connected person outranks an equal-direct broadcaster with no edges" do
    ranks =
      rooted_ranks(
        %{"connected" => 5.0, "broadcaster" => 5.0, "colleague" => 2.0},
        %{{"colleague", "connected"} => 2.0}
      )

    assert ranks["connected"] > ranks["broadcaster"]
  end

  test "unreached nodes rank zero and are excluded" do
    ranks = rooted_ranks(%{"a" => 1.0}, %{})

    assert Map.keys(ranks) == ["a"]
  end
end
