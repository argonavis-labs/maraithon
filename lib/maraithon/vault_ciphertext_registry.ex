defmodule Maraithon.VaultCiphertextRegistry do
  @moduledoc """
  Closed inventory of every database column encrypted by `Maraithon.Vault`.

  Rotation and key-retirement preflights use this inventory directly; durable
  proof rows are never treated as an old-key count authority.
  """

  @extra [
    %{
      module: Maraithon.Accounts.ConnectedAccount,
      table: "connected_accounts",
      field: :access_token,
      column: "access_token",
      type: :binary,
      max_bytes: 65_536
    },
    %{
      module: Maraithon.Accounts.ConnectedAccount,
      table: "connected_accounts",
      field: :refresh_token,
      column: "refresh_token",
      type: :binary,
      max_bytes: 65_536
    },
    %{
      module: Maraithon.OAuth.Token,
      table: "oauth_tokens",
      field: :access_token,
      column: "access_token",
      type: :binary,
      max_bytes: 65_536
    },
    %{
      module: Maraithon.OAuth.Token,
      table: "oauth_tokens",
      field: :refresh_token,
      column: "refresh_token",
      type: :binary,
      max_bytes: 65_536
    },
    %{
      module: Maraithon.LocalBrowserHistory.LocalVisit,
      table: "local_browser_visits",
      field: :title,
      column: "title",
      type: :binary,
      max_bytes: 131_072
    },
    %{
      module: Maraithon.LocalCalendar.LocalEvent,
      table: "local_calendar_events",
      field: :title,
      column: "title",
      type: :binary,
      max_bytes: 131_072
    },
    %{
      module: Maraithon.LocalCalendar.LocalEvent,
      table: "local_calendar_events",
      field: :notes,
      column: "notes",
      type: :binary,
      max_bytes: 524_288
    },
    %{
      module: Maraithon.LocalFiles.LocalFile,
      table: "local_files",
      field: :filename,
      column: "filename",
      type: :binary,
      max_bytes: 131_072
    },
    %{
      module: Maraithon.LocalFiles.LocalFile,
      table: "local_files",
      field: :text_content,
      column: "text_content",
      type: :binary,
      max_bytes: 524_288
    },
    %{
      module: Maraithon.Memory.Item,
      table: "memory_items",
      field: :content,
      column: "content",
      type: :binary,
      max_bytes: 65_536
    },
    %{
      module: Maraithon.Memory.Item,
      table: "memory_items",
      field: :summary,
      column: "summary",
      type: :binary,
      max_bytes: 32_768
    },
    %{
      module: Maraithon.Memory.Item,
      table: "memory_items",
      field: :metadata,
      column: "metadata",
      type: :map,
      max_bytes: 262_144
    }
  ]

  @doc "Every reviewed Vault-encrypted Ecto field."
  def all do
    durable =
      for source <- Maraithon.DurablePayloadRegistry.all(),
          {field, column, type, max_bytes, _required} <- source.fields do
        %{
          module: source.module,
          table: source.table,
          field: field,
          column: Atom.to_string(column),
          type: type,
          max_bytes: max_bytes
        }
      end

    durable ++ @extra
  end

  @doc "Fetches one reviewed table/column target."
  def fetch(table, column) when is_binary(table) and is_binary(column) do
    case Enum.find(all(), &(&1.table == table and &1.column == column)) do
      nil -> :error
      target -> {:ok, target}
    end
  end

  def fetch(_table, _column), do: :error
end
