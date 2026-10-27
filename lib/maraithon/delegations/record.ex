defmodule Maraithon.Delegations.Record do
  @moduledoc false
  import Ecto.Changeset
  alias Maraithon.DurablePayload

  defmacro __using__(_opts) do
    quote do
      use Ecto.Schema
      import Ecto.Changeset
      import Maraithon.Delegations.Record, only: [payload_fields: 0]
      alias Maraithon.Delegations.Record
      @primary_key {:id, :binary_id, autogenerate: true}
      @foreign_key_type :binary_id
      def hydrate(nil), do: nil
      def hydrate(row), do: Record.hydrate(row, payload_binding_spec())
    end
  end

  defmacro payload_fields do
    quote do
      field :user_id, :string
      field :data, Maraithon.Encrypted.Map, source: :data_ciphertext, redact: true
      field :payload_encryption_version, :integer, default: 1
      field :payload_binding_version, :integer
      field :payload_binding_key_tag, :string
      field :payload_binding_mac, :binary, redact: true
      field :payload_purged_at, :utc_datetime_usec
      timestamps(type: :utc_datetime_usec)
    end
  end

  def spec(table, fields) do
    %{
      table: table,
      identity_fields: [:id],
      scope_fields: [:user_id],
      fields: [:data],
      bound_fields: fields,
      purge_field: :payload_purged_at
    }
  end

  def bounds,
    do: [max_binary_bytes: 32_768, max_depth: 12, max_nodes: 8_000, max_list_items: 1_000]

  # New records are ciphertext-only; there is no legacy plaintext write path.
  def changeset(row, attrs, fields, required) do
    row
    |> cast(attrs, [:data | fields])
    |> validate_required([:user_id, :data | required])
    |> bind_columns(row.__struct__.payload_binding_spec())
    |> DurablePayload.put_bounded_map(:data, 65_536, bounds())
    |> DurablePayload.put_binding(row.__struct__.payload_binding_spec())
    |> DurablePayload.require_current_mutation()
    |> foreign_key_constraint(:user_id)
  end

  def hydrate(row, spec) do
    :ok = DurablePayload.verify_binding!(row, spec, :exact)

    cond do
      row.payload_purged_at != nil and row.data == nil ->
        row

      row.payload_purged_at == nil and row.payload_encryption_version == 1 and is_map(row.data) ->
        expected = canonical(Map.take(row, spec.bound_fields))
        if row.data["_bound"] != expected, do: raise(ArgumentError, "delegation scope mismatch")
        row

      true ->
        raise ArgumentError, "invalid delegation payload"
    end
  end

  defp bind_columns(changeset, spec) do
    case get_field(changeset, :data) do
      data when is_map(data) ->
        columns = Map.new(spec.bound_fields, &{&1, get_field(changeset, &1)})
        put_change(changeset, :data, Map.put(data, "_bound", canonical(columns)))

      _ ->
        changeset
    end
  end

  defp canonical(value) do
    value
    |> Map.new(fn
      {key, %DateTime{} = datetime} ->
        utc = DateTime.shift_zone!(datetime, "Etc/UTC")
        {key, DateTime.to_iso8601(%{utc | microsecond: {elem(utc.microsecond, 0), 6}})}

      entry ->
        entry
    end)
    |> Jason.encode!()
    |> Jason.decode!()
  end
end
