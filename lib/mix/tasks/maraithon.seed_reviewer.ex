defmodule Mix.Tasks.Maraithon.SeedReviewer do
  @shortdoc "Seed the App Store reviewer's demo account with representative data"

  @moduledoc """
  Seeds the App Store review demo account so Apple's reviewer lands in a
  populated account (Today / Work / People / Chat) instead of an empty shell.

      mix maraithon.seed_reviewer

  Delegates to `Maraithon.ReviewerSeed.seed/0`. The reviewer email defaults to
  `APP_REVIEW_BYPASS_EMAIL`, falling back to `reviewer@maraithon.com`. Run once
  after deploy — NOT on every boot. Idempotent.

  On a prod release (no Mix), run the seeding directly on the running node:

      bin/maraithon rpc 'Maraithon.ReviewerSeed.seed()'
  """

  use Mix.Task

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("app.start")

    case Maraithon.ReviewerSeed.seed() do
      {:ok, user_id} ->
        Mix.shell().info("Seeded reviewer demo account for #{user_id}.")

      {:error, reason} ->
        Mix.raise("Could not seed reviewer account: #{inspect(reason)}")
    end
  end
end
