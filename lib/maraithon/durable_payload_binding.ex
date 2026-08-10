defmodule Maraithon.DurablePayloadBinding do
  @moduledoc """
  Row-context authentication for durable encrypted payloads.

  Cloak authenticates ciphertext bytes but its AES-GCM AAD is shared, so a
  valid ciphertext can otherwise be substituted across rows or fields. Binding
  v1 HMACs a canonical, length-framed row context and fixed ordered plaintext
  fields with a separate versioned keyring.
  """

  @version 1
  @domain "maraithon:durable-payload-binding:v1"
  @max_previous_keys 8
  @tag_regex ~r/^[A-Za-z0-9][A-Za-z0-9._:-]{0,63}$/
  @fallback_tag "BINDING.HMAC.V1"
  @fallback_key :crypto.hash(:sha256, "maraithon-dev-binding-key-do-not-use-in-production")

  @type binding :: %{version: 1, key_tag: String.t(), mac: binary()}

  @doc "Fails startup on malformed, duplicate, missing, or non-32-byte keys."
  def validate_config! do
    _ = keyring!()
    :ok
  end

  @doc "The tag used for new bindings; key material is never returned."
  def current_key_tag, do: keyring!().current_tag

  @doc "Configured current and previous tags, without keys."
  def configured_key_tags, do: keyring!().keys |> Map.keys() |> Enum.sort()

  @doc "Signs one fixed ordered durable row context with the current key."
  @spec sign(String.t(), String.t(), String.t() | nil, [{String.t(), term()}]) :: binding()
  def sign(table, row_identity, tenant_or_agent_identity, ordered_fields)
      when is_binary(table) and is_binary(row_identity) and is_list(ordered_fields) do
    ring = keyring!()
    key = Map.fetch!(ring.keys, ring.current_tag)

    mac =
      :crypto.mac(
        :hmac,
        :sha256,
        key,
        binding_input(
          table,
          row_identity,
          tenant_or_agent_identity,
          ring.current_tag,
          @version,
          ordered_fields
        )
      )

    %{version: @version, key_tag: ring.current_tag, mac: mac}
  end

  @doc "Verifies a persisted binding in constant time."
  def verify(
        table,
        row_identity,
        tenant_or_agent_identity,
        ordered_fields,
        @version,
        key_tag,
        mac
      )
      when is_binary(table) and is_binary(row_identity) and is_list(ordered_fields) and
             is_binary(key_tag) and is_binary(mac) and byte_size(mac) == 32 do
    with {:ok, key} <- Map.fetch(keyring!().keys, key_tag) do
      expected =
        :crypto.mac(
          :hmac,
          :sha256,
          key,
          binding_input(
            table,
            row_identity,
            tenant_or_agent_identity,
            key_tag,
            @version,
            ordered_fields
          )
        )

      if Plug.Crypto.secure_compare(expected, mac), do: :ok, else: {:error, :binding_mismatch}
    else
      :error -> {:error, :binding_key_unavailable}
    end
  rescue
    _error -> {:error, :binding_invalid}
  end

  def verify(_table, _row_identity, _scope, _fields, _version, _key_tag, _mac),
    do: {:error, :binding_invalid}

  @doc "Returns deterministic canonical bytes for fixed ordered JSON fields."
  def binding_input(table, row_identity, tenant_or_agent_identity, key_tag, version, fields)
      when is_binary(table) and is_binary(row_identity) and is_binary(key_tag) and
             is_integer(version) and is_list(fields) do
    [
      @domain,
      table,
      row_identity,
      tenant_or_agent_identity || "",
      key_tag,
      Integer.to_string(version)
      | Enum.flat_map(fields, fn {name, value} ->
          [name, canonical_value!(value)]
        end)
    ]
    |> Enum.map(&frame/1)
    |> IO.iodata_to_binary()
  end

  defp canonical_value!(nil), do: <<0>>

  defp canonical_value!(value) do
    canonical =
      value
      |> Jason.encode!()
      |> Jason.decode!()
      |> canonical_term()

    <<1, :erlang.term_to_binary(canonical, [:deterministic])::binary>>
  end

  defp canonical_term(value) when is_map(value) do
    value
    |> Enum.map(fn {key, nested} -> {to_string(key), canonical_term(nested)} end)
    |> Enum.sort_by(&elem(&1, 0))
    |> then(&{:map, &1})
  end

  defp canonical_term(value) when is_list(value), do: {:list, Enum.map(value, &canonical_term/1)}
  defp canonical_term(value), do: value

  defp frame(value) when is_binary(value),
    do: <<byte_size(value)::unsigned-big-64, value::binary>>

  defp keyring! do
    allow_fallback? = Application.get_env(:maraithon, :allow_insecure_vault, false)

    {current_tag, current_key} =
      case {System.get_env("DURABLE_PAYLOAD_BINDING_CURRENT_TAG"),
            System.get_env("DURABLE_PAYLOAD_BINDING_CURRENT_KEY")} do
        {nil, nil} when allow_fallback? ->
          {@fallback_tag, @fallback_key}

        {tag, encoded} when is_binary(tag) and is_binary(encoded) ->
          {validate_tag!(tag), decode_key!(encoded)}

        _missing ->
          raise "DURABLE_PAYLOAD_BINDING_CURRENT_TAG and DURABLE_PAYLOAD_BINDING_CURRENT_KEY are both required"
      end

    previous = parse_previous_keys!(System.get_env("DURABLE_PAYLOAD_BINDING_PREVIOUS_KEYS"))
    entries = [{current_tag, current_key} | previous]
    tags = Enum.map(entries, &elem(&1, 0))

    if length(tags) != length(Enum.uniq(tags)) do
      raise "durable payload binding key tags must be unique"
    end

    %{current_tag: current_tag, keys: Map.new(entries)}
  end

  defp parse_previous_keys!(nil), do: []
  defp parse_previous_keys!(""), do: []

  defp parse_previous_keys!(encoded) when is_binary(encoded) do
    value = Jason.decode!(encoded)

    unless is_list(value) and length(value) <= @max_previous_keys do
      raise "DURABLE_PAYLOAD_BINDING_PREVIOUS_KEYS must be a JSON array of at most #{@max_previous_keys} keys"
    end

    Enum.map(value, fn
      %{"tag" => tag, "key" => key} when is_binary(tag) and is_binary(key) ->
        {validate_tag!(tag), decode_key!(key)}

      _invalid ->
        raise "each previous durable payload binding key requires string tag and key fields"
    end)
  rescue
    error in Jason.DecodeError ->
      raise ArgumentError,
            "DURABLE_PAYLOAD_BINDING_PREVIOUS_KEYS is invalid JSON: #{Exception.message(error)}"
  end

  defp validate_tag!(tag) do
    if tag == String.trim(tag) and Regex.match?(@tag_regex, tag),
      do: tag,
      else: raise("invalid durable payload binding key tag")
  end

  defp decode_key!(encoded) do
    case Base.decode64(encoded) do
      {:ok, key} when byte_size(key) == 32 ->
        if Base.encode64(key) == encoded,
          do: key,
          else: raise("key must use canonical base64 encoding")

      _invalid ->
        raise "durable payload binding keys must be strict base64-encoded 32-byte values"
    end
  end
end
