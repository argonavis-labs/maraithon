defmodule Mix.Tasks.Maraithon.ConversationPrivacy do
  @moduledoc """
  Operates the additive Telegram conversation privacy rollout.

      mix maraithon.conversation_privacy preflight
      mix maraithon.conversation_privacy backfill --batch-size 100 --max-batches 20
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
    confirm: :boolean
  ]

  @impl Mix.Task
  def run(args) do
    {opts, argv, invalid} = OptionParser.parse(args, strict: @switches)

    if invalid != [] do
      Mix.raise("Invalid options: #{inspect(invalid)}")
    end

    Mix.Task.run("app.start")

    case argv do
      ["preflight"] ->
        print(Privacy.preflight())

      ["backfill"] ->
        case Privacy.backfill(opts) do
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

  defp print(value), do: Mix.shell().info(Jason.encode!(value, pretty: true))

  defp usage do
    """
    Usage:
      mix maraithon.conversation_privacy preflight
      mix maraithon.conversation_privacy backfill [--batch-size N] [--max-batches N]
      mix maraithon.conversation_privacy scrub-expired --confirm [--retention-days N] [--batch-size N] [--max-batches N]
    """
  end
end
