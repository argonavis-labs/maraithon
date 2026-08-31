defmodule Mix.Tasks.Maraithon.Slack.Manifest.Verify do
  use Mix.Task

  @shortdoc "Verifies the committed Slack app manifest"

  @moduledoc """
  Verifies that the committed Slack app manifest exactly matches Maraithon's
  OAuth scopes, callback URLs, and coverage-critical Events API subscriptions.

      mix maraithon.slack.manifest.verify
  """

  @impl Mix.Task
  def run(_args) do
    case Maraithon.SlackAppManifest.verify() do
      :ok ->
        Mix.shell().info("Slack app manifest matches the application contract")

      {:error, errors} ->
        Mix.raise("Slack app manifest is invalid:\n- " <> Enum.join(errors, "\n- "))
    end
  end
end
