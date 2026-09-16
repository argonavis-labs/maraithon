defmodule Maraithon.Delegations.Sources do
  @moduledoc "A bounded, account-scoped source refresh outside the coordinator and DB transaction."
  alias Maraithon.Repo
  alias Maraithon.Delegations.{GmailSource, Ingress, Jobs, SlackSource, SlackIngress, Toolbox}
  alias Maraithon.Runtime.BackgroundJob
  alias Maraithon.TelegramAssistant.Run

  def verify_before_send(job, %{delegation: %{provider: "gmail"} = d} = context) do
    with {:ok, index} <- GmailSource.index(d, context.grant.data["scope"]) do
      if GmailSource.unchanged?(index, context.run.prompt_snapshot["sources"]) do
        Toolbox.verify_before_send(context)
      else
        with {:ok, messages, sources} <- GmailSource.read(context, index),
             {:ok, _} <-
               Jobs.transaction(job, fn current -> route!(current, messages, sources) end),
             do: {:error, :source_changed}
      end
    end
  end

  def verify_before_send(job, context) do
    with {:ok, messages, fresh, progress} <- SlackSource.read(context, "slack_verify"),
         {:ok, result} <-
           Jobs.transaction(job, fn current ->
             route!(current, messages, fresh)
             save_progress!(current.run, "slack_verify", if(fresh, do: nil, else: progress))

             d = Repo.get!(Maraithon.Delegations.Delegation, current.delegation.id)

             cond do
               d.source_revision != current.turn.source_revision -> :changed
               is_nil(fresh) -> :reading
               SlackSource.unchanged?(fresh, current.run.prompt_snapshot["sources"]) -> :unchanged
               true -> :changed
             end
           end) do
      case result do
        :unchanged -> Toolbox.verify_before_send(context)
        :reading -> {:retry, 1_000}
        :superseded -> {:error, :source_changed}
        :changed -> {:error, :source_changed}
      end
    end
  end

  def execute(%BackgroundJob{job_type: "delegation_sync"} = job) do
    job = BackgroundJob.hydrate_payloads(job)

    result =
      case Jobs.transaction(job, & &1) do
        {:ok, :superseded} -> {:ok, :superseded}
        {:ok, context} -> refresh(job, context)
        error -> error
      end

    Jobs.finish(result, job)
  end

  defp refresh(job, context) do
    if is_map(context.run.prompt_snapshot["sources"]) do
      Jobs.transaction(job, fn current ->
        Jobs.result!(current, "sync_result", %{})
        %{state: "synced", run_id: current.run.id}
      end)
    else
      with {:ok, messages, sources, progress} <- read(context) do
        persist(job, messages, sources, progress)
      else
        {:error, reason} -> source_error(job, reason)
      end
    end
  end

  defp read(%{delegation: %{provider: "gmail"}} = context) do
    with {:ok, messages, sources} <- GmailSource.read(context),
         do: {:ok, messages, sources, nil}
  end

  defp read(context), do: SlackSource.read(context, "slack_read")

  defp save_progress!(run, key, progress) do
    snapshot =
      if progress,
        do: Map.put(run.prompt_snapshot, key, progress),
        else: Map.delete(run.prompt_snapshot, key)

    run |> Run.changeset(%{prompt_snapshot: snapshot}) |> Repo.update!()
  end

  defp persist(job, messages, sources, progress) do
    # Ingestion and the source snapshot share the worker's ownership fence. A
    # missed reply advances the revision here before any decision can be made.
    Jobs.transaction(job, fn current ->
      route!(current, messages, sources)

      run =
        if current.delegation.provider == "slack",
          do: save_progress!(current.run, "slack_read", if(sources, do: nil, else: progress)),
          else: current.run

      d = Repo.get!(Maraithon.Delegations.Delegation, current.delegation.id)

      cond do
        d.source_revision != current.turn.source_revision ->
          %{state: "new_messages", run_id: current.run.id}

        is_nil(sources) ->
          %{state: "syncing", run_id: current.run.id}

        true ->
          snapshot = Map.put(run.prompt_snapshot, "sources", sources)
          run |> Run.changeset(%{prompt_snapshot: snapshot}) |> Repo.update!()
          Jobs.result!(current, "sync_result", %{})
          %{state: "synced", run_id: current.run.id}
      end
    end)
    |> case do
      {:ok, %{state: "syncing"} = result} -> {:ok, result, {:reschedule_in, 1_000}}
      result -> result
    end
  end

  defp route!(
         %{delegation: %{provider: "slack", provider_thread_id: nil} = d, grant: grant},
         messages,
         _sources
       ),
       do: Enum.each(messages, &SlackIngress.accept_source!(d, grant.data["scope"], &1))

  defp route!(%{delegation: %{provider: "slack"} = d, grant: grant}, messages, _sources),
    do: Enum.each(messages, &SlackIngress.accept!(d.user_id, grant.data["scope"]["team_id"], &1))

  defp route!(%{delegation: %{provider_thread_id: nil} = d, grant: grant}, messages, _),
    do: Enum.each(messages, &Ingress.gmail_source!(d, grant.data["scope"], &1))

  defp route!(%{delegation: d}, messages, _),
    do: Enum.each(messages, &Ingress.gmail!(d.user_id, d.connected_account_id, &1))

  defp source_error(job, reason) do
    # A rate limit is a queue cooldown, not a new model call or a tight retry.
    case reason do
      {:rate_limited, seconds, _} when is_integer(seconds) ->
        Jobs.provider_wait(job, seconds, reason)

      {:rate_limited, _} ->
        Jobs.provider_wait(job, 30, reason)

      {:http_error, _} when job.attempts + 1 < job.max_attempts ->
        {:error, :source_temporarily_unavailable}

      {:http_status, status, _} when status >= 500 and job.attempts + 1 < job.max_attempts ->
        {:error, :source_temporarily_unavailable}

      _ ->
        Jobs.transaction(job, fn context ->
          Jobs.hold!(context, Maraithon.Redaction.error_class(reason))
          %{state: "needs_user", run_id: context.run.id}
        end)
    end
  end

  @doc "Keep a complete thread fingerprint and its six most recent message bodies."
  def snapshot(messages, account_id, thread_id),
    do: GmailSource.snapshot(messages, account_id, thread_id)
end
