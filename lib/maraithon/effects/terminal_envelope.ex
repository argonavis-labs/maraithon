defmodule Maraithon.Effects.TerminalEnvelope do
  @moduledoc """
  Closed, versioned codec for durable Effect terminal results.

  The database row is authoritative. A present envelope is always interpreted
  before the legacy `status`/`result`/`error` columns; legacy fallback is used
  only when the envelope is `nil`.
  """

  alias Maraithon.Effects.Effect
  alias Maraithon.PolicyDecisionCopy

  @version 1
  @ambiguous_outcome :effect_outcome_ambiguous

  @max_envelope_bytes 16_384
  @max_envelope_binary_bytes 512
  @max_envelope_depth 8
  @max_envelope_nodes 128
  @max_reason_depth 4
  @max_tuple_arity 3
  @max_result_bytes 512_000
  @max_result_binary_bytes 256_000

  @llm_result_atom_keys %{
    "content" => :content,
    "model" => :model,
    "tokens_in" => :tokens_in,
    "tokens_out" => :tokens_out,
    "usage" => :usage,
    "input_tokens" => :input_tokens,
    "output_tokens" => :output_tokens,
    "total_tokens" => :total_tokens,
    "total_cost" => :total_cost,
    "finish_reason" => :finish_reason,
    "generation_mode" => :generation_mode,
    "intelligence" => :intelligence,
    "reasoning" => :reasoning,
    "messages" => :messages,
    "todos" => :todos
  }

  @policy_kinds [:tool_policy_denied, :tool_policy_needs_confirmation]
  @policy_reason_codes %{
    tool_policy_denied: %{
      "invalid_user_context" => :invalid_user_context,
      "provider_write_blocked" => :provider_write_blocked,
      "unexpected_policy_state" => :unexpected_policy_state,
      "unknown_tool" => :unknown_tool,
      "tool_failed" => :tool_failed
    },
    tool_policy_needs_confirmation: %{
      "confirmation_required" => :confirmation_required
    }
  }
  @policy_fallback_codes %{
    tool_policy_denied: :tool_failed,
    tool_policy_needs_confirmation: :confirmation_required
  }

  @doc "Return the current durable success envelope."
  def success do
    %{"status" => "ok", "version" => @version}
  end

  @doc "Return a bounded durable error envelope without provider-controlled detail."
  def error(reason) do
    %{
      "status" => "error",
      "version" => @version,
      "reason" => encode_reason(reason)
    }
  end

  @doc """
  Interpret a persisted terminal Effect row into the callback result shape.

  Unknown versions and malformed present envelopes fail closed as an ambiguous
  outcome. They never fall through to the legacy columns.
  """
  def decode(%Effect{} = effect), do: decode(Map.from_struct(effect))

  def decode(%{result_envelope: envelope} = effect),
    do: decode_envelope_or_legacy(envelope, effect)

  def decode(%{"result_envelope" => envelope} = effect),
    do: decode_envelope_or_legacy(envelope, effect)

  def decode(_effect), do: ambiguous_result()

  @doc false
  def encode_reason({kind, decision}) when kind in @policy_kinds and is_map(decision) do
    # Keep the durable grammar readable by the deployed v1 decoder. Only a
    # shallow, closed reason code crosses the boundary; free-form policy copy,
    # metadata, and discarded nested values are never traversed or persisted.
    encode_tuple([kind, policy_reason_code(kind, decision)])
  end

  def encode_reason({kind, %{reason: reason}})
      when kind in [:incomplete_response, :invalid_response] and is_binary(reason) do
    encode_closed_validation(kind, reason)
  end

  def encode_reason({kind, %{"reason" => reason}})
      when kind in [:incomplete_response, :invalid_response] and is_binary(reason) do
    encode_closed_validation(kind, reason)
  end

  def encode_reason(reason) when is_atom(reason) do
    %{"type" => "atom", "value" => Atom.to_string(reason)}
  end

  def encode_reason({kind, detail})
      when kind in [:provider_refusal, :content_filtered] and detail == :redacted do
    encode_tuple([kind, :redacted])
  end

  def encode_reason({kind, delay_ms})
      when kind in [:rate_limited, :llm_busy] and is_integer(delay_ms) do
    encode_tuple([kind, bounded_integer(delay_ms)])
  end

  def encode_reason({kind, status, provider_detail})
      when is_atom(kind) and is_integer(status) do
    safe_detail = if provider_detail == :redacted, do: :redacted, else: "redacted_detail"
    encode_tuple([kind, bounded_integer(status), safe_detail])
  end

  def encode_reason({kind, _detail}) when is_atom(kind) do
    encode_tuple([kind, "redacted_detail"])
  end

  def encode_reason(value) when is_integer(value) do
    %{"type" => "integer", "value" => bounded_integer(value)}
  end

  def encode_reason(value) when is_binary(value) do
    %{"type" => "string", "value" => Maraithon.Redaction.error_summary(value)}
  end

  def encode_reason(_reason) do
    %{"type" => "string", "value" => "redacted_detail"}
  end

  @doc false
  def decode_reason(reason) do
    case do_decode_reason(reason, 0) do
      {:ok, decoded} -> {:ok, restore_policy_decision(decoded)}
      :error -> {:error, @ambiguous_outcome}
    end
  end

  defp decode_envelope_or_legacy(nil, effect), do: decode_legacy(effect)

  defp decode_envelope_or_legacy(envelope, effect) do
    with {:ok, canonical} <- canonical_envelope(envelope),
         true <- known_version?(canonical) do
      decode_present_envelope(canonical, effect)
    else
      _invalid -> ambiguous_result()
    end
  end

  defp decode_present_envelope(envelope, effect) do
    case envelope do
      %{"status" => "ok"} ->
        if Enum.sort(Map.keys(envelope)) == ["status", "version"] do
          decode_success(effect)
        else
          ambiguous_result()
        end

      %{"status" => "error", "reason" => reason} ->
        if exact_keys?(envelope, ["reason", "status", "version"], ["reason", "status"]) do
          case do_decode_reason(reason, 0) do
            {:ok, decoded} -> {:error, restore_policy_decision(decoded)}
            :error -> ambiguous_result()
          end
        else
          ambiguous_result()
        end

      _unknown ->
        ambiguous_result()
    end
  end

  defp decode_legacy(effect) do
    case field(effect, :status) do
      "completed" ->
        if is_nil(field(effect, :result)), do: {:ok, %{}}, else: decode_success(effect)

      "failed" ->
        case field(effect, :error) do
          error when is_binary(error) ->
            if safe_legacy_error?(error), do: {:error, error}, else: ambiguous_result()

          _invalid ->
            ambiguous_result()
        end

      _nonterminal ->
        ambiguous_result()
    end
  end

  defp decode_success(effect) do
    case canonical_result(field(effect, :result)) do
      {:ok, result} -> {:ok, restore_callback_result(field(effect, :effect_type), result)}
      :error -> ambiguous_result()
    end
  end

  defp canonical_envelope(envelope) when is_map(envelope) and not is_struct(envelope) do
    if Maraithon.BoundedJSON.valid?(envelope, @max_envelope_bytes,
         max_binary_bytes: @max_envelope_binary_bytes,
         max_depth: @max_envelope_depth,
         max_nodes: @max_envelope_nodes,
         max_map_entries: 16,
         max_list_items: @max_tuple_arity
       ) do
      with {:ok, encoded} <- Jason.encode(envelope),
           true <- byte_size(encoded) <= @max_envelope_bytes,
           {:ok, canonical} when is_map(canonical) <- Jason.decode(encoded) do
        {:ok, canonical}
      else
        _invalid -> :error
      end
    else
      :error
    end
  rescue
    _error -> :error
  end

  defp canonical_envelope(_envelope), do: :error

  defp canonical_result(result) when is_map(result) and not is_struct(result) do
    if Maraithon.BoundedJSON.valid?(result, @max_result_bytes,
         max_binary_bytes: @max_result_binary_bytes,
         max_depth: 12,
         max_nodes: 20_000,
         max_map_entries: 2_000,
         max_list_items: 2_000
       ) do
      with {:ok, encoded} <- Jason.encode(result),
           true <- byte_size(encoded) <= @max_result_bytes,
           {:ok, canonical} when is_map(canonical) <- Jason.decode(encoded) do
        {:ok, canonical}
      else
        _invalid -> :error
      end
    else
      :error
    end
  rescue
    _error -> :error
  end

  defp canonical_result(_result), do: :error

  defp known_version?(%{"version" => @version}), do: true
  defp known_version?(envelope) when is_map(envelope), do: not Map.has_key?(envelope, "version")
  defp known_version?(_envelope), do: false

  defp exact_keys?(map, versioned_keys, unversioned_keys) do
    Enum.sort(Map.keys(map)) in [Enum.sort(versioned_keys), Enum.sort(unversioned_keys)]
  end

  defp do_decode_reason(_reason, depth) when depth > @max_reason_depth, do: :error

  defp do_decode_reason(%{"type" => "atom", "value" => value} = encoded, _depth)
       when map_size(encoded) == 2 and is_binary(value) and byte_size(value) in 1..128 do
    if String.valid?(value) and :binary.match(value, <<0>>) == :nomatch do
      try do
        {:ok, String.to_existing_atom(value)}
      rescue
        ArgumentError -> :error
      end
    else
      :error
    end
  end

  defp do_decode_reason(%{"type" => "integer", "value" => value} = encoded, _depth)
       when map_size(encoded) == 2 and is_integer(value) and
              value >= -9_223_372_036_854_775_808 and value <= 9_223_372_036_854_775_807,
       do: {:ok, value}

  defp do_decode_reason(%{"type" => "string", "value" => value} = encoded, _depth)
       when map_size(encoded) == 2 and is_binary(value) and byte_size(value) <= 512 do
    if String.valid?(value) and :binary.match(value, <<0>>) == :nomatch,
      do: {:ok, value},
      else: :error
  end

  defp do_decode_reason(%{"type" => "tuple", "items" => items} = encoded, depth)
       when map_size(encoded) == 2 and is_list(items) and
              length(items) in 1..@max_tuple_arity do
    with {:ok, decoded} <- decode_reason_items(items, depth + 1, []) do
      {:ok, List.to_tuple(decoded)}
    end
  end

  defp do_decode_reason(
         %{
           "type" => "closed_validation",
           "kind" => kind,
           "reason" => reason
         } = encoded,
         _depth
       )
       when map_size(encoded) == 3 and
              kind in ["incomplete_response", "invalid_response"] and is_binary(reason) do
    if safe_validation_reason?(reason) do
      decoded_kind =
        case kind do
          "incomplete_response" -> :incomplete_response
          "invalid_response" -> :invalid_response
        end

      {:ok, {decoded_kind, %{reason: reason}}}
    else
      :error
    end
  end

  defp do_decode_reason(_reason, _depth), do: :error

  defp decode_reason_items([], _depth, acc), do: {:ok, Enum.reverse(acc)}

  defp decode_reason_items([item | rest], depth, acc) do
    case do_decode_reason(item, depth) do
      {:ok, decoded} -> decode_reason_items(rest, depth, [decoded | acc])
      :error -> :error
    end
  end

  defp encode_closed_validation(kind, reason) do
    safe_reason = if safe_validation_reason?(reason), do: reason, else: "redacted_detail"

    %{
      "type" => "closed_validation",
      "kind" => Atom.to_string(kind),
      "reason" => safe_reason
    }
  end

  defp encode_tuple(items) do
    %{"type" => "tuple", "items" => Enum.map(items, &encode_reason/1)}
  end

  defp policy_reason_code(kind, decision) do
    requested = Map.get(decision, "reason_code") || Map.get(decision, :reason_code)
    allowed = Map.fetch!(@policy_reason_codes, kind)
    fallback = Map.fetch!(@policy_fallback_codes, kind)

    if is_binary(requested) and byte_size(requested) in 1..80 and String.valid?(requested),
      do: Map.get(allowed, requested, fallback),
      else: fallback
  end

  defp restore_policy_decision({kind, encoded_code}) when kind in @policy_kinds do
    code = normalize_policy_reason_code(kind, encoded_code)

    status =
      case kind do
        :tool_policy_denied -> "deny"
        :tool_policy_needs_confirmation -> "needs_confirmation"
      end

    metadata =
      if kind == :tool_policy_needs_confirmation,
        do: %{"confirmation_required" => true},
        else: %{}

    decision =
      PolicyDecisionCopy.sanitize(%{
        "status" => status,
        "reason_code" => Atom.to_string(code),
        "metadata" => metadata
      })

    {kind, decision}
  end

  defp restore_policy_decision(decoded), do: decoded

  defp normalize_policy_reason_code(kind, encoded_code) do
    allowed = Map.fetch!(@policy_reason_codes, kind)
    fallback = Map.fetch!(@policy_fallback_codes, kind)

    cond do
      is_binary(encoded_code) and byte_size(encoded_code) in 1..80 ->
        Map.get(allowed, encoded_code, fallback)

      is_atom(encoded_code) ->
        Enum.find_value(allowed, fallback, fn {_wire_code, atom_code} ->
          if atom_code == encoded_code, do: atom_code
        end)

      true ->
        fallback
    end
  end

  defp safe_validation_reason?(reason)
       when is_binary(reason) and byte_size(reason) <= 128 do
    String.valid?(reason) and Regex.match?(~r/^[A-Za-z0-9._:-]+$/, reason)
  end

  defp safe_validation_reason?(_reason), do: false

  defp safe_legacy_error?(error) when byte_size(error) <= 512 do
    String.valid?(error) and :binary.match(error, <<0>>) == :nomatch
  end

  defp safe_legacy_error?(_error), do: false

  defp restore_callback_result(effect_type, value)
       when effect_type in ["llm_call", :llm_call] and is_map(value) do
    Map.new(value, fn {key, nested} ->
      restored_key = Map.get(@llm_result_atom_keys, key, key)
      {restored_key, restore_callback_result(effect_type, nested)}
    end)
  end

  defp restore_callback_result(effect_type, value)
       when effect_type in ["llm_call", :llm_call] and is_list(value),
       do: Enum.map(value, &restore_callback_result(effect_type, &1))

  defp restore_callback_result(_effect_type, value), do: value

  defp bounded_integer(value)
       when value < -9_223_372_036_854_775_808,
       do: -9_223_372_036_854_775_808

  defp bounded_integer(value)
       when value > 9_223_372_036_854_775_807,
       do: 9_223_372_036_854_775_807

  defp bounded_integer(value), do: value

  defp field(effect, key) do
    Map.get(effect, key, Map.get(effect, Atom.to_string(key)))
  end

  defp ambiguous_result, do: {:error, @ambiguous_outcome}
end
