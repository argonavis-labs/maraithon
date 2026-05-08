defmodule MaraithonWeb.SettingsHTML do
  use MaraithonWeb, :html

  embed_templates "settings_html/*"

  def setting_badge_class(true),
    do:
      "inline-flex rounded-md bg-emerald-500/15 px-1.5 py-0.5 text-xs/5 font-medium text-emerald-700"

  def setting_badge_class(false),
    do: "inline-flex rounded-md bg-rose-400/15 px-1.5 py-0.5 text-xs/5 font-medium text-rose-700"

  def setting_badge_label(true), do: "present"
  def setting_badge_label(false), do: "missing"
end
