defmodule Maraithon.TelegramAssistant.ToolboxTest do
  use ExUnit.Case, async: true

  alias Maraithon.TelegramAssistant.Toolbox

  @new_tools ~w(
    notes_search notes_get notes_list_recent
    voice_memos_search voice_memos_get voice_memos_list_recent
  )

  @messages_tools ~w(
    messages_search messages_get messages_list_recent messages_chats_recent
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

    test "exposes the four iMessage tools" do
      names =
        Toolbox.tool_definitions(%{})
        |> Enum.map(&Map.get(&1, "name"))

      for tool <- @messages_tools do
        assert tool in names, "expected #{tool} to be registered in the toolbox"
      end
    end

    test "exposes recall_anywhere as a unified open-ended search tool" do
      definitions =
        Toolbox.tool_definitions(%{})
        |> Map.new(fn definition -> {definition["name"], definition} end)

      definition = Map.get(definitions, "recall_anywhere")
      assert definition, "expected recall_anywhere to be registered in the toolbox"

      assert "query" in definition["parameters"]["required"]
      assert definition["parameters"]["properties"]["sources"]["type"] == "array"
      assert definition["parameters"]["properties"]["limit"]["type"] == "integer"
      assert definition["description"] =~ "open-ended"
    end

    test "each new tool exposes a non-empty description and input schema" do
      all_new = @new_tools ++ @messages_tools

      definitions =
        Toolbox.tool_definitions(%{})
        |> Enum.filter(fn definition -> definition["name"] in all_new end)

      assert length(definitions) == length(all_new)

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
      assert "query" in definitions["messages_search"]["parameters"]["required"]
      assert "message_id" in definitions["messages_get"]["parameters"]["required"]
    end
  end
end
