defmodule Maraithon.LocalSearchTest do
  use ExUnit.Case, async: true

  alias Maraithon.LocalSearch

  test "matches multi-word queries across separate local-source fields" do
    query = LocalSearch.compile("Matthew setup")

    assert LocalSearch.matches?(query, [
             "Matthew Raue",
             "Asked for pricing owner and the setup path before the next call."
           ])
  end

  test "requires signal instead of matching only stop words" do
    query = LocalSearch.compile("the and for")

    refute LocalSearch.matches?(query, [
             "A short note with only common words."
           ])
  end
end
