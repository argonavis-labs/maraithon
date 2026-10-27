defmodule Maraithon.PromptBudgetTest do
  use ExUnit.Case, async: true

  alias Maraithon.PromptBudget

  test "returns an explicit drop sentinel below the empty-object byte floor" do
    assert PromptBudget.project_fields(%{"keep" => "value"}, ["keep"], 0) == nil
    assert PromptBudget.project_fields(%{"keep" => "value"}, ["keep"], 1) == nil
    assert PromptBudget.project_fields(%{"keep" => "value"}, [], 2) == %{}
  end

  test "truncates escaped and multibyte text without exceeding the byte budget" do
    value = String.duplicate("🙂\"\n", 20)

    for max_bytes <- 0..40 do
      truncated = PromptBudget.truncate_utf8(value, max_bytes)
      assert String.valid?(truncated)
      assert byte_size(truncated) <= max_bytes
    end
  end

  test "returns short values unchanged" do
    assert PromptBudget.truncate_utf8("already small", 100) == "already small"
  end

  test "sanitizes large invalid binaries with bounded output" do
    value = :binary.copy(<<255>>, 100_000)
    truncated = PromptBudget.truncate_utf8(value, 64)

    assert String.valid?(truncated)
    assert byte_size(truncated) <= 64
  end

  test "compacts colliding map keys deterministically" do
    first = Map.new([{"same", "string value"}, {:same, "atom value"}])
    second = Map.new([{:same, "atom value"}, {"same", "string value"}])

    assert PromptBudget.compact(first) == PromptBudget.compact(second)
    assert PromptBudget.compact(first)["same"] == "string value"
  end

  test "recursively retains bounded nested memory entries" do
    value = %{
      "count" => 20,
      "memories" =>
        Enum.map(1..20, fn index ->
          %{"id" => index, "content" => String.duplicate("remember this ", 100)}
        end),
      "summary" => "Relevant interruption guidance"
    }

    bounded = PromptBudget.bounded(value, 1_500)

    assert PromptBudget.encoded_bytes(bounded) <= 1_500
    assert is_list(bounded["memories"])
    assert bounded["memories"] != []
  end

  test "bounds JSON-escaped strings inside the encoded budget" do
    value = String.duplicate("\"\n🙂", 1_000)
    bounded = PromptBudget.encoded_string(value, 250)

    assert String.valid?(bounded)
    assert PromptBudget.encoded_bytes(bounded) <= 250
  end

  test "bounds deeply nested list and mixed structures by depth" do
    list_only = Enum.reduce(1..5_000, "leaf", fn _index, acc -> [acc] end)

    mixed =
      Enum.reduce(1..5_000, %{"leaf" => "value"}, fn index, acc ->
        if rem(index, 2) == 0, do: [acc], else: %{"nested" => acc}
      end)

    compact_list = PromptBudget.compact(list_only, max_depth: 6)
    compact_mixed = PromptBudget.compact(mixed, max_depth: 6)

    assert PromptBudget.encoded_bytes(compact_list) < 100
    assert PromptBudget.encoded_bytes(compact_mixed) < 500
    assert Jason.encode!(compact_list)
    assert Jason.encode!(compact_mixed)
  end

  test "compacts very wide maps with a fixed retained entry window" do
    wide =
      Map.new(20_000..1//-1, fn index ->
        {"key-#{index |> Integer.to_string() |> String.pad_leading(5, "0")}", index}
      end)

    compact = PromptBudget.compact(wide, map_entries: 20)

    assert map_size(compact) == 20

    assert Map.keys(compact) |> Enum.sort() ==
             Enum.map(1..20, fn index ->
               "key-#{index |> Integer.to_string() |> String.pad_leading(5, "0")}"
             end)
  end

  test "fails closed before traversing maps beyond the hard input width" do
    too_wide = Map.new(1..20_001, &{"key-#{&1}", &1})
    assert PromptBudget.compact(too_wide, map_entries: 20) == %{}
  end

  test "skips overlong or unsupported map keys without starving valid fields" do
    assert PromptBudget.compact(%{
             String.duplicate("k", 4_097) => "secret",
             "z" => "KEEP"
           }) == %{"z" => "KEEP"}

    assert PromptBudget.compact(%{{:tuple, "key"} => "secret", "z" => "KEEP"}) == %{
             "z" => "KEEP"
           }
  end

  test "clamps adversarial compact settings" do
    compact =
      PromptBudget.compact(
        %{"items" => Enum.map(1..1_000, &String.duplicate("x", &1))},
        list_items: 1_000_000,
        map_entries: 1_000_000,
        string_bytes: 1_000_000,
        max_depth: 1_000_000,
        key_bytes: 1_000_000
      )

    assert length(compact["items"]) == 100
    assert compact["items"] |> List.last() |> byte_size() <= 100
  end

  test "one oversized item cannot consume the budget reserved for later list items" do
    bounded =
      PromptBudget.bounded(
        [String.duplicate("\"", 1_000), "KEEP"],
        20,
        string_bytes: 5_000
      )

    assert PromptBudget.encoded_bytes(bounded) <= 20
    assert "KEEP" in bounded
  end

  test "one oversized map field cannot erase every later field" do
    bounded =
      PromptBudget.bounded(
        %{"a_huge" => String.duplicate("x", 5_000), "z_keep" => "KEEP"},
        40,
        string_bytes: 5_000
      )

    assert PromptBudget.encoded_bytes(bounded) <= 40
    assert bounded["z_keep"] == "KEEP"
  end

  test "a dropped long-key field cannot erase a later independently fitting field" do
    value = %{
      String.duplicate("a", 64) => String.duplicate("x", 5_000),
      "z" => "KEEP"
    }

    bounded = PromptBudget.bounded(value, 20, string_bytes: 5_000)

    assert PromptBudget.encoded_bytes(bounded) <= 20
    assert bounded["z"] == "KEEP"
  end
end
