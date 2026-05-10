defmodule Maraithon.NormalizationTest do
  use ExUnit.Case, async: true

  alias Maraithon.Normalization

  test "stringify_keys preserves structs while normalizing nested maps" do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    assert %{
             "outer" => %{"inner" => "value", "at" => ^now},
             "items" => [%{"name" => "one"}]
           } =
             Normalization.stringify_keys(%{
               outer: %{inner: "value", at: now},
               items: [%{name: "one"}]
             })
  end

  test "read helpers normalize mixed key shapes" do
    attrs = %{
      "metadata" => %{foo: "bar"},
      user_id: " kent ",
      allowed: [" read ", :write, "", "read"],
      ttl: "15"
    }

    assert Normalization.read_string(attrs, :user_id) == "kent"
    assert Normalization.read_map(attrs, :metadata) == %{"foo" => "bar"}
    assert Normalization.read_list(attrs, :allowed) == ["read", "write"]
    assert Normalization.read_integer(attrs, :ttl) == 15
  end

  test "normalize_json_value emits JSON-safe map keys and temporal values" do
    at = ~U[2026-05-10 12:00:00Z]

    assert %{"at" => "2026-05-10T12:00:00Z", "status" => "ok"} =
             Normalization.normalize_json_value(%{at: at, status: :ok})
  end
end
