defmodule Mix.Tasks.Maraithon.ConversationPrivacy do
  @moduledoc """
  Operates only the additive Telegram conversation encryption rollout.

      mix maraithon.conversation_privacy preflight
      mix maraithon.conversation_privacy backfill --confirm --batch-size 100 --max-batches 20

  Ongoing retention runs exclusively through `Maraithon.PrivacyRetention`,
  which owns the fixed policy, PostgreSQL clock, exact authority, tenant cursor,
  metrics, and durable scheduling. User erasure runs exclusively through the
  central durable erasure lifecycle.
  """

  use Mix.Task

  alias Maraithon.TelegramConversations.Privacy

  @shortdoc "Preflight or backfill conversation payload encryption"
  @switches [batch_size: :integer, max_batches: :integer, confirm: :boolean]

  @impl Mix.Task
  def run(args) do
    {opts, argv, invalid} = OptionParser.parse(args, strict: @switches)

    if invalid != [] do
      Mix.raise("Invalid options: #{inspect(invalid)}")
    end

    start_storage!()

    case argv do
      ["preflight"] ->
        print(Privacy.preflight())

      ["backfill"] ->
        unless opts[:confirm] do
          Mix.raise("backfill requires --confirm after the non-rolling fleet is drained")
        end

        backfill_opts =
          opts
          |> Keyword.delete(:confirm)
          |> Keyword.put(:confirmation, "NON_ROLLING_FLEET_DRAINED")

        case Privacy.backfill(backfill_opts) do
          {:ok, result} ->
            print(result)

          {:error, reason, partial} ->
            Mix.raise("Backfill failed: #{inspect(reason)} #{inspect(partial)}")

          {:error, reason} ->
            Mix.raise("Backfill failed: #{inspect(reason)}")
        end

      _other ->
        Mix.raise(usage())
    end
  end

  defp start_storage! do
    Mix.Task.run("app.config")

    case Application.ensure_all_started(:ecto_sql) do
      {:ok, _apps} -> :ok
      {:error, _reason} -> Mix.raise("could not start privacy storage dependencies")
    end

    :ok = Maraithon.DurablePayloadBinding.validate_config!()
    start_once(Maraithon.Vault)
    start_once(Maraithon.Repo)
  end

  defp start_once(module) do
    case module.start_link() do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
      {:error, _reason} -> Mix.raise("could not start privacy storage")
    end
  end

  defp print(value), do: Mix.shell().info(Jason.encode!(value, pretty: true))

  defp usage do
    """
    Usage:
      mix maraithon.conversation_privacy preflight
      mix maraithon.conversation_privacy backfill --confirm [--batch-size N] [--max-batches N]
    """
  end
end
