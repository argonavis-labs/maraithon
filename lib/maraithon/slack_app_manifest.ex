defmodule Maraithon.SlackAppManifest do
  @moduledoc """
  Versioned Slack app configuration contract.

  The manifest is safe to commit: it contains URLs, scopes, and subscriptions,
  but no Slack credentials. `verify/0` keeps the external Slack configuration
  artifact aligned with the OAuth scopes and coverage-critical message events
  expected by the application.
  """

  alias Maraithon.OAuth.Slack, as: SlackOAuth

  @redirect_url "https://maraithon.com/auth/slack/callback"
  @event_request_url "https://maraithon.com/webhooks/slack"
  @required_user_events ~w(message.channels message.groups message.im message.mpim)
  @required_bot_events ~w(
    app_mention
    reaction_added
    reaction_removed
    member_joined_channel
    member_left_channel
  )

  def path, do: Application.app_dir(:maraithon, "priv/slack/app_manifest.json")

  def required_user_events, do: @required_user_events
  def required_bot_events, do: @required_bot_events

  @doc "Loads the committed Slack app manifest."
  def load do
    with {:ok, json} <- File.read(path()),
         {:ok, manifest} when is_map(manifest) <- Jason.decode(json) do
      {:ok, manifest}
    else
      {:ok, _invalid} -> {:error, ["manifest root must be a JSON object"]}
      {:error, %Jason.DecodeError{} = error} -> {:error, [Exception.message(error)]}
      {:error, reason} -> {:error, ["manifest could not be read: #{inspect(reason)}"]}
    end
  end

  @doc "Verifies exact OAuth, callback, and Events API alignment."
  def verify do
    with {:ok, manifest} <- load() do
      errors =
        []
        |> compare_list(
          "bot OAuth scopes",
          get_in(manifest, ["oauth_config", "scopes", "bot"]),
          SlackOAuth.default_scopes()
        )
        |> compare_list(
          "user OAuth scopes",
          get_in(manifest, ["oauth_config", "scopes", "user"]),
          SlackOAuth.default_user_scopes()
        )
        |> compare_list(
          "OAuth redirect URLs",
          get_in(manifest, ["oauth_config", "redirect_urls"]),
          [@redirect_url]
        )
        |> compare_value(
          "Events API request URL",
          get_in(manifest, ["settings", "event_subscriptions", "request_url"]),
          @event_request_url
        )
        |> compare_list(
          "user message events",
          get_in(manifest, ["settings", "event_subscriptions", "user_events"]),
          @required_user_events
        )
        |> compare_list(
          "bot events",
          get_in(manifest, ["settings", "event_subscriptions", "bot_events"]),
          @required_bot_events
        )
        |> compare_value(
          "Socket Mode",
          get_in(manifest, ["settings", "socket_mode_enabled"]),
          false
        )

      if errors == [], do: :ok, else: {:error, Enum.reverse(errors)}
    end
  end

  defp compare_list(errors, label, actual, expected) when is_list(actual) do
    if Enum.sort(actual) == Enum.sort(expected), do: errors, else: ["#{label} differ" | errors]
  end

  defp compare_list(errors, label, _actual, _expected),
    do: ["#{label} must be a list" | errors]

  defp compare_value(errors, _label, actual, expected) when actual == expected, do: errors
  defp compare_value(errors, label, _actual, _expected), do: ["#{label} differs" | errors]
end
