defmodule Maraithon.Runtime.IngressReceipts do
  @moduledoc """
  Feature-dark durable admission for exact provider events.

  `record_in_transaction/1` is the future atomic ingress boundary: a caller can
  record the immutable receipt and enqueue its Agent directive in the same
  caller-owned transaction before acknowledging the provider transport. It
  derives provider-account identity from the connected account and admits only
  an enabled Agent with an active same-user binding and exact connector grant.
  """

  import Ecto.Query

  alias Maraithon.Accounts.ConnectedAccount
  alias Maraithon.Agents.Agent
  alias Maraithon.AgentIsolation.Binding
  alias Maraithon.Lineage.Canonical
  alias Maraithon.Lineage.Transaction
  alias Maraithon.Repo
  alias Maraithon.Runtime.DatabaseClock
  alias Maraithon.Runtime.IngressReceipt

  @max_payload_bytes 128_000
  @authority_errors [
    :ingress_owner_mismatch,
    :ingress_account_not_connected,
    :ingress_agent_not_enabled,
    :ingress_binding_inactive,
    :ingress_connector_not_granted,
    :ingress_provider_account_mismatch,
    :invalid_provider_account_identity
  ]
  @identity_fields [
    :user_id,
    :agent_id,
    :connected_account_id,
    :provider,
    :provider_account_key,
    :ingress_kind,
    :provider_event_key
  ]

  def record(attrs) when is_map(attrs) do
    case Repo.transaction(fn -> record_in_transaction(attrs) end) do
      {:ok, result} -> result
      {:error, reason} -> {:error, reason}
    end
  end

  def record(_attrs), do: {:error, :invalid_ingress_receipt}

  def record_in_transaction(attrs) when is_map(attrs) do
    with :ok <- Transaction.require(),
         {:ok, prepared} <- prepare(attrs) do
      insert_or_compare(prepared)
    end
  end

  def record_in_transaction(_attrs) do
    with :ok <- Transaction.require(), do: {:error, :invalid_ingress_receipt}
  end

  def get_by_provider_identity(attrs) when is_map(attrs) do
    with {:ok, identity} <- identity(attrs),
         {:ok, account} <- get_exact_account(identity),
         {:ok, provider_account_key} <- persisted_provider_account_key(account),
         :ok <- verify_provider_account_key(attrs, provider_account_key) do
      identity
      |> Map.put(:provider_account_key, provider_account_key)
      |> identity_query()
      |> Repo.one()
    else
      _error -> nil
    end
  end

  def get_by_provider_identity(_attrs), do: nil

  defp prepare(attrs) do
    with {:ok, identity} <- identity(attrs),
         {:ok, authority} <- lock_authority(identity),
         :ok <- active_authority(authority),
         {:ok, provider_account_key} <- persisted_provider_account_key(authority.account),
         :ok <- verify_provider_account_key(attrs, provider_account_key),
         :ok <- exact_connector_grant(authority, identity.provider, provider_account_key),
         identity <- Map.put(identity, :provider_account_key, provider_account_key),
         {:ok, payload, encoded_payload, _payload_digest} <-
           Canonical.object(value(attrs, :payload, %{}), @max_payload_bytes,
             max_binary_bytes: 100_000,
             max_depth: 12,
             max_nodes: 20_000,
             max_map_entries: 2_000,
             max_list_items: 5_000
           ),
         {:ok, receipt_key} <-
           Canonical.identity("runtime-ingress-receipt-v1", [
             identity.user_id,
             identity.agent_id,
             identity.connected_account_id,
             identity.provider,
             identity.provider_account_key,
             identity.ingress_kind,
             identity.provider_event_key
           ]),
         {:ok, request_fingerprint} <-
           Canonical.identity("runtime-ingress-fingerprint-v1", [
             identity.ingress_kind,
             encoded_payload
           ]),
         {:ok, provider_occurred_at} <- optional_datetime(value(attrs, :provider_occurred_at)) do
      now = DatabaseClock.now!()

      prepared =
        identity
        |> Map.merge(%{
          id: Ecto.UUID.generate(),
          receipt_key: receipt_key,
          payload: payload,
          request_fingerprint: request_fingerprint,
          provider_occurred_at: provider_occurred_at,
          received_at: now,
          inserted_at: now
        })

      changeset = IngressReceipt.changeset(%IngressReceipt{}, prepared)
      if changeset.valid?, do: {:ok, prepared}, else: {:error, changeset}
    else
      false -> {:error, :invalid_ingress_receipt}
      {:error, :invalid_lineage_payload} -> {:error, :invalid_ingress_payload}
      {:error, reason} when reason in @authority_errors -> {:error, reason}
      {:error, _reason} -> {:error, :invalid_ingress_receipt}
    end
  end

  defp identity(attrs) do
    with {:ok, user_id} <- Canonical.string(value(attrs, :user_id), 320, allow_whitespace: false),
         {:ok, agent_id} <- uuid(value(attrs, :agent_id)),
         {:ok, connected_account_id} <- positive_integer(value(attrs, :connected_account_id)),
         {:ok, provider} <-
           Canonical.string(value(attrs, :provider), 80, allow_whitespace: false),
         {:ok, ingress_kind} <- ingress_kind(value(attrs, :ingress_kind)),
         {:ok, provider_event_key} <-
           Canonical.string(value(attrs, :provider_event_key), 512) do
      {:ok,
       %{
         user_id: user_id,
         agent_id: agent_id,
         connected_account_id: connected_account_id,
         provider: provider,
         ingress_kind: ingress_kind,
         provider_event_key: provider_event_key
       }}
    end
  end

  defp insert_or_compare(prepared) do
    case Repo.insert_all(IngressReceipt, [prepared],
           on_conflict: :nothing,
           conflict_target: @identity_fields,
           returning: [:id]
         ) do
      {1, _rows} ->
        {:ok, Repo.get!(IngressReceipt, prepared.id), :inserted}

      {0, _rows} ->
        existing = Repo.one!(identity_query(prepared) |> lock("FOR SHARE"))
        compare_existing(existing, prepared)
    end
  end

  defp compare_existing(existing, prepared) do
    same_identity? =
      Enum.all?(@identity_fields, &(Map.get(existing, &1) == Map.get(prepared, &1)))

    cond do
      not same_identity? or existing.receipt_key != prepared.receipt_key ->
        {:error, :ingress_identity_collision}

      existing.request_fingerprint == prepared.request_fingerprint and
        existing.payload == prepared.payload and
          existing.provider_occurred_at == prepared.provider_occurred_at ->
        {:ok, existing, :duplicate}

      true ->
        {:error, :ingress_idempotency_conflict}
    end
  end

  defp identity_query(identity) do
    from(receipt in IngressReceipt,
      where: receipt.user_id == ^identity.user_id,
      where: receipt.agent_id == ^identity.agent_id,
      where: receipt.connected_account_id == ^identity.connected_account_id,
      where: receipt.provider == ^identity.provider,
      where: receipt.provider_account_key == ^identity.provider_account_key,
      where: receipt.ingress_kind == ^identity.ingress_kind,
      where: receipt.provider_event_key == ^identity.provider_event_key
    )
  end

  defp lock_authority(identity) do
    with {:ok, agent} <- lock_exact_agent(identity),
         {:ok, binding} <- lock_exact_binding(identity),
         {:ok, account} <- lock_exact_account(identity) do
      {:ok, %{agent: agent, binding: binding, account: account}}
    end
  end

  defp lock_exact_agent(identity) do
    case Repo.one(
           from(agent in Agent,
             where: agent.id == ^identity.agent_id and agent.user_id == ^identity.user_id,
             lock: "FOR UPDATE"
           )
         ) do
      %Agent{} = agent -> {:ok, agent}
      nil -> {:error, :ingress_owner_mismatch}
    end
  end

  defp lock_exact_binding(identity) do
    case Repo.one(
           from(binding in Binding,
             where: binding.agent_id == ^identity.agent_id,
             where: binding.user_id == ^identity.user_id,
             lock: "FOR UPDATE"
           )
         ) do
      %Binding{} = binding -> {:ok, binding}
      nil -> {:error, :ingress_binding_inactive}
    end
  end

  defp lock_exact_account(identity) do
    case Repo.one(exact_account_query(identity) |> lock("FOR SHARE")) do
      %ConnectedAccount{} = account -> {:ok, account}
      nil -> {:error, :ingress_owner_mismatch}
    end
  end

  defp get_exact_account(identity) do
    case Repo.one(exact_account_query(identity)) do
      %ConnectedAccount{} = account -> {:ok, account}
      nil -> {:error, :ingress_owner_mismatch}
    end
  end

  defp exact_account_query(identity) do
    from(account in ConnectedAccount,
      where: account.id == ^identity.connected_account_id,
      where: account.user_id == ^identity.user_id,
      where: account.provider == ^identity.provider
    )
  end

  defp active_authority(%{agent: agent, binding: binding, account: account}) do
    cond do
      agent.install_status != "enabled" -> {:error, :ingress_agent_not_enabled}
      binding.status != "active" -> {:error, :ingress_binding_inactive}
      account.status != "connected" -> {:error, :ingress_account_not_connected}
      true -> :ok
    end
  end

  defp persisted_provider_account_key(%ConnectedAccount{external_account_id: value})
       when is_binary(value) and value != "" do
    case Canonical.string(value, 255) do
      {:ok, key} -> {:ok, key}
      _error -> {:error, :invalid_provider_account_identity}
    end
  end

  defp persisted_provider_account_key(_account),
    do: {:error, :invalid_provider_account_identity}

  defp verify_provider_account_key(attrs, expected) do
    case value(attrs, :provider_account_key) do
      nil ->
        :ok

      supplied ->
        case Canonical.string(supplied, 255) do
          {:ok, ^expected} -> :ok
          _mismatch -> {:error, :ingress_provider_account_mismatch}
        end
    end
  end

  defp exact_connector_grant(authority, provider, provider_account_key) do
    agent_granted? =
      connector_granted?(authority.agent.connector_grants, provider, provider_account_key)

    binding_granted? =
      connector_granted?(authority.binding.connector_scope, provider, provider_account_key)

    if agent_granted? and binding_granted?,
      do: :ok,
      else: {:error, :ingress_connector_not_granted}
  end

  defp connector_granted?(grants, provider, provider_account_key) when is_map(grants) do
    case Map.get(grants, provider) do
      grant when is_map(grant) ->
        enabled? = Map.get(grant, "enabled", Map.get(grant, :enabled, true)) != false
        account_ids = Map.get(grant, "account_ids", Map.get(grant, :account_ids, []))

        enabled? and is_list(account_ids) and provider_account_key in account_ids

      _missing ->
        false
    end
  end

  defp connector_granted?(_grants, _provider, _provider_account_key), do: false

  defp ingress_kind(value) when is_atom(value), do: ingress_kind(Atom.to_string(value))

  defp ingress_kind(value) when is_binary(value) do
    if value in IngressReceipt.kinds(),
      do: {:ok, value},
      else: {:error, :invalid_ingress_kind}
  end

  defp ingress_kind(_value), do: {:error, :invalid_ingress_kind}

  defp uuid(value) do
    case Ecto.UUID.cast(value) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, :invalid_uuid}
    end
  end

  defp positive_integer(value) when is_integer(value) and value > 0, do: {:ok, value}
  defp positive_integer(_value), do: {:error, :invalid_account_id}

  defp optional_datetime(nil), do: {:ok, nil}

  defp optional_datetime(%DateTime{} = value),
    do: {:ok, DateTime.truncate(value, :microsecond)}

  defp optional_datetime(_value), do: {:error, :invalid_datetime}

  defp value(attrs, key, default \\ nil) do
    Map.get(attrs, key, Map.get(attrs, Atom.to_string(key), default))
  end
end
