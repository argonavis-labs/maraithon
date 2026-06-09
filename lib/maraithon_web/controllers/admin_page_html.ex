defmodule MaraithonWeb.AdminPageHTML do
  @moduledoc """
  Templates for the small set of admin-only HTML pages owned by
  `MaraithonWeb.AdminPageController`.
  """

  use MaraithonWeb, :html

  embed_templates "admin_page_html/*"

  @doc """
  Pretty-prints a `last_seen_at` timestamp as a relative phrase
  ("3m ago", "yesterday"). Falls back to "never" for nil.
  """
  def relative_time(nil), do: "never"

  def relative_time(%DateTime{} = dt) do
    diff = DateTime.diff(DateTime.utc_now(), dt, :second)

    cond do
      diff < 0 -> "just now"
      diff < 60 -> "just now"
      diff < 3_600 -> "#{div(diff, 60)}m ago"
      diff < 86_400 -> "#{div(diff, 3_600)}h ago"
      diff < 7 * 86_400 -> "#{div(diff, 86_400)}d ago"
      true -> Calendar.strftime(dt, "%Y-%m-%d")
    end
  end

  @doc """
  Renders a device's revocation state as a small Catalyst-style badge.
  """
  def device_state_badge_class(nil),
    do:
      "inline-flex rounded-md bg-emerald-500/15 px-1.5 py-0.5 text-xs/5 font-medium text-emerald-700"

  def device_state_badge_class(%DateTime{}),
    do: "inline-flex rounded-md bg-zinc-500/15 px-1.5 py-0.5 text-xs/5 font-medium text-zinc-700"

  def device_state_label(nil), do: "active"
  def device_state_label(%DateTime{}), do: "revoked"

  @source_labels [
    {:messages_count, "Messages"},
    {:notes_count, "Notes"},
    {:voice_memos_count, "Voice memos"},
    {:calendar_events_count, "Calendar"},
    {:reminders_count, "Reminders"},
    {:contacts_count, "Contacts"},
    {:files_count, "Files"},
    {:browser_visits_count, "Browser"}
  ]

  def source_labels, do: @source_labels
end
