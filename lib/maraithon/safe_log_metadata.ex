defmodule Maraithon.SafeLogMetadata do
  @moduledoc false

  # One closed schema controls both formatter inclusion and value
  # classification. Adding a field in one place cannot accidentally make the
  # in-memory backend and production JSON formatter disagree.
  @opaque_fields ~w(
    body callbackerror content context error fallbackreason messages originalreason prompt
    providerbody rawbody reason requestbody responsebody tooloutput
  )

  @identifier_fields ~w(userid chatid telegramchatid accountid owneruserid)

  @numeric_fields ~w(
    durationms retryafterms inputtokens outputtokens reasoningtokens costusd
    choicecount detailfailurecount promptbytes promptbytecap basepromptbytes
    availablecandidates includedcandidates users usercount planned interruptnow
    providererrorcode digest held delivered deliveryunknown failed undeliverable expired recovered
    sent suppressed disabled responsestatus truncated backfillneeded
    candidatecount devicecount sourcecount itemcount rejected unregistered attempt iteration
    detected swept alerted count oldestageseconds activecandidatecount activejobcount
    activeeffectcount
  )

  @label_fields ~w(
    requestid agentid effectid jobid jobtype provider useridhash userfingerprint
    agentreference devicereference candidatereference effectreference cyclereference
    providerreference targetreference
    model reasoningeffort finishreason failurecode responseshape errorclass
    transportclass callbackclass promptkind effecttype eventtype table
  )

  @structured_fields [
    :request_id,
    :agent_id,
    :effect_id,
    :job_id,
    :job_type,
    :error,
    :reason,
    :provider,
    :provider_reference,
    :agent_reference,
    :user_id,
    :user_id_hash,
    :user_fingerprint,
    :device_reference,
    :candidate_reference,
    :effect_reference,
    :cycle_reference,
    :target_reference,
    :status,
    :duration_ms,
    :retry_after_ms,
    :model,
    :reasoning_effort,
    :input_tokens,
    :output_tokens,
    :reasoning_tokens,
    :cost_usd,
    :finish_reason,
    :choice_count,
    :detail_failure_count,
    :truncated,
    :backfill_needed,
    :sent,
    :held,
    :suppressed,
    :failed,
    :disabled,
    :failure_code,
    :failure_codes,
    :response_status,
    :provider_error_code,
    :response_shape,
    :error_class,
    :transport_class,
    :callback_class,
    :prompt_kind,
    :base_prompt_bytes,
    :prompt_bytes,
    :prompt_byte_cap,
    :available_candidates,
    :included_candidates,
    :users,
    :user_count,
    :planned,
    :interrupt_now,
    :digest,
    :delivered,
    :delivery_unknown,
    :undeliverable,
    :expired,
    :recovered,
    :candidate_count,
    :device_count,
    :source_count,
    :item_count,
    :rejected,
    :unregistered,
    :attempt,
    :iteration,
    :detected,
    :swept,
    :alerted,
    :count,
    :oldest_age_seconds,
    :active_candidate_count,
    :active_job_count,
    :active_effect_count,
    :effect_type,
    :event_type,
    :table
  ]

  def structured_fields, do: @structured_fields

  def structured_key?(key) when is_atom(key), do: key in @structured_fields

  def structured_key?(key) when is_binary(key) do
    Enum.any?(@structured_fields, &(Atom.to_string(&1) == key))
  end

  def structured_key?(_key), do: false

  def classification(key) do
    normalized = normalize_key(key)

    cond do
      normalized in @identifier_fields -> :identifier
      normalized in @opaque_fields -> :opaque
      normalized == "status" -> :status
      normalized in @numeric_fields -> :numeric
      normalized in @label_fields -> :label
      normalized == "failurecodes" -> :failure_codes
      true -> :unknown
    end
  end

  defp normalize_key(key) do
    key
    |> to_string()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]/, "")
  end
end
