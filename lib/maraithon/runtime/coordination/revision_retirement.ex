defmodule Maraithon.Runtime.Coordination.RevisionRetirement do
  @moduledoc """
  Requests retirement of the exact Cloud Run revisions observed before a deploy.

  HTTP routing cannot address an instance kept alive by an existing WebSocket.
  Fence its durable node instead; its Session observes `draining` on renewal
  and performs local termination and proof persistence. This never supplies a
  termination proof or declares a provider outcome.
  """

  import Ecto.Query

  alias Maraithon.Repo
  alias Maraithon.Runtime.Coordination.{Authority, NodeIncarnation, Session}

  def live_revisions do
    case System.get_env("K_SERVICE") do
      service when is_binary(service) and service != "" ->
        service
        |> live_nodes()
        |> select([node], fragment("?->>'cloud_run_revision'", node.metadata))
        |> distinct(true)
        |> Repo.all()
        |> Enum.filter(&valid_revision?/1)
        |> Enum.sort()

      _ ->
        []
    end
  end

  def request(serving_revision, revisions) do
    with :ok <- validate_request(serving_revision, revisions),
         %{phase: :ready} <- Session.status() do
      results =
        System.fetch_env!("K_SERVICE")
        |> live_nodes()
        |> where([node], fragment("?->>'cloud_run_revision'", node.metadata) in ^revisions)
        |> order_by([node], asc: node.id)
        |> Repo.all()
        |> Enum.map(&request_node/1)

      {:ok,
       %{
         requested: Enum.count(results, &(&1.result == "requested")),
         failed: Enum.count(results, &(&1.result == "retry_needed")),
         nodes: results
       }}
    else
      {:error, _reason} = error -> error
      _ -> {:error, :runtime_not_ready}
    end
  rescue
    _error -> {:error, :retirement_unavailable}
  catch
    :exit, _reason -> {:error, :retirement_unavailable}
  end

  defp validate_request(serving_revision, revisions) do
    cond do
      not valid_revision?(serving_revision) or not is_list(revisions) ->
        {:error, :invalid_retirement_request}

      length(revisions) > 64 or not Enum.all?(revisions, &valid_revision?/1) ->
        {:error, :invalid_retirement_request}

      serving_revision in revisions ->
        {:error, :cannot_retire_serving_revision}

      serving_revision != System.get_env("K_REVISION") or
          System.get_env("K_SERVICE") in [nil, ""] ->
        {:error, :serving_revision_mismatch}

      true ->
        :ok
    end
  end

  defp valid_revision?(revision) when is_binary(revision) and byte_size(revision) <= 63,
    do: Regex.match?(~r/\A[a-z][a-z0-9-]*\z/, revision)

  defp valid_revision?(_revision), do: false

  defp live_nodes(service) do
    from(node in NodeIncarnation,
      where: node.state in ["joining", "ready", "draining"],
      where: node.lease_expires_at > fragment("timezone('UTC', clock_timestamp())"),
      where: fragment("?->>'cloud_run_service'", node.metadata) == ^service
    )
  end

  defp request_node(node) do
    result =
      case Authority.begin_node_drain(node) do
        {:ok, :draining} -> "requested"
        _ -> "retry_needed"
      end

    %{node_id: node.id, revision: node.metadata["cloud_run_revision"], result: result}
  rescue
    _error ->
      %{node_id: node.id, revision: node.metadata["cloud_run_revision"], result: "retry_needed"}
  end
end
