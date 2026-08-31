defmodule Maraithon.Release do
  @moduledoc """
  Release tasks for running migrations.
  """

  @app :maraithon

  def migrate do
    load_app()

    for repo <- repos() do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end
  end

  def rollback(repo, version) do
    load_app()
    {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :down, to: version))
  end

  def validate_authorized_todo_launch do
    target = System.get_env("TODO_VALIDATION_USER", "")

    if target != "kent@runner.now" do
      raise "TODO_VALIDATION_USER is not the authorized launch account"
    end

    load_app()
    {:ok, _apps} = Application.ensure_all_started(:req)
    {:ok, vault} = Maraithon.Vault.start_link([])

    {:ok, tool_call_supervisor} =
      Task.Supervisor.start_link(name: Maraithon.Runtime.ToolCallSupervisor)

    try do
      for repo <- repos() do
        {:ok, result, _apps} =
          Ecto.Migrator.with_repo(repo, fn _repo ->
            case Maraithon.Todos.ProductionValidator.run(target) do
              {:ok, report} -> report
              {:error, reason} -> raise "Todo launch validation failed: #{reason}"
            end
          end)

        IO.puts("TODO_LAUNCH_VALIDATION=" <> Jason.encode!(result))
      end
    after
      Supervisor.stop(tool_call_supervisor)
      GenServer.stop(vault)
    end
  end

  defp repos do
    Application.fetch_env!(@app, :ecto_repos)
  end

  defp load_app do
    Application.load(@app)
  end
end
