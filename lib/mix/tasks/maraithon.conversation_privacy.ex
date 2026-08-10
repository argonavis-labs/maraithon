defmodule Mix.Tasks.Maraithon.ConversationPrivacy do
  @moduledoc """
  Operates the additive Telegram conversation privacy rollout.

      mix maraithon.conversation_privacy preflight
      mix maraithon.conversation_privacy backfill --confirm --batch-size 100 --max-batches 20
      mix maraithon.conversation_privacy scrub-expired --retention-days 90 --batch-size 100 --confirm

  `backfill` is rerunnable and commits only bounded `FOR UPDATE SKIP LOCKED`
  batches. `scrub-expired` preserves rows and identifiers, and requires an
  explicit confirmation flag.
  """

  use Mix.Task

  alias Maraithon.TelegramConversations.Privacy

  @shortdoc "Backfill encryption and scrub expired conversation content"
  @switches [
    batch_size: :integer,
    max_batches: :integer,
    retention_days: :integer,
    confirm: :boolean,
    user_id: :string
  ]

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

      ["scrub-expired"] ->
        unless opts[:confirm] do
          Mix.raise("scrub-expired requires --confirm")
        end

        scrub_batches(opts)
        |> print()

      ["erase-user"] ->
        unless opts[:confirm] && is_binary(opts[:user_id]) do
          Mix.raise("erase-user requires --confirm and --user-id")
        end

        erase_opts =
          opts
          |> Keyword.delete(:confirm)
          |> Keyword.delete(:user_id)
          |> Keyword.put(:confirmation, "NON_ROLLING_FLEET_DRAINED")

        case Privacy.erase_user_batch(opts[:user_id], erase_opts) do
          {:ok, result} -> print(result)
          {:error, reason} -> Mix.raise("User erasure failed: #{inspect(reason)}")
        end

      _other ->
        Mix.raise(usage())
    end
  end

  defp scrub_batches(opts) do
    max_batches = opts |> Keyword.get(:max_batches, 1) |> max(1) |> min(1_000)

    Enum.reduce_while(
      1..max_batches,
      %{batches: 0, scrubbed_turns: 0, scrubbed_conversations: 0},
      fn _, total ->
        case Privacy.scrub_expired(opts) do
          {:ok, batch} ->
            next = %{
              batches: total.batches + 1,
              scrubbed_turns: total.scrubbed_turns + batch.scrubbed_turns,
              scrubbed_conversations: total.scrubbed_conversations + batch.scrubbed_conversations
            }

            if batch.scrubbed_turns + batch.scrubbed_conversations == 0,
              do: {:halt, next},
              else: {:cont, next}

          {:error, reason} ->
            Mix.raise("Retention scrub failed: #{inspect(reason)}")
        end
      end
    )
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
      mix maraithon.conversation_privacy scrub-expired --confirm [--retention-days N] [--batch-size N] [--max-batches N]
      mix maraithon.conversation_privacy erase-user --confirm --user-id ID [--batch-size N]
    """
  end
end
