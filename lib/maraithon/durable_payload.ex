defmodule Maraithon.DurablePayload do
  @moduledoc false

  import Ecto.Changeset, only: [add_error: 4, fetch_change: 2, put_change: 3]

  alias Maraithon.BoundedJSON

  @protocol_cutover Maraithon.Effects.ProtocolCutover

  @doc false
  def legacy_write? do
    case protocol_mode() do
      :legacy -> true
      :exact -> false
      {:blocked, _mismatch} -> raise "durable payload protocol is blocked"
      _invalid -> raise "invalid durable payload protocol mode"
    end
  end

  @doc false
  def require_legacy_mutation! do
    if Code.ensure_loaded?(@protocol_cutover) and
         function_exported?(@protocol_cutover, :require_legacy_mutation!, 0) do
      apply(@protocol_cutover, :require_legacy_mutation!, [])
    else
      :ok
    end
  end

  @doc false
  def require_current_mutation! do
    if Code.ensure_loaded?(@protocol_cutover) and
         function_exported?(@protocol_cutover, :require_current_mutation!, 0) do
      apply(@protocol_cutover, :require_current_mutation!, [])
    else
      :ok
    end
  end

  defp protocol_mode do
    if Code.ensure_loaded?(@protocol_cutover) and
         function_exported?(@protocol_cutover, :mode, 0) do
      apply(@protocol_cutover, :mode, [])
    else
      :legacy
    end
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
end
