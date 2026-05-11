defmodule Maraithon.Repo.Migrations.AddAudioAndTranscriptToLocalVoiceMemos do
  use Ecto.Migration

  def change do
    alter table(:local_voice_memos) do
      # Raw .m4a bytes as Postgres bytea. Nullable: not every record
      # carries audio (the file may have been > 5 MB and dropped on
      # ingest, or the row may pre-date v1.5).
      add :audio_bytes, :binary
      add :audio_truncated, :boolean, default: false, null: false
      add :audio_mime, :string, default: "audio/m4a"

      # Transcript fields. `transcript` is encrypted at rest via the
      # existing Cloak vault — same treatment as `title` / `snippet`.
      add :transcript, :binary
      add :transcript_engine, :string
      add :transcript_lang, :string
    end
  end
end
