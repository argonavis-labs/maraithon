defmodule Maraithon.Companion.Releases do
  @moduledoc """
  Context module for the `companion_releases` table.

  Drives the Sparkle appcast feed served at `/companion/appcast.xml`
  and the `mix companion.release` Mix task. The data model is
  intentionally minimal — one row per published version — and the
  context's job is just to insert rows and list them in publication
  order.
  """

  import Ecto.Query

  alias Maraithon.Companion.Release
  alias Maraithon.Repo

  @doc """
  Persists a new release row.

  `attrs` is a map matching `Release.changeset/2` — at minimum
  `version`, `build_number`, `url`, `signature`, and `released_at`.
  If `released_at` is missing the current time is used.
  """
  def publish(attrs) when is_map(attrs) do
    attrs = Map.put_new_lazy(attrs, :released_at, fn -> DateTime.utc_now() end)

    %Release{}
    |> Release.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Lists releases newest-first. Limit is best-effort — Sparkle does not
  need an unbounded history.
  """
  def list(opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)

    Repo.all(
      from release in Release,
        order_by: [desc: release.released_at, desc: release.inserted_at],
        limit: ^limit
    )
  end

  @doc """
  Latest release row, or `nil` if none are published yet.
  """
  def latest do
    Repo.one(
      from release in Release,
        order_by: [desc: release.released_at, desc: release.inserted_at],
        limit: 1
    )
  end

  @doc """
  Looks up a single release by semver string.
  """
  def get_by_version(version) when is_binary(version) do
    Repo.get_by(Release, version: version)
  end
end
