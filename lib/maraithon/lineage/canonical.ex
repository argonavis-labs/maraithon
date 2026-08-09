defmodule Maraithon.Lineage.Canonical do
  @moduledoc false

  alias Maraithon.BoundedJSON

  @sensitive_keys MapSet.new(~w(
    access_token api_key authorization client_secret cookie exception exception_body
    id_token password provider_error_body provider_exception raw_exception raw_response
    refresh_token response_body set-cookie signing_secret stacktrace webhook_secret
  ))

  def object(value, max_bytes, opts \\ [])

  def object(value, max_bytes, opts)
      when is_map(value) and not is_struct(value) and is_integer(max_bytes) and max_bytes > 0 and
             is_list(opts) do
    with true <- BoundedJSON.valid?(value, max_bytes, opts),
         :ok <- reject_sensitive_keys(value),
         {:ok, json} <- Jason.encode(value),
         true <- byte_size(json) <= max_bytes,
         {:ok, canonical} when is_map(canonical) <- Jason.decode(json),
         {:ok, encoded} <- encode(canonical),
         true <- byte_size(encoded) <= max_bytes do
      {:ok, canonical, encoded, :crypto.hash(:sha256, encoded)}
    else
      _invalid -> {:error, :invalid_lineage_payload}
    end
  rescue
    _error -> {:error, :invalid_lineage_payload}
  end

  def object(_value, _max_bytes, _opts), do: {:error, :invalid_lineage_payload}

  def identity(namespace, parts) when is_binary(namespace) and is_list(parts) do
    with {:ok, encoded_parts} <- encode_identity_parts([namespace | parts]) do
      {:ok, :crypto.hash(:sha256, encoded_parts)}
    end
  end

  def identity(_namespace, _parts), do: {:error, :invalid_lineage_identity}

  def string(value, max_bytes, opts \\ [])

  def string(value, max_bytes, opts)
      when is_binary(value) and is_integer(max_bytes) and max_bytes > 0 and is_list(opts) do
    min_bytes = Keyword.get(opts, :min_bytes, 1)
    whitespace? = Keyword.get(opts, :allow_whitespace, true)

    if byte_size(value) in min_bytes..max_bytes and String.valid?(value) and
         :binary.match(value, <<0>>) == :nomatch and not control_character?(value) and
         (whitespace? or not Regex.match?(~r/\s/u, value)) do
      {:ok, value}
    else
      {:error, :invalid_lineage_identity}
    end
  end

  def string(_value, _max_bytes, _opts), do: {:error, :invalid_lineage_identity}

  def digest(value) when is_binary(value), do: :crypto.hash(:sha256, value)

  defp encode_identity_parts(parts) do
    Enum.reduce_while(parts, {:ok, []}, fn
      nil, {:ok, encoded} ->
        {:cont, {:ok, [encoded, <<0>>]}}

      part, {:ok, encoded} when is_binary(part) ->
        if byte_size(part) <= 1_000_000 do
          {:cont, {:ok, [encoded, <<1, byte_size(part)::unsigned-big-32>>, part]}}
        else
          {:halt, {:error, :invalid_lineage_identity}}
        end

      part, {:ok, encoded} when is_integer(part) ->
        binary = Integer.to_string(part)
        {:cont, {:ok, [encoded, <<2, byte_size(binary)::unsigned-big-32>>, binary]}}

      _part, _acc ->
        {:halt, {:error, :invalid_lineage_identity}}
    end)
  end

  defp reject_sensitive_keys(value) when is_map(value) do
    Enum.reduce_while(value, :ok, fn {key, nested}, :ok ->
      normalized_key = normalize_sensitive_key(key)

      if sensitive_key?(normalized_key) do
        {:halt, {:error, :sensitive_lineage_payload}}
      else
        case reject_sensitive_keys(nested) do
          :ok -> {:cont, :ok}
          error -> {:halt, error}
        end
      end
    end)
  rescue
    _error -> {:error, :invalid_lineage_payload}
  end

  defp reject_sensitive_keys(value) when is_list(value) do
    Enum.reduce_while(value, :ok, fn nested, :ok ->
      case reject_sensitive_keys(nested) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp reject_sensitive_keys(_value), do: :ok

  defp sensitive_key?(key) do
    MapSet.member?(@sensitive_keys, key) or
      key in ~w(token tokens secret secrets credential credentials private_key) or
      String.contains?(key, "exception") or
      Enum.any?(~w(token secret password credential credentials private_key api_key), fn suffix ->
        String.ends_with?(key, "_#{suffix}")
      end)
  end

  defp normalize_sensitive_key(key) do
    key
    |> to_string()
    |> Macro.underscore()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/u, "_")
    |> String.trim("_")
  end

  defp encode(value) when is_map(value) do
    value
    |> Enum.sort_by(fn {key, _value} -> key end)
    |> Enum.reduce_while({:ok, []}, fn {key, nested}, {:ok, encoded} ->
      with true <- is_binary(key),
           {:ok, encoded_key} <- Jason.encode(key),
           {:ok, encoded_value} <- encode(nested) do
        separator = if encoded == [], do: [], else: ","
        {:cont, {:ok, [encoded, separator, encoded_key, ":", encoded_value]}}
      else
        _invalid -> {:halt, {:error, :invalid_lineage_payload}}
      end
    end)
    |> case do
      {:ok, encoded} -> {:ok, IO.iodata_to_binary(["{", encoded, "}"])}
      error -> error
    end
  end

  defp encode(value) when is_list(value) do
    value
    |> Enum.reduce_while({:ok, []}, fn nested, {:ok, encoded} ->
      case encode(nested) do
        {:ok, encoded_value} ->
          separator = if encoded == [], do: [], else: ","
          {:cont, {:ok, [encoded, separator, encoded_value]}}

        error ->
          {:halt, error}
      end
    end)
    |> case do
      {:ok, encoded} -> {:ok, IO.iodata_to_binary(["[", encoded, "]"])}
      error -> error
    end
  end

  defp encode(value)
       when is_binary(value) or is_integer(value) or is_float(value) or is_boolean(value) or
              is_nil(value),
       do: Jason.encode(value)

  defp encode(_value), do: {:error, :invalid_lineage_payload}

  defp control_character?(value), do: Regex.match?(~r/[\x00-\x1F\x7F]/u, value)
end
