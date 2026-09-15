defmodule Maraithon.Delegations.Sources do
  @moduledoc "A bounded, account-scoped source refresh outside the coordinator and DB transaction."
  alias Maraithon.{DurablePayload, Repo}
  alias Maraithon.Connectors.{Gmail, GoogleAccount}
  alias Maraithon.Delegations.{Ingress, Jobs, SlackSource, SlackIngress}
  alias Maraithon.Runtime.BackgroundJob
  alias Maraithon.TelegramAssistant.Run

  @max_messages 100
  @max_bytes 240_000

  def verify_before_send(_job, %{delegation: %{provider: "gmail", provider_thread_id: nil}}),
    do: :ok

  def verify_before_send(job, context) do
    d = context.delegation

    with {:ok, messages, fresh} <- fetch(d, context.grant.data["scope"]) do
      previous = context.run.prompt_snapshot["sources"]
      ids = fn source -> MapSet.new(source["messages"], &{&1["message_id"], &1["revision"]}) end

      if ids.(fresh) == ids.(previous) do
        :ok
      else
        case Jobs.transaction(job, fn _ ->
               route!(context, messages, fresh)
             end) do
          {:ok, _} -> {:error, :source_changed}
          error -> error
        end
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
      d = context.delegation
      scope = context.grant.data["scope"]

      with {:ok, messages, sources} <- fetch(d, scope) do
        persist(job, context, messages, sources)
      else
        {:error, reason} -> source_error(job, reason)
      end
    end
  end

  defp persist(job, context, messages, sources) do
    # Ingestion and the source snapshot share the worker's ownership fence. A
    # missed reply advances the revision here before any decision can be made.
    Jobs.transaction(job, fn current ->
      if context.delegation.provider_thread_id do
        route!(context, messages, sources)
      end

      d = Repo.get!(Maraithon.Delegations.Delegation, current.delegation.id)

      if d.source_revision != current.turn.source_revision do
        %{state: "new_messages", run_id: current.run.id}
      else
        snapshot = Map.put(current.run.prompt_snapshot, "sources", sources)
        current.run |> Run.changeset(%{prompt_snapshot: snapshot}) |> Repo.update!()
        Jobs.result!(current, "sync_result", %{})
        %{state: "synced", run_id: current.run.id}
      end
    end)
  end

  defp fetch(%{provider: "gmail"} = d, scope) do
    account =
      if d.provider_thread_id, do: d.connected_account_id, else: scope["source_account_id"]

    thread = d.provider_thread_id || scope["source_thread_id"]

    with {:ok, token} <- GoogleAccount.access_token(d.user_id, account),
         {:ok, messages} <- Gmail.fetch_thread_content(token, thread, access_token: true),
         {:ok, sources} <- snapshot(messages, account, thread),
         do: {:ok, messages, sources}
  end

  defp fetch(%{provider: "slack"} = d, scope) do
    channel = if d.provider_thread_id, do: d.slack_channel, else: scope["source_channel_id"]
    thread = d.provider_thread_id || scope["source_thread_id"]

    with {:ok, sources} <-
           SlackSource.fetch(d.user_id, scope["identity"], channel, thread,
             include_unthreaded?:
               not is_nil(d.provider_thread_id) and String.starts_with?(d.slack_channel, "D") and
                 SlackIngress.only_live_id(d.user_id, d.slack_channel) == d.id
           ),
         do: {:ok, sources["messages"], sources}
  end

  defp fetch(_, _), do: {:error, :unsupported_delegation_source}

  defp route!(
         %{delegation: %{provider: "slack", provider_thread_id: nil} = d, grant: grant},
         messages,
         _sources
       ),
       do: Enum.each(messages, &SlackIngress.accept_source!(d, grant.data["scope"], &1))

  defp route!(%{delegation: %{provider: "slack"} = d, grant: grant}, messages, _sources),
    do: Enum.each(messages, &SlackIngress.accept!(d.user_id, grant.data["scope"]["team_id"], &1))

  defp route!(%{delegation: d}, messages, sources),
    do: Enum.each(messages, &Ingress.gmail!(d.user_id, sources["account_id"], &1))

  defp source_error(job, reason) do
    # A rate limit is a queue cooldown, not a new model call or a tight retry.
    case reason do
      {:rate_limited, seconds, _} when is_integer(seconds) ->
        {:error, {:retry_after, max(seconds, 30), reason}}

      {:rate_limited, _} ->
        {:error, {:retry_after, 30, reason}}

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

  @doc "Never label a partial, empty, cross-thread, or oversized read as complete."
  def snapshot(messages, account_id, thread_id) when is_list(messages) do
    messages = Enum.reject(messages, &("DRAFT" in (&1.labels || [])))
    ids = Enum.map(messages, & &1.message_id)

    if length(messages) in 1..@max_messages and length(Enum.uniq(ids)) == length(ids) and
         Enum.all?(messages, &valid_message?(&1, thread_id)) do
      data = %{
        "account_id" => account_id,
        "thread_id" => thread_id,
        "read_at" => DateTime.to_iso8601(DateTime.utc_now()),
        "complete" => true,
        "messages" =>
          messages |> Enum.sort_by(& &1.internal_date, DateTime) |> Enum.map(&public_message/1)
      }

      case DurablePayload.prepare_map(data, @max_bytes) do
        {:ok, bounded} -> {:ok, bounded}
        _ -> {:error, :source_gap}
      end
    else
      {:error, :source_gap}
    end
  end

  def snapshot(_, _, _), do: {:error, :source_gap}

  defp valid_message?(m, thread_id) do
    Gmail.valid_id?(m.message_id) and m.thread_id == thread_id and
      is_struct(m.internal_date, DateTime) and is_binary(m.internet_message_id) and
      m.internet_message_id != "" and is_binary(m.text_body) and
      length(Enum.filter(Gmail.message_participants(m), &(&1["role"] == "from"))) == 1
  end

  defp public_message(m) do
    Map.take(
      m,
      ~w(message_id thread_id from to cc subject internet_message_id in_reply_to references text_body auto_submitted return_path content_type labels)a
    )
    |> Map.put(:internal_date, DateTime.to_iso8601(m.internal_date))
  end
end
