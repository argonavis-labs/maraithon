defmodule MaraithonWeb.AgentActionCopyTest do
  use ExUnit.Case, async: true

  alias MaraithonWeb.AgentActionCopy

  test "success copy uses automation names without internal ids" do
    assert AgentActionCopy.success(:create, "Board prep agent") == "Board prep automation created"
    assert AgentActionCopy.success(:update, "Chief of Staff") == "Chief of Staff updated"
    assert AgentActionCopy.success(:create, "unnamed_agent") == "Automation created"
    assert AgentActionCopy.success(:update, nil) == "Automation updated"
  end

  test "preserves human validation details" do
    assert AgentActionCopy.error(:install, "Choose a template before creating the agent.") ==
             "Could not install that automation. Choose a template before creating the automation."
  end

  test "renders changeset validation without failure jargon" do
    changeset =
      {%{}, %{name: :string}}
      |> Ecto.Changeset.cast(%{}, [:name])
      |> Ecto.Changeset.validate_required([:name])

    assert AgentActionCopy.error(:create, changeset) ==
             "Could not create that automation. Name can't be blank."
  end

  test "hides internal automation action reasons" do
    assert AgentActionCopy.error(:create, "DBConnection.ConnectionError token abc123") ==
             "Could not create that automation. Review the settings and try again."

    assert AgentActionCopy.error(:start, {:supervisor, :timeout}) ==
             "Could not start that automation. Refresh the page and try again."

    assert AgentActionCopy.error(:delete, {:repo, :not_found}) ==
             "Could not remove that automation. Refresh the page and try again."
  end

  test "hides marketplace internals" do
    copy = AgentActionCopy.marketplace_error({:invalid_agent_manifest, [model: "missing"]})

    assert copy == "Some automation templates are unavailable because setup needs attention."

    refute copy =~ "invalid_agent_manifest"
    refute copy =~ "agent templates"
    refute copy =~ "missing"
    refute copy =~ "model"
  end
end
