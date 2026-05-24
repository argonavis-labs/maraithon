defmodule Mix.Tasks.Maraithon.VerifyTelegramChat do
  @moduledoc """
  Runs the Telegram assistant scenario verification loop.
  """

  use Mix.Task

  @shortdoc "Verify Telegram chat scenarios against the live assistant path"

  @impl Mix.Task
  def run(args) do
    Logger.configure(level: :warning)
    Application.put_env(:maraithon, :start_background_workers, false)
    Mix.Task.run("app.start")

    {opts, _rest, _invalid} =
      OptionParser.parse(args,
        strict: [
          attempts: :integer,
          minimum_score: :integer,
          user_id: :string,
          chat_id: :string,
          keep_data: :boolean
        ]
      )

    verification_opts =
      []
      |> maybe_put(:max_attempts, opts[:attempts])
      |> maybe_put(:minimum_score, opts[:minimum_score])
      |> maybe_put(:user_id, opts[:user_id])
      |> maybe_put(:chat_id, opts[:chat_id])
      |> Keyword.put(:cleanup?, opts[:keep_data] != true)

    result = Maraithon.TelegramAssistant.VerificationLoop.run_until_pass!(verification_opts)

    Mix.shell().info(Maraithon.TelegramAssistant.VerificationLoop.format_summary(result))
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)
end
