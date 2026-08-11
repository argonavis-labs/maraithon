defmodule Maraithon.KeyRetirementBootGuard do
  @moduledoc """
  Refuses to start a writer whose configured current key tag was durably fenced.

  PostgreSQL triggers remain authoritative for nodes that were already running
  or were started from older code. Previous/read-only keyring entries stay
  configured until the separately authorized external removal step.
  """

  use GenServer

  alias Maraithon.DurablePayloadBinding
  alias Maraithon.Repo
  alias Maraithon.Vault

  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @impl true
  def init(:ok) do
    case Repo.query!(
           """
           SELECT public.durable_payload_key_write_fenced('vault', $1),
                  public.durable_payload_key_write_fenced('binding', $2)
           """,
           [Vault.current_key_tag(), DurablePayloadBinding.current_key_tag()],
           log: false
         ).rows do
      [[false, false]] ->
        {:ok, %{}}

      [[vault_fenced, binding_fenced]] ->
        fenced_kinds =
          []
          |> maybe_fenced(:vault, vault_fenced)
          |> maybe_fenced(:binding, binding_fenced)

        {:stop, {:current_durable_payload_key_tag_retired, fenced_kinds}}
    end
  rescue
    error ->
      {:stop, {:durable_payload_key_fence_unavailable, Exception.message(error)}}
  end

  defp maybe_fenced(kinds, kind, true), do: [kind | kinds]
  defp maybe_fenced(kinds, _kind, false), do: kinds
end
