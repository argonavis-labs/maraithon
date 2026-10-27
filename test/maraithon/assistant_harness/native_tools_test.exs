defmodule Maraithon.AssistantHarness.NativeToolsTest do
  use ExUnit.Case, async: true
  alias Maraithon.AssistantHarness.NativeTools

  test "uses Muse-compatible automatic selection and preserves tool call/result pairs" do
    call = call("list_people", %{"query" => "Mohit"})

    exchange = [
      %{"role" => "assistant", "tool_calls" => [call]},
      %{"role" => "tool", "tool_call_id" => call["id"], "content" => "[]"}
    ]

    request =
      NativeTools.request(%{"messages" => []}, %{tools: [tool()], _native_exchanges: [exchange]})

    assert request["tool_choice"] == "auto"
    assert request["messages"] == exchange

    assert Enum.map(request["tools"], &get_in(&1, ["function", "name"])) == [
             "list_people",
             "maraithon_finish"
           ]

    assert {:ok, %{"status" => "tool_calls", "tool_calls" => [%{"tool" => "list_people"}]}} =
             NativeTools.decode(
               %{message: %{"tool_calls" => [call]}, finish_reason: "tool_calls"},
               request
             )
  end

  test "accepts a plain final reply without executing any action" do
    assert {:ok,
            %{"status" => "final", "assistant_message" => "Which Mohit?", "tool_calls" => []}} =
             NativeTools.decode(
               %{message: %{"content" => "Which Mohit?"}, finish_reason: "stop"},
               %{}
             )
  end

  test "rejects unknown actions, incomplete responses and mixed final/action calls" do
    request = NativeTools.request(%{"messages" => []}, %{tools: [tool()]})

    for response <- [
          %{message: %{"content" => ""}, finish_reason: "stop"},
          %{message: %{"content" => "Partial"}, finish_reason: "length"},
          %{
            message: %{"content" => "Done", "tool_calls" => [call("list_people", %{})]},
            finish_reason: "stop"
          },
          %{message: %{"tool_calls" => [call("send_email", %{})]}, finish_reason: "tool_calls"},
          %{
            message: %{
              "tool_calls" => [
                call("list_people", %{}),
                call("maraithon_finish", %{"assistant_message" => "Done"})
              ]
            },
            finish_reason: "tool_calls"
          }
        ] do
      assert {:error, _} = NativeTools.decode(response, request)
    end
  end

  defp tool, do: %{"name" => "list_people", "parameters" => %{"type" => "object"}}

  defp call(name, args),
    do: %{
      "id" => "call-" <> name,
      "type" => "function",
      "function" => %{"name" => name, "arguments" => Jason.encode!(args)}
    }
end
