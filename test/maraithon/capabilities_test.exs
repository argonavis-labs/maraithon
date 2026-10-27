defmodule Maraithon.CapabilitiesTest do
  use ExUnit.Case, async: true

  alias Maraithon.Capabilities
  alias Maraithon.Tools

  test "tools facade reads descriptors and policy metadata from the capability registry" do
    assert Tools.list() == Capabilities.tool_names()

    descriptor = Tools.describe(["gmail_send_message"]) |> List.first()

    assert descriptor.description =~ "Send a Gmail message"
    assert get_in(descriptor, [:annotations, "sideEffect"]) == "external_send"
    assert get_in(descriptor, [:annotations, "confirmationRequired"]) == true

    assert Capabilities.policy_metadata_for("gmail_send_message") == %{
             side_effect: "external_send",
             read_only?: false,
             destructive?: false,
             idempotent?: false,
             user_required?: true,
             confirmation_required?: true
           }
  end

  test "every registered tool has policy metadata and an input schema" do
    for tool <- Tools.list() do
      assert %{} = Capabilities.policy_metadata_for(tool)
      assert %{} = Capabilities.tool_descriptor(tool).input_schema
    end
  end

  test "connector registry covers required first-party sources" do
    assert Capabilities.required_connector_ids() == [
             "github",
             "gmail",
             "google",
             "google_calendar",
             "google_contacts",
             "linear",
             "notaui",
             "notion",
             "slack",
             "telegram",
             "whatsapp"
           ]

    assert Capabilities.connector_metadata_for("slack").tool_names |> Enum.sort() ==
             ~w(
               slack_get_thread_replies slack_list_conversations slack_list_messages
               slack_open_conversation slack_post_message slack_search_messages
             )
  end

  test "built-in resource coverage is derived from tool annotations" do
    todo_coverage =
      Capabilities.built_in_resource_coverage()
      |> Enum.find(&(&1.resource == "todos"))

    assert todo_coverage.resource_types == ["todo", "open_loop"]
    assert "get_todo" in todo_coverage.tools
    assert "update_todo" in todo_coverage.tools
    assert "delete_todo" in todo_coverage.tools
    assert "upsert_todos" in todo_coverage.operations["create"]
    assert "update_todo" in todo_coverage.operations["update"]
    assert "delete_todo" in todo_coverage.operations["delete"]

    assert Capabilities.operations_for_tools(["gmail_drafts"]) == %{
             "create" => ["gmail_drafts"],
             "delete" => ["gmail_drafts"],
             "read" => ["gmail_drafts"],
             "update" => ["gmail_drafts"]
           }
  end

  test "register helpers validate capability metadata without mutating runtime registry" do
    assert {:error, :missing_policy_metadata} =
             Capabilities.register_tool(%{
               name: "unsafe_runtime_tool",
               module: Example.Tool,
               description: "Invalid test tool"
             })

    assert {:ok, %{id: "test_connector", type: "connector"}} =
             Capabilities.register_connector(%{
               id: "test_connector",
               display_name: "Test Connector",
               provider: "test",
               tool_names: ["time"]
             })

    refute "unsafe_runtime_tool" in Tools.list()
  end
end
