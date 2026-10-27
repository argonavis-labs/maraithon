defmodule Maraithon.Vault do
  @moduledoc """
  Versioned Cloak vault for all sensitive database ciphertext.

  New writes use `CLOAK_CURRENT_KEY_TAG` and `CLOAK_CURRENT_KEY`. Previous
  read keys are supplied as a bounded JSON array in `CLOAK_PREVIOUS_KEYS`:

      [{"tag":"AES.GCM.V1","key":"<strict base64>"}]

  `CLOAK_KEY` remains a rollout-only alias for the current key when the two
  versioned variables are absent; it always uses tag `AES.GCM.V1`. Production
  never synthesizes key material. Key tags are embedded in Cloak ciphertext
  and must be unique across the current and previous keyring.
  """

  use Cloak.Vault, otp_app: :maraithon

  @algorithm_version 1
  @max_previous_keys 8
  @tag_regex ~r/^[A-Za-z0-9][A-Za-z0-9._:-]{0,63}$/
  @legacy_tag "AES.GCM.V1"
  @fallback_key :crypto.hash(:sha256, "maraithon-dev-key-do-not-use-in-production")

  @doc "Fails closed on missing, malformed, duplicate, or non-32-byte keys."
  def validate_config! do
    _ = keyring!()
    :ok
  end

  @doc "Algorithm/keyring format version used for new ciphertext."
  def current_key_version, do: @algorithm_version

  @doc "Configured current write tag; key material is never returned."
  def current_key_tag, do: keyring!().current_tag

  @doc "All configured read tags without key material."
  def configured_key_tags, do: keyring!().entries |> Enum.map(&elem(&1, 0)) |> Enum.sort()

  @doc "Returns the authenticated Cloak tag header without decrypting content."
  def ciphertext_key_tag(ciphertext) when is_binary(ciphertext) do
    case safe_decode_tag(ciphertext) do
      %{tag: tag} when is_binary(tag) -> {:ok, tag}
      _invalid -> {:error, :ciphertext_tag_invalid}
    end
  end

  def ciphertext_key_tag(_ciphertext), do: {:error, :ciphertext_tag_invalid}

  @doc false
  def tag_prefix(tag) when is_binary(tag) do
    tag = validate_tag!(tag)
    <<1, byte_size(tag), tag::binary>>
  end

  @impl GenServer
  def init(config) do
    ciphers =
      keyring!().entries
      |> Enum.with_index()
      |> Enum.map(fn {{tag, key}, index} ->
        {cipher_label(index), {Cloak.Ciphers.AES.GCM, tag: tag, key: key, iv_length: 12}}
      end)

    {:ok, Keyword.put(config, :ciphers, ciphers)}
  end

  defp keyring! do
    {current_tag, current_key} = current_key!()
    previous = parse_previous_keys!(System.get_env("CLOAK_PREVIOUS_KEYS"))
    entries = [{current_tag, current_key} | previous]
    tags = Enum.map(entries, &elem(&1, 0))

    if length(tags) != length(Enum.uniq(tags)) do
      raise "Cloak key tags must be unique"
    end

    %{current_tag: current_tag, entries: entries}
  end

  defp current_key! do
    versioned = {
      System.get_env("CLOAK_CURRENT_KEY_TAG"),
      System.get_env("CLOAK_CURRENT_KEY")
    }

    case versioned do
      {tag, key} when is_binary(tag) and is_binary(key) ->
        {validate_tag!(tag), decode_key!(key)}

      {nil, nil} ->
        legacy_or_fallback_key!()

      _partial ->
        raise "CLOAK_CURRENT_KEY_TAG and CLOAK_CURRENT_KEY must be provided together"
    end
  end

  defp legacy_or_fallback_key! do
    case System.get_env("CLOAK_KEY") do
      key when is_binary(key) ->
        {@legacy_tag, decode_key!(key)}

      nil ->
        if Application.get_env(:maraithon, :allow_insecure_vault, false) do
          {@legacy_tag, @fallback_key}
        else
          raise "CLOAK_CURRENT_KEY_TAG and CLOAK_CURRENT_KEY are required"
        end
    end
  end

  defp parse_previous_keys!(nil), do: []
  defp parse_previous_keys!(""), do: []

  defp parse_previous_keys!(encoded) when is_binary(encoded) do
    value = Jason.decode!(encoded)

    unless is_list(value) and length(value) <= @max_previous_keys do
      raise "CLOAK_PREVIOUS_KEYS must be a JSON array of at most #{@max_previous_keys} keys"
    end

    Enum.map(value, fn
      %{"tag" => tag, "key" => key} when is_binary(tag) and is_binary(key) ->
        {validate_tag!(tag), decode_key!(key)}

      _invalid ->
        raise "each previous Cloak key requires string tag and key fields"
    end)
  rescue
    error in Jason.DecodeError ->
      raise ArgumentError, "CLOAK_PREVIOUS_KEYS is invalid JSON: #{Exception.message(error)}"
  end

  defp validate_tag!(tag) do
    if tag == String.trim(tag) and Regex.match?(@tag_regex, tag),
      do: tag,
      else: raise("invalid Cloak key tag")
  end

  defp decode_key!(encoded) do
    case Base.decode64(encoded) do
      {:ok, key} when byte_size(key) == 32 ->
        if Base.encode64(key) == encoded,
          do: key,
          else: raise("key must use canonical base64 encoding")

      _invalid ->
        raise "Cloak keys must be canonical base64-encoded 32-byte values"
    end
  end

  defp safe_decode_tag(ciphertext) do
    Cloak.Tags.Decoder.decode(ciphertext)
  rescue
    _error -> :error
  catch
    _kind, _reason -> :error
  end

  defp cipher_label(0), do: :current
  defp cipher_label(1), do: :previous_1
  defp cipher_label(2), do: :previous_2
  defp cipher_label(3), do: :previous_3
  defp cipher_label(4), do: :previous_4
  defp cipher_label(5), do: :previous_5
  defp cipher_label(6), do: :previous_6
  defp cipher_label(7), do: :previous_7
  defp cipher_label(8), do: :previous_8
end
