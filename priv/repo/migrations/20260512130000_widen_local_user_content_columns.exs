defmodule Maraithon.Repo.Migrations.WidenLocalUserContentColumns do
  @moduledoc """
  Widens varchar(255) columns that hold user-controlled strings to
  unbounded `:text` so a long filename / chat name / folder name / file
  path doesn't trip Postgres `22001 string_data_right_truncation`.

  We previously hit this on `local_files.local_id` (deep filesystem
  paths) — and because the insert raised inside the Phoenix Channel
  GenServer, the whole device channel died and took every other
  source's pushes with it. Widening removes the failure mode entirely;
  the channel-level `try/rescue` we're shipping alongside this catches
  any remaining surprises so one bad row can never crash the channel.

  Server-controlled columns (`guid`, `source`, `user_id`, `key_id`)
  stay at varchar(255) — those are bounded by our own code.
  """

  use Ecto.Migration

  @widenings %{
    "local_files" => ~w(local_id extension mime_type)a,
    "local_messages" => ~w(chat_display_name chat_key chat_style local_id)a,
    "local_notes" => ~w(folder local_id body_format)a,
    "local_reminders" => ~w(list_name list_color local_id url_attachment)a,
    "local_voice_memos" => ~w(local_id audio_mime transcript_engine transcript_lang)a,
    "local_calendar_events" => ~w()a
  }

  def up do
    for {table, cols} <- @widenings, col <- cols do
      execute "ALTER TABLE #{table} ALTER COLUMN #{col} TYPE text"
    end
  end

  def down do
    for {table, cols} <- @widenings, col <- cols do
      execute "ALTER TABLE #{table} ALTER COLUMN #{col} TYPE varchar(255)"
    end
  end
end
