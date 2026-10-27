defmodule Maraithon.Companion.ReleasesTest do
  use Maraithon.DataCase, async: true

  alias Maraithon.Companion.Release
  alias Maraithon.Companion.Releases

  defp valid_attrs(overrides \\ %{}) do
    version = Map.get(overrides, :version, "0.#{System.unique_integer([:positive])}.0")

    Map.merge(
      %{
        version: version,
        build_number: "1",
        url: "https://maraithon.com/releases/Maraithon-#{version}.dmg",
        signature: "MC0CFQDSparkleEdDSAsignaturePlaceholder==",
        notes_markdown: "First release."
      },
      overrides
    )
  end

  describe "publish/1" do
    test "inserts a row with a default released_at and round-trips" do
      attrs = valid_attrs()

      assert {:ok, %Release{} = release} = Releases.publish(attrs)
      assert release.version == attrs.version
      assert release.build_number == "1"
      assert release.url =~ "https://"
      assert release.signature
      assert release.released_at
    end

    test "rejects duplicate versions" do
      attrs = valid_attrs(%{version: "9.9.9"})
      assert {:ok, _} = Releases.publish(attrs)
      assert {:error, changeset} = Releases.publish(attrs)
      assert %{version: ["has already been taken"]} = errors_on(changeset)
    end

    test "rejects non-semver versions" do
      attrs = valid_attrs(%{version: "not-a-version"})
      assert {:error, changeset} = Releases.publish(attrs)
      assert errors_on(changeset).version != []
    end

    test "rejects non-URL urls" do
      attrs = valid_attrs(%{url: "not-a-url"})
      assert {:error, changeset} = Releases.publish(attrs)
      assert errors_on(changeset).url != []
    end
  end

  describe "list/1 and latest/0" do
    test "orders newest-first" do
      {:ok, r1} =
        Releases.publish(
          valid_attrs(%{
            version: "0.0.1",
            released_at: ~U[2026-01-01 00:00:00.000000Z]
          })
        )

      {:ok, r2} =
        Releases.publish(
          valid_attrs(%{
            version: "0.0.2",
            released_at: ~U[2026-02-01 00:00:00.000000Z]
          })
        )

      assert [first, second | _] = Releases.list()
      assert first.id == r2.id
      assert second.id == r1.id

      assert Releases.latest().id == r2.id
    end

    test "returns nil when no releases are published" do
      assert Releases.latest() == nil
    end
  end

  describe "get_by_version/1" do
    test "returns the matching release or nil" do
      {:ok, release} = Releases.publish(valid_attrs(%{version: "1.2.3"}))
      assert Releases.get_by_version("1.2.3").id == release.id
      assert Releases.get_by_version("does.not.exist") == nil
    end
  end
end
