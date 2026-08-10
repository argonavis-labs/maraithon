defmodule MaraithonWeb.AgentTerminationIncidentController do
  @moduledoc """
  Admin-only, read-only detail surface for Agent termination incidents.

  External evidence is written only through the separately credentialed
  incident-operator task. The ordinary web/runtime database role cannot insert
  an external proof or delete the fenced lease.
  """

  use MaraithonWeb, :controller

  alias Maraithon.Runtime.AgentTerminations

  def show(conn, %{"id" => id}) do
    case AgentTerminations.get(id) do
      nil ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "termination_incident_not_found"})

      incident ->
        proof = AgentTerminations.proof_for(incident.id)

        json(conn, %{
          incident: incident_json(incident),
          proof: proof_json(proof),
          attestation: %{
            algorithm: "Ed25519",
            domain: "maraithon-agent-termination-v1",
            required_role: AgentTerminations.operator_role(),
            detail_url: AgentTerminations.operator_url(incident),
            command: "mix maraithon.agents.attest_terminated",
            evidence_digest_encoding: "hex_sha256",
            signature_encoding: "base64"
          }
        })
    end
  end

  defp incident_json(incident) do
    %{
      id: incident.id,
      status: incident.status,
      activation_epoch: incident.activation_epoch,
      node_incarnation_id: incident.node_incarnation_id,
      partition_id: incident.partition_id,
      partition_epoch: incident.partition_epoch,
      agent_id: incident.agent_id,
      lease_token: incident.lease_token,
      owner_node: incident.owner_node,
      request_reason: incident.request_reason,
      requested_at: incident.requested_at,
      proved_at: incident.proved_at,
      reconciled_at: incident.reconciled_at,
      retry_at: incident.retry_at,
      reconcile_attempts: incident.reconcile_attempts,
      last_error: incident.last_error,
      required_role: AgentTerminations.operator_role()
    }
  end

  defp proof_json(nil), do: nil

  defp proof_json(proof) do
    %{
      id: proof.id,
      proof_kind: proof.proof_kind,
      evidence_id: proof.evidence_id,
      evidence_digest: encode_hex(proof.evidence_digest),
      proved_by: proof.proved_by,
      proved_at: proof.proved_at
    }
  end

  defp encode_hex(nil), do: nil
  defp encode_hex(value), do: Base.encode16(value, case: :lower)
end
