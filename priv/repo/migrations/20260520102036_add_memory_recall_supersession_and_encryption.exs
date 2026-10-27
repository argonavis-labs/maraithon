defmodule Maraithon.Repo.Migrations.AddMemoryRecallSupersessionAndEncryption do
  use Ecto.Migration

  @decay_index :memory_items_user_active_decay_at_index
  @superseded_by_index :memory_items_superseded_by_id_index
  @supersedes_index :memory_items_supersedes_id_index

  def up do
    alter table(:memory_items) do
      add :decay_at, :utc_datetime_usec
      add :superseded_by_id, references(:memory_items, type: :binary_id, on_delete: :nilify_all)
      add :supersedes_id, references(:memory_items, type: :binary_id, on_delete: :nilify_all)
      add :content_ciphertext, :binary
      add :summary_ciphertext, :binary
      add :metadata_ciphertext, :binary
    end

    create index(:memory_items, [:user_id, :decay_at],
             name: @decay_index,
             where: "status = 'active'"
           )

    create index(:memory_items, [:superseded_by_id], name: @superseded_by_index)
    create index(:memory_items, [:supersedes_id], name: @supersedes_index)

    flush()

    backfill_encrypted_memory_items()

    alter table(:memory_items) do
      remove :content
      remove :summary
      remove :metadata
    end

    rename table(:memory_items), :content_ciphertext, to: :content
    rename table(:memory_items), :summary_ciphertext, to: :summary
    rename table(:memory_items), :metadata_ciphertext, to: :metadata

    alter table(:memory_items) do
      modify :content, :binary, null: false
      modify :metadata, :binary, null: false
    end
  end

  def down do
    alter table(:memory_items) do
      add :content_plaintext, :text
      add :summary_plaintext, :text
      add :metadata_plaintext, :map
    end

    flush()

    backfill_plaintext_memory_items()

    alter table(:memory_items) do
      remove :content
      remove :summary
      remove :metadata
    end

    rename table(:memory_items), :content_plaintext, to: :content
    rename table(:memory_items), :summary_plaintext, to: :summary
    rename table(:memory_items), :metadata_plaintext, to: :metadata

    alter table(:memory_items) do
      modify :content, :text, null: false
      modify :metadata, :map, null: false, default: %{}
    end

    drop_if_exists index(:memory_items, [:user_id, :decay_at], name: @decay_index)
    drop_if_exists index(:memory_items, [:superseded_by_id], name: @superseded_by_index)
    drop_if_exists index(:memory_items, [:supersedes_id], name: @supersedes_index)

    alter table(:memory_items) do
      remove :decay_at
      remove :superseded_by_id
      remove :supersedes_id
    end
  end

  defp backfill_encrypted_memory_items do
    started_vault? = ensure_vault_started()

    try do
      %{rows: rows} =
        migration_repo().query!("SELECT id, content, summary, metadata FROM memory_items", [],
          log: false
        )

      Enum.each(rows, fn [id, content, summary, metadata] ->
        {:ok, encrypted_content} = Maraithon.Encrypted.Binary.dump(content || "")
        {:ok, encrypted_summary} = Maraithon.Encrypted.Binary.dump(summary)
        {:ok, encrypted_metadata} = Maraithon.Encrypted.Map.dump(metadata || %{})

        migration_repo().query!(
          """
          UPDATE memory_items
          SET content_ciphertext = $1,
              summary_ciphertext = $2,
              metadata_ciphertext = $3
          WHERE id = $4
          """,
          [encrypted_content, encrypted_summary, encrypted_metadata, id],
          log: false
        )
      end)
    after
      stop_started_vault(started_vault?)
    end
  end

  defp backfill_plaintext_memory_items do
    started_vault? = ensure_vault_started()

    try do
      %{rows: rows} =
        migration_repo().query!("SELECT id, content, summary, metadata FROM memory_items", [],
          log: false
        )

      Enum.each(rows, fn [id, content, summary, metadata] ->
        {:ok, decrypted_content} = Maraithon.Encrypted.Binary.load(content)
        {:ok, decrypted_summary} = Maraithon.Encrypted.Binary.load(summary)
        {:ok, decrypted_metadata} = Maraithon.Encrypted.Map.load(metadata)

        migration_repo().query!(
          """
          UPDATE memory_items
          SET content_plaintext = $1,
              summary_plaintext = $2,
              metadata_plaintext = $3
          WHERE id = $4
          """,
          [decrypted_content || "", decrypted_summary, decrypted_metadata || %{}, id],
          log: false
        )
      end)
    after
      stop_started_vault(started_vault?)
    end
  end

  defp ensure_vault_started do
    case Process.whereis(Maraithon.Vault) do
      nil ->
        case Maraithon.Vault.start_link() do
          {:ok, _pid} -> true
          {:error, {:already_started, _pid}} -> false
        end

      _pid ->
        false
    end
  end

  defp stop_started_vault(true), do: GenServer.stop(Maraithon.Vault)
  defp stop_started_vault(false), do: :ok

  defp migration_repo, do: Maraithon.Repo
end
