defmodule Mix.Tasks.Maraithon.ConversationPrivacy do
  @moduledoc """
  Operates only the additive Telegram conversation encryption rollout.

      mix maraithon.conversation_privacy preflight
      mix maraithon.conversation_privacy backfill --confirm --evidence-id ID --evidence-sha256 SHA256 --revision REV --batch-size 100 --max-batches 20

  Ongoing retention runs exclusively through `Maraithon.PrivacyRetention`,
  which owns the fixed policy, PostgreSQL clock, exact authority, tenant cursor,
  metrics, and durable scheduling. User erasure runs exclusively through the
  central durable erasure lifecycle.
  """

  use Mix.Task

  alias Maraithon.TelegramConversations.Privacy

  @shortdoc "Preflight or backfill conversation payload encryption"
  @switches [
    batch_size: :integer,
    max_batches: :integer,
    confirm: :boolean,
    evidence_id: :string,
    evidence_sha256: :string,
    revision: :string
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
          |> Keyword.put(:evidence_id, opts[:evidence_id])
          |> Keyword.put(:evidence_digest, decode_sha256(opts[:evidence_sha256]))
          |> Keyword.put(:revision, opts[:revision])

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
    configure_activation_url!()

    case Application.ensure_all_started(:ecto_sql) do
      {:ok, _apps} -> :ok
      {:error, _reason} -> Mix.raise("could not start privacy storage dependencies")
    end

    :ok = Maraithon.DurablePayloadBinding.validate_config!()
    start_once(Maraithon.Vault)
    start_once(Maraithon.Repo)
  end

  defp configure_activation_url! do
    url = System.get_env("MARAITHON_ACTIVATION_DATABASE_URL")

    if Mix.env() == :prod and (is_nil(url) or String.trim(url) == "") do
      Mix.raise("MARAITHON_ACTIVATION_DATABASE_URL is required in production")
    end

    if is_binary(url) and String.trim(url) != "" do
      config = Application.get_env(:maraithon, Maraithon.Repo, [])
      Application.put_env(:maraithon, Maraithon.Repo, Keyword.put(config, :url, url))
    end
  end

  defp decode_sha256(nil), do: nil

  defp decode_sha256(value) when is_binary(value) do
    case Base.decode16(value, case: :lower) do
      {:ok, digest} when byte_size(digest) == 32 -> digest
      _invalid -> Mix.raise("--evidence-sha256 must be 64 lowercase hexadecimal characters")
    end
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
      mix maraithon.conversation_privacy backfill --confirm --evidence-id ID --evidence-sha256 SHA256 --revision REV [--batch-size N] [--max-batches N]
    """
  end
end
