defmodule Maraithon.TelegramAssistant.ToolboxTest do
  use ExUnit.Case, async: true

  alias Maraithon.TelegramAssistant.Toolbox

  @new_tools ~w(
    notes_search notes_get notes_list_recent
    voice_memos_search voice_memos_get voice_memos_list_recent
  )

  describe "tool_definitions/1" do
    test "exposes the six Apple Notes and Voice Memos tools" do
      names =
        Toolbox.tool_definitions(%{})
        |> Enum.map(&Map.get(&1, "name"))

      for tool <- @new_tools do
        assert tool in names, "expected #{tool} to be registered in the toolbox"
      end
    end

    test "each new tool exposes a non-empty description and input schema" do
      definitions =
        Toolbox.tool_definitions(%{})
        |> Enum.filter(fn definition -> definition["name"] in @new_tools end)

      assert length(definitions) == length(@new_tools)

      for definition <- definitions do
        description = definition["description"]
        schema = definition["parameters"]

        assert is_binary(description) and description != "",
               "missing description for #{definition["name"]}"

        assert schema["type"] == "object",
               "expected object input schema for #{definition["name"]}"
      end
    end

    test "search and get tools require their primary argument" do
      definitions =
        Toolbox.tool_definitions(%{})
        |> Map.new(fn definition -> {definition["name"], definition} end)

      assert "query" in definitions["notes_search"]["parameters"]["required"]
      assert "note_id" in definitions["notes_get"]["parameters"]["required"]
      assert "query" in definitions["voice_memos_search"]["parameters"]["required"]
      assert "memo_id" in definitions["voice_memos_get"]["parameters"]["required"]
    end
  end
end
