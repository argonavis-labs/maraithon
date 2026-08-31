defmodule Maraithon.SlackAppManifestTest do
  use ExUnit.Case, async: true

  alias Maraithon.SlackAppManifest

  test "committed manifest matches the coverage-critical Slack contract" do
    assert :ok = SlackAppManifest.verify()

    assert {:ok, manifest} = SlackAppManifest.load()

    assert get_in(manifest, ["settings", "event_subscriptions", "user_events"]) ==
             SlackAppManifest.required_user_events()

    assert get_in(manifest, ["settings", "event_subscriptions", "request_url"]) ==
             "https://maraithon.com/webhooks/slack"
  end
end
