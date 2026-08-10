defmodule Maraithon.DurablePayload do
  @moduledoc false

  import Ecto.Changeset,
    only: [
      add_error: 3,
      add_error: 4,
      fetch_change: 2,
      get_field: 2,
      prepare_changes: 2,
      put_change: 3
    ]

  alias Maraithon.BoundedJSON

  @protocol_cutover Maraithon.Effects.ProtocolCutover

  @doc false
  def mode! do
    case @protocol_cutover.mode() do
      :legacy -> :legacy
      :exact -> :exact
      {:blocked, reason} -> raise "durable payload protocol is blocked: #{inspect(reason)}"
      invalid -> raise "invalid durable payload protocol mode: #{inspect(invalid)}"
    end
  end

  @doc false
  def legacy_write?, do: mode!() == :legacy

  @doc false
  def legacy_read?, do: mode!() == :legacy

  @doc false
  def require_legacy_mutation!, do: @protocol_cutover.require_legacy_mutation!()

  @doc false
  def require_current_mutation!, do: @protocol_cutover.require_current_mutation!()

  @doc false
  def require_current_mutation(changeset) do
    prepare_changes(changeset, fn changeset ->
      :ok = require_current_mutation!()
      changeset
    end)
  end

  @doc false
  def put_bounded_map(changeset, field, max_bytes, opts \\ [])
      when is_atom(field) and is_integer(max_bytes) and max_bytes > 0 and is_list(opts) do
    case fetch_change(changeset, field) do
      :error ->
        changeset

      {:ok, value} ->
        case prepare_map(value, max_bytes, opts) do
          {:ok, canonical} ->
            put_change(changeset, field, canonical)

          {:error, :invalid_payload} ->
            add_error(
              changeset,
              field,
              Keyword.get(opts, :message, "must be a bounded JSON object"),
              validation: :bounded_json
            )
        end
    end
  end

  @doc false
  def prepare_map(value, max_bytes, opts \\ [])

  def prepare_map(value, max_bytes, opts)
      when is_map(value) and not is_struct(value) and is_integer(max_bytes) and max_bytes > 0 and
             is_list(opts) do
    bounds = Keyword.drop(opts, [:message])

    with true <- BoundedJSON.valid?(value, max_bytes, bounds),
         {:ok, encoded} <- Jason.encode(value),
         true <- byte_size(encoded) <= max_bytes,
         {:ok, canonical} when is_map(canonical) <- Jason.decode(encoded) do
      {:ok, canonical}
    else
      _invalid -> {:error, :invalid_payload}
    end
  rescue
    _error -> {:error, :invalid_payload}
  end

  def prepare_map(_value, _max_bytes, _opts), do: {:error, :invalid_payload}

  @doc false
  def put_binding(changeset, spec) when is_map(spec) do
    changeset = ensure_binding_identity(changeset, spec)

    prepare_changes(changeset, fn prepared ->
      purge_marker = get_field(prepared, Map.fetch!(spec, :purge_field))

      if is_nil(purge_marker) do
        binding = binding_for_changeset!(prepared, spec)

        prepared
        |> put_change(:payload_binding_version, binding.version)
        |> put_change(:payload_binding_key_tag, binding.key_tag)
        |> put_change(:payload_binding_mac, binding.mac)
      else
        prepared
        |> put_change(:payload_binding_version, nil)
        |> put_change(:payload_binding_key_tag, nil)
        |> put_change(:payload_binding_mac, nil)
      end
    end)
  end

  @doc false
  def binding_attrs!(row_or_changeset, spec) when is_map(spec) do
    binding = binding_for!(row_or_changeset, spec)

    %{
      payload_binding_version: binding.version,
      payload_binding_key_tag: binding.key_tag,
      payload_binding_mac: binding.mac
    }
  end

  @doc false
  def verify_binding!(row, spec, mode \\ mode!()) when mode in [:legacy, :exact] do
    purged? = not is_nil(Map.fetch!(row, Map.fetch!(spec, :purge_field)))

    binding =
      {Map.get(row, :payload_binding_version), Map.get(row, :payload_binding_key_tag),
       Map.get(row, :payload_binding_mac)}

    cond do
      purged? and binding == {nil, nil, nil} ->
        :ok

      purged? ->
        raise ArgumentError, "purged durable payload binding must be empty"

      binding == {nil, nil, nil} and mode == :legacy ->
        :ok

      true ->
        {version, key_tag, mac} = binding
        {table, identity, scope, fields} = binding_context!(row, spec)

        case Maraithon.DurablePayloadBinding.verify(
               table,
               identity,
               scope,
               fields,
               version,
               key_tag,
               mac
             ) do
          :ok -> :ok
          {:error, reason} -> raise ArgumentError, "durable payload binding failed: #{reason}"
        end
    end
  end

  @doc false
  def binding_context!(row_or_changeset, spec) when is_map(spec) do
    getter = getter(row_or_changeset)
    table = Map.fetch!(spec, :table)

    identity =
      spec
      |> Map.fetch!(:identity_fields)
      |> Enum.map(fn field ->
        case getter.(field) do
          value when is_binary(value) and value != "" -> value
          value when is_integer(value) and value > 0 -> value
          _missing -> raise ArgumentError, "durable payload stable identity is missing"
        end
      end)
      |> encode_context!()

    scope =
      spec
      |> Map.get(:scope_fields, [])
      |> Enum.map(&context_value!(getter.(&1)))
      |> encode_context!()

    fields =
      Enum.map(Map.fetch!(spec, :fields), fn field ->
        {Atom.to_string(field), getter.(field)}
      end)

    {table, identity, scope, fields}
  end

  defp ensure_binding_identity(changeset, spec) do
    Enum.reduce(Map.fetch!(spec, :identity_fields), changeset, fn field, prepared ->
      case get_field(prepared, field) do
        value when is_binary(value) and value != "" ->
          prepared

        value when is_integer(value) and value > 0 ->
          prepared

        nil when field == :id ->
          case Map.get(prepared.types, field) do
            type when type in [:binary_id, Ecto.UUID] ->
              put_change(prepared, field, Ecto.UUID.generate())

            _other ->
              add_error(prepared, field, "must be assigned before payload binding")
          end

        _missing_or_invalid ->
          add_error(prepared, field, "must be assigned before payload binding")
      end
    end)
  end

  defp binding_for_changeset!(changeset, spec), do: binding_for!(changeset, spec)

  defp binding_for!(row_or_changeset, spec) do
    {table, identity, scope, fields} = binding_context!(row_or_changeset, spec)
    Maraithon.DurablePayloadBinding.sign(table, identity, scope, fields)
  end

  defp getter(%Ecto.Changeset{} = changeset), do: &get_field(changeset, &1)
  defp getter(row) when is_map(row), do: &Map.get(row, &1)

  defp context_value!(nil), do: nil
  defp context_value!(value) when is_binary(value), do: value
  defp context_value!(value) when is_integer(value), do: value

  defp context_value!(_unsupported) do
    raise ArgumentError, "durable payload context values must be nil, strings, or integers"
  end

  @doc false
  def legacy_context_identity(values) when is_list(values) do
    encoded =
      Enum.map(values, fn
        nil -> ""
        value when is_binary(value) -> value
        value when is_integer(value) -> Integer.to_string(value)
      end)

    case encoded do
      [] -> ""
      values -> Jason.encode!(values)
    end
  end

  @doc false
  def context_identity(values) when is_list(values) do
    values
    |> Enum.map(&context_value!/1)
    |> encode_context!()
  end

  defp encode_context!(values) do
    values
    |> Enum.map(fn
      nil -> ["nil"]
      value when is_binary(value) -> ["string", value]
      value when is_integer(value) -> ["integer", Integer.to_string(value)]
    end)
    |> Jason.encode!()
  end
end
