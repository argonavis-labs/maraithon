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
    assert AgentActionCopy.not_found() ==
             "That automation is no longer available. Refresh automations before continuing."

    assert AgentActionCopy.details_not_found() ==
             "Automation details are no longer available. Refresh automations before continuing."

    assert AgentActionCopy.already_active() == "That automation is already active."

    assert AgentActionCopy.error(:create, "DBConnection.ConnectionError token abc123") ==
             "Could not create that automation. Review the settings before saving."

    assert AgentActionCopy.error(:update, "OPENROUTER_API_KEY=sk-live client_secret=secret") ==
             "Could not update that automation. Review the settings before saving."

    assert AgentActionCopy.error(:install, "Authorization: Bearer sk-live request_id=req_123") ==
             "Could not install that automation. Review the launch details before installing."

    assert AgentActionCopy.error(:start, {:supervisor, :timeout}) ==
             "Could not start that automation. Refresh automations before starting it."

    assert AgentActionCopy.error(:delete, {:repo, :not_found}) ==
             "Could not remove that automation. Refresh automations before removing it."

    assert AgentActionCopy.error(:send_message, {:runtime, :stopped}) ==
             "Could not send that message. Start the automation before sending a message."

    copies = [
      AgentActionCopy.not_found(),
      AgentActionCopy.error(:create, "DBConnection.ConnectionError token abc123"),
      AgentActionCopy.error(:update, "OPENROUTER_API_KEY=sk-live client_secret=secret"),
      AgentActionCopy.error(:install, "Authorization: Bearer sk-live request_id=req_123"),
      AgentActionCopy.error(:start, {:supervisor, :timeout}),
      AgentActionCopy.error(:delete, {:repo, :not_found}),
      AgentActionCopy.error(:send_message, {:runtime, :stopped})
    ]

    refute Enum.any?(copies, &String.contains?(String.downcase(&1), "try again"))
    refute Enum.any?(copies, &String.contains?(&1, "OPENROUTER_API_KEY"))
    refute Enum.any?(copies, &String.contains?(&1, "client_secret"))
    refute Enum.any?(copies, &String.contains?(&1, "Bearer"))
    refute Enum.any?(copies, &String.contains?(&1, "request_id"))
  end

  test "hides marketplace internals" do
    copy = AgentActionCopy.marketplace_error({:invalid_agent_manifest, [model: "missing"]})

    assert copy ==
             "Some automation templates are unavailable because required connections need attention."

    refute copy =~ "invalid_agent_manifest"
    refute copy =~ "agent templates"
    refute copy =~ "missing"
    refute copy =~ "model"
  end
end
