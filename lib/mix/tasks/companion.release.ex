defmodule Mix.Tasks.Companion.Release do
  @moduledoc """
  Publish a new Maraithon Mac companion release into the appcast feed.

  Usage:

      mix companion.release \\
        --version 0.1.1 \\
        --build 2 \\
        --url https://maraithon.com/releases/Maraithon-0.1.1.dmg \\
        --signature "<EdDSA signature from sign_update>" \\
        --notes "Initial Sparkle release."

  Optional:

      --min-system 14.0           Minimum macOS version.
      --released-at 2026-05-10T12:00:00Z   Override pubDate (defaults to now).

  Alternatively, pass `--from-release-info build/release-info.json`
  (the JSON file emitted by `maraithon-mac/scripts/release.sh`) and the
  task will populate `--version`/`--build`/`--signature` from it.

  After insertion, `/companion/appcast.xml` will include the new
  release on the next request.
  """

  use Mix.Task

  alias Maraithon.Companion.Releases

  @shortdoc "Publish a Mac companion release to the appcast feed"

  @switches [
    version: :string,
    build: :string,
    url: :string,
    signature: :string,
    notes: :string,
    min_system: :string,
    released_at: :string,
    from_release_info: :string
  ]

  @impl true
  def run(args) do
    {opts, _argv, invalid} = OptionParser.parse(args, strict: @switches)

    if invalid != [] do
      Mix.raise(
        "Invalid options: #{Enum.map_join(invalid, ", ", fn {key, _value} -> "--#{key}" end)}"
      )
    end

    opts = maybe_merge_release_info(opts)

    version = required(opts, :version)
    build = required(opts, :build)
    url = required(opts, :url)
    signature = required(opts, :signature)

    released_at = parse_released_at(opts[:released_at])

    Mix.Task.run("app.start")

    attrs = %{
      version: version,
      build_number: build,
      url: url,
      signature: signature,
      min_system_version: opts[:min_system],
      notes_markdown: opts[:notes],
      released_at: released_at
    }

    case Releases.publish(attrs) do
      {:ok, release} ->
        Mix.shell().info("""
        Published release #{release.version} (build #{release.build_number}).
          url:       #{release.url}
          signature: #{String.slice(release.signature, 0, 24)}…
          pubDate:   #{DateTime.to_iso8601(release.released_at)}
        """)

      {:error, changeset} ->
        errors =
          Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
            Enum.reduce(opts, msg, fn {key, value}, acc ->
              String.replace(acc, "%{#{key}}", to_string(value))
            end)
          end)

        Mix.raise("Failed to publish release: #{inspect(errors)}")
    end
  end

  defp required(opts, key) do
    case opts[key] do
      nil -> Mix.raise("--#{String.replace(to_string(key), "_", "-")} is required")
      "" -> Mix.raise("--#{String.replace(to_string(key), "_", "-")} is required")
      value -> value
    end
  end

  defp parse_released_at(nil), do: DateTime.utc_now()
  defp parse_released_at(""), do: DateTime.utc_now()

  defp parse_released_at(iso) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, dt, _offset} -> dt
      {:error, reason} -> Mix.raise("Invalid --released-at: #{inspect(reason)}")
    end
  end

  defp maybe_merge_release_info(opts) do
    case opts[:from_release_info] do
      nil ->
        opts

      "" ->
        opts

      path ->
        case File.read(path) do
          {:ok, body} ->
            info = Jason.decode!(body)
            opts |> merge_release_info(info)

          {:error, reason} ->
            Mix.raise("Could not read --from-release-info #{path}: #{inspect(reason)}")
        end
    end
  end

  defp merge_release_info(opts, info) do
    Enum.reduce(
      [
        {:version, "version"},
        {:build, "build"},
        {:signature, "signature"},
        {:url, "url"}
      ],
      opts,
      fn {key, json_key}, acc ->
        case {acc[key], Map.get(info, json_key)} do
          {nil, value} when is_binary(value) and value != "" -> Keyword.put(acc, key, value)
          _ -> acc
        end
      end
    )
  end
end
