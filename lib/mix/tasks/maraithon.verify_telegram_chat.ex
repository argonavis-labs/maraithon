defmodule Mix.Tasks.Maraithon.VerifyTelegramChat do
  @moduledoc """
  Runs the Telegram assistant scenario verification loop.
  """

  use Mix.Task

  @shortdoc "Verify Telegram chat scenarios against the live assistant path"

  @impl Mix.Task
  def run(args) do
    Logger.configure(level: :warning)

    {opts, _rest, _invalid} =
      OptionParser.parse(args,
        strict: [
          attempts: :integer,
          minimum_score: :integer,
          user_id: :string,
          chat_id: :string,
          keep_data: :boolean,
          live_model: :boolean
        ]
      )

    Application.put_env(:maraithon, :start_background_workers, false)
    configure_quiet_repo_logging()

    unless opts[:live_model] == true do
      configure_deterministic_verification()
    end

    Mix.Task.run("app.start")

    unless opts[:live_model] == true do
      configure_deterministic_verification()
    end

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

  defp configure_quiet_repo_logging do
    repo_config = Application.get_env(:maraithon, Maraithon.Repo, [])

    Application.put_env(
      :maraithon,
      Maraithon.Repo,
      Keyword.put(repo_config, :log, false)
    )
  end

  defp configure_deterministic_verification do
    assistant_config = Application.get_env(:maraithon, :telegram_assistant, [])

    Application.put_env(
      :maraithon,
      :telegram_assistant,
      Keyword.put(
        assistant_config,
        :client_module,
        Maraithon.TelegramAssistant.VerificationClient
      )
    )

    todos_config = Application.get_env(:maraithon, :todos, [])

    Application.put_env(
      :maraithon,
      :todos,
      todos_config
      |> Keyword.put(
        :llm_complete,
        &Maraithon.TelegramAssistant.VerificationClient.todo_intelligence_complete/1
      )
      |> Keyword.put(:mock_llm_when_unconfigured, true)
    )
  end
end
