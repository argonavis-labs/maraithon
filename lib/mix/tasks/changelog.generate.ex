defmodule Mix.Tasks.Changelog.Generate do
  @moduledoc """
  Generates `priv/changelog.json` from `git log`, grouped by day.

  We bake the changelog into a static asset at build time because the
  production container does not ship `.git/`. Run this locally before
  shipping a release so the in-app `/changelog` surface is up-to-date.

      mix changelog.generate

  Filters out merge commits and conventional-commit "chore/test/ci"
  prefixes. Keeps the latest 200 commits and trims the body to the
  first paragraph for a consumer-grade summary.
  """

  use Mix.Task

  @shortdoc "Generate priv/changelog.json from git log"

  @output_path "priv/changelog.json"
  @max_commits 200

  @skip_subject_prefixes ~w(chore: ci: test: wip: merge bump:)

  @impl Mix.Task
  def run(_args) do
    case System.cmd("git", git_log_args(), stderr_to_stdout: true) do
      {output, 0} ->
        commits = parse(output)

        json =
          %{
            generated_at: DateTime.utc_now() |> DateTime.to_iso8601(),
            total: length(commits),
            days: group_by_day(commits)
          }
          |> Jason.encode!(pretty: true)

        File.write!(@output_path, json)
        Mix.shell().info("Wrote #{length(commits)} commits to #{@output_path}")

      {error, _code} ->
        Mix.raise("git log failed: #{error}")
    end
  end

  defp git_log_args do
    [
      "log",
      "--no-merges",
      "-n",
      "#{@max_commits}",
      "--pretty=format:%H%x1f%aI%x1f%s%x1f%b%x1e"
    ]
  end

  defp parse(output) do
    output
    |> String.split("\x1e", trim: true)
    |> Enum.map(&parse_record/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.reject(&skip?/1)
  end

  defp parse_record(record) do
    case String.split(String.trim(record), "\x1f", parts: 4) do
      [sha, iso, subject, body] ->
        with {:ok, dt, _} <- DateTime.from_iso8601(iso) do
          %{
            sha: String.slice(sha, 0, 7),
            datetime: DateTime.to_iso8601(dt),
            date: DateTime.to_date(dt) |> Date.to_iso8601(),
            title: clean_subject(subject),
            summary: first_paragraph(body)
          }
        else
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp clean_subject(subject) do
    subject
    |> String.trim()
    |> String.replace(~r/\s+/, " ")
  end

  defp first_paragraph(""), do: nil

  defp first_paragraph(body) do
    body
    |> String.split("\n\n", parts: 2)
    |> List.first()
    |> String.trim()
    |> String.replace(~r/\s+/, " ")
    |> case do
      "" -> nil
      paragraph -> paragraph
    end
  end

  defp skip?(%{title: title}) do
    lower = String.downcase(title)

    Enum.any?(@skip_subject_prefixes, &String.starts_with?(lower, &1)) or
      String.starts_with?(lower, "co-authored-by")
  end

  defp group_by_day(commits) do
    commits
    |> Enum.group_by(& &1.date)
    |> Enum.map(fn {date, entries} ->
      %{
        date: date,
        entries: Enum.sort_by(entries, & &1.datetime, :desc)
      }
    end)
    |> Enum.sort_by(& &1.date, :desc)
  end
end
