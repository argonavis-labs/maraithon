defmodule MaraithonWeb.SettingsHTMLTest do
  use ExUnit.Case, async: true

  alias MaraithonWeb.SettingsHTML

  test "setup badges use product copy" do
    assert SettingsHTML.setting_badge_label(true) == "ready"
    assert SettingsHTML.setting_badge_label(false) == "needs setup"
  end
end
