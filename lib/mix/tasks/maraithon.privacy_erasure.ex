defmodule Mix.Tasks.Maraithon.PrivacyErasure do
  use Mix.Task

  alias Maraithon.PrivacyErasure

  @shortdoc "Request, enqueue, or inspect durable privacy erasure"
  @switches [idempotency_key: :string, user_id: :string, limit: :integer]

  @moduledoc """
  Storage-only privacy erasure operator. It starts config, Ecto SQL, Vault,
  and Repo, never Maraithon.Application, web endpoints, or runtime producers.

      mix maraithon.privacy_erasure request-user USER_ID [--idempotency-key KEY]
      mix maraithon.privacy_erasure request-agent AGENT_ID [--user-id USER_ID] [--idempotency-key KEY]
      mix maraithon.privacy_erasure status REQUEST_ID
      mix maraithon.privacy_erasure enqueue [--limit 50]
  """

  @impl Mix.Task
  def run(args) do
    {opts, argv, invalid} = OptionParser.parse(args, strict: @switches)
    if invalid != [], do: Mix.raise(usage())

    start_storage_only!()

    result =
      case argv do
        ["request-user", user_id] ->
          PrivacyErasure.request_user(user_id, request_opts(opts))

        ["request-agent", agent_id] ->
          PrivacyErasure.request_agent(agent_id, request_opts(opts, include_user?: true))

        ["status", request_id] when opts == [] ->
          PrivacyErasure.status(request_id)

        ["enqueue"] ->
          PrivacyErasure.discover_missing_jobs(Keyword.get(opts, :limit, 50))

        _other ->
          Mix.raise(usage())
      end

    case result do
      {:ok, value} -> Mix.shell().info(Jason.encode!(json_value(value), pretty: true))
      {:error, reason} -> Mix.raise("privacy erasure operation failed: #{error_code(reason)}")
    end
  end

  defp request_opts(opts, extra \\ []) do
    []
    |> maybe_put(:idempotency_key, opts[:idempotency_key])
    |> maybe_put_user(opts[:user_id], Keyword.get(extra, :include_user?, false))
  end

  defp maybe_put_user(opts, nil, _include?), do: opts
  defp maybe_put_user(opts, user_id, true), do: Keyword.put(opts, :user_id, user_id)
  defp maybe_put_user(opts, _user_id, false), do: opts

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp json_value(%Maraithon.Privacy.ErasureRequest{id: id}) do
    case PrivacyErasure.status(id) do
      {:ok, status} -> status
      {:error, _reason} -> %{state: "requested"}
    end
  end

  defp json_value(value), do: value

  defp error_code(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp error_code({code, _detail}) when is_atom(code), do: Atom.to_string(code)
  defp error_code(_reason), do: "privacy_erasure_failed"

  defp start_storage_only! do
    Mix.Task.run("app.config")

    case Application.ensure_all_started(:ecto_sql) do
      {:ok, _apps} -> :ok
      {:error, _reason} -> Mix.raise("could not start privacy erasure storage dependencies")
    end

    start_once(Maraithon.Vault)
    start_once(Maraithon.Repo)
  end

  defp start_once(module) do
    case module.start_link() do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
      {:error, _reason} -> Mix.raise("could not start privacy erasure storage")
    end
  end

  defp usage do
    """
    Usage:
      mix maraithon.privacy_erasure request-user USER_ID [--idempotency-key KEY]
      mix maraithon.privacy_erasure request-agent AGENT_ID [--user-id USER_ID] [--idempotency-key KEY]
      mix maraithon.privacy_erasure status REQUEST_ID
      mix maraithon.privacy_erasure enqueue [--limit 50]
    """
  end
end
