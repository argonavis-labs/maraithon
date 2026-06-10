defmodule Maraithon.Companion.Release do
  @moduledoc """
  A single published version of the Maraithon Mac companion app,
  served to installed apps via the Sparkle appcast feed.

  Each row records the metadata Sparkle needs to fetch and verify the
  update:

    * `version`           — semver string (e.g. `0.1.1`).
    * `build_number`      — monotonically increasing build counter, used
      by Sparkle as `sparkle:version` (the canonical comparison key).
    * `url`               — fully-qualified URL where the signed,
      notarized, stapled DMG is hosted. Today this is a Fly.io volume
      served by the Phoenix app (e.g. `https://maraithon.fly.dev/releases/Maraithon-0.1.1.dmg`),
      but it can equally point at S3 / a CDN in the future.
    * `signature`         — Sparkle EdDSA signature emitted by
      `bin/sign_update` against the DMG bytes.
    * `min_system_version` — optional minimum macOS version (e.g. `14.0`).
    * `notes_markdown`    — release notes rendered into the appcast as
      `<sparkle:releaseNotesLink>`/`<description>` text.
    * `released_at`       — publication timestamp; rendered as `pubDate`.

  The actual DMG bytes live wherever `url` points — this table only
  stores pointers and signatures.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "companion_releases" do
    field :version, :string
    field :build_number, :string
    field :url, :string
    field :signature, :string
    field :min_system_version, :string
    field :notes_markdown, :string
    field :released_at, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec)
  end

  @required_fields [:version, :build_number, :url, :signature, :released_at]
  @optional_fields [:min_system_version, :notes_markdown]

  def changeset(release, attrs) do
    release
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_format(:version, ~r/^\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.\-]+)?$/,
      message: "must be a semver string like 0.1.1"
    )
    |> validate_format(:url, ~r{^https?://}, message: "must be an absolute URL")
    |> unique_constraint(:version)
  end
end
