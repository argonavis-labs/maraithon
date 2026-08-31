defmodule Maraithon.Runtime.SourceWatermarkCommit do
  @moduledoc false

  import Ecto.Query

  alias Maraithon.Accounts.User
  alias Maraithon.Accounts.ConnectedAccount
  alias Maraithon.Connectors.SourceCursor
  alias Maraithon.Connectors.SourceCursors
  alias Maraithon.Repo
  alias Maraithon.Runtime.BackgroundJob
  alias Maraithon.Runtime.GmailSourceReplay
  alias Maraithon.Runtime.SourceCycleSettlement

  @slack_conversation_reconcile_job "runtime_partition:slack_conversation_reconcile"

  @job_watermark_kinds %{
    "runtime_partition:source_account_discovery" =>
      ~w(gmail_discovery_watermark slack_discovery_watermark),
    "runtime_partition:source_account_discovery_finalize" =>
      ~w(gmail_discovery_watermark slack_discovery_watermark),
    "runtime_partition:source_account_closure_acquire" =>
      ~w(gmail_closure_watermark slack_closure_watermark),
    "runtime_partition:source_account_closure_finalize" =>
      ~w(gmail_closure_watermark slack_closure_watermark)
  }

  @doc false
  def commit_and_sanitize(
        %BackgroundJob{job_type: @slack_conversation_reconcile_job} = job,
        {:ok, result}
      )
      when is_map(result) do
    case deferred_watermarks(result) do
      nil ->
        {:ok, {:ok, result}}

      [watermark] = watermarks ->
        with account_id when is_integer(account_id) and account_id > 0 <-
               read_integer(result, "account_id"),
             :ok <- validate_slack_conversation_watermark(watermark, account_id),
             {:ok, account, current_value} <-
               lock_source_scope(job.user_id, account_id, watermark),
             {:ok, disposition} <- settlement_disposition(watermark, current_value) do
          settle_slack_conversation_disposition(
            disposition,
            result,
            account,
            watermarks
          )
        else
          nil -> {:error, :source_watermark_account_not_found}
          {:error, _reason} = error -> error
          _invalid -> {:error, :invalid_deferred_source_watermark}
        end

      _invalid ->
        {:error, :invalid_deferred_source_watermark}
    end
  end

  def commit_and_sanitize(%BackgroundJob{} = job, {:ok, result}) when is_map(result) do
    case deferred_watermarks(result) do
      nil ->
        {:ok, {:ok, result}}

      watermarks when is_list(watermarks) ->
        with {:ok, allowed_kinds} <- allowed_kinds(job.job_type),
             account_id when is_integer(account_id) and account_id > 0 <-
               read_integer(result, "account_id"),
             :ok <- validate_watermarks(watermarks, account_id, allowed_kinds),
             {:ok, account, current_value} <-
               lock_source_scope(job.user_id, account_id, hd(watermarks)),
             :ok <- validate_source_contract(job, account, hd(watermarks)),
             {:ok, disposition} <- settlement_disposition(hd(watermarks), current_value) do
          settle_disposition(disposition, job, result, account, watermarks)
        else
          nil -> {:error, :source_watermark_account_not_found}
          {:error, _reason} = error -> error
          _invalid -> {:error, :invalid_deferred_source_watermark}
        end
    end
  end

  def commit_and_sanitize(%BackgroundJob{}, handler_result), do: {:ok, handler_result}

  @doc false
  def deferred?(handler_result) do
    case handler_result do
      {:ok, result} when is_map(result) -> is_list(deferred_watermarks(result))
      _other -> false
    end
  end

  defp allowed_kinds(job_type) do
    case Map.fetch(@job_watermark_kinds, job_type) do
      {:ok, kinds} -> {:ok, kinds}
      :error -> {:error, :source_watermark_job_type_not_allowed}
    end
  end

  defp validate_watermarks([watermark], account_id, allowed_kinds) when is_map(watermark) do
    with ^account_id <- read_integer(watermark, "account_id"),
         kind when is_binary(kind) <- read_string(watermark, "kind"),
         true <- allowed_kind?(kind, allowed_kinds),
         value when is_binary(value) and value != "" <- read_string(watermark, "value"),
         :ok <- validate_expected_lower(watermark) do
      :ok
    else
      _invalid -> {:error, :invalid_deferred_source_watermark}
    end
  end

  defp validate_watermarks(_watermarks, _account_id, _allowed_kinds),
    do: {:error, :invalid_deferred_source_watermark}

  defp allowed_kind?(kind, allowed_kinds) do
    kind in allowed_kinds or
      (GmailSourceReplay.watermark_kind?(kind, "discovery") and
         "gmail_discovery_watermark" in allowed_kinds) or
      (GmailSourceReplay.watermark_kind?(kind, "closure") and
         "gmail_closure_watermark" in allowed_kinds)
  end

  defp validate_source_contract(%BackgroundJob{} = job, account, watermark) do
    role = source_job_role(job.job_type)

    expected_job_type =
      case role do
        "discovery" -> "runtime_partition:source_account_discovery"
        "closure" -> "runtime_partition:source_account_closure_acquire"
        nil -> nil
      end

    with role when role in ["discovery", "closure"] <- role,
         {:ok, acquisition} <- replay_acquisition_job(job, role),
         ^expected_job_type <- acquisition.job_type,
         true <- acquisition.user_id == account.user_id,
         true <- read_integer(acquisition.payload || %{}, "account_id") == account.id,
         {:ok, replay} <-
           GmailSourceReplay.from_payload(account, acquisition.payload || %{}, role),
         :ok <- validate_mode_watermark(account, watermark, replay, role) do
      :ok
    else
      _invalid -> {:error, :invalid_gmail_source_replay_settlement}
    end
  end

  defp validate_mode_watermark(_account, watermark, replay, _role) when is_map(replay) do
    if read_string(watermark, "kind") == replay.kind and
         read_string(watermark, "value") == Integer.to_string(replay.upper) and
         has_key?(watermark, "expected_lower_value") and
         read_string(watermark, "expected_lower_value") == Integer.to_string(replay.lower) do
      :ok
    else
      {:error, :invalid_gmail_source_replay_settlement}
    end
  end

  defp validate_mode_watermark(account, watermark, nil, role) do
    expected_kind = canonical_watermark_kind(account.provider, role)

    if read_string(watermark, "kind") == expected_kind,
      do: :ok,
      else: {:error, :invalid_deferred_source_watermark}
  end

  defp source_job_role(job_type)
       when job_type in [
              "runtime_partition:source_account_discovery",
              "runtime_partition:source_account_discovery_finalize"
            ],
       do: "discovery"

  defp source_job_role(job_type)
       when job_type in [
              "runtime_partition:source_account_closure_acquire",
              "runtime_partition:source_account_closure_finalize"
            ],
       do: "closure"

  defp source_job_role(_job_type), do: nil

  defp canonical_watermark_kind(provider, role) when is_binary(provider) do
    source = if String.starts_with?(provider, "slack:"), do: "slack", else: "gmail"
    "#{source}_#{role}_watermark"
  end

  defp replay_acquisition_job(%BackgroundJob{} = job, role) do
    expected_root_type =
      case role do
        "discovery" -> "runtime_partition:source_account_discovery"
        "closure" -> "runtime_partition:source_account_closure_acquire"
      end

    if job.job_type == expected_root_type do
      {:ok, BackgroundJob.hydrate_payloads(job)}
    else
      job = BackgroundJob.hydrate_payloads(job)

      with acquisition_id when is_binary(acquisition_id) <-
             read_string(job.payload || %{}, "acquisition_job_id"),
           %BackgroundJob{} = acquisition <- Repo.get(BackgroundJob, acquisition_id) do
        {:ok, BackgroundJob.hydrate_payloads(acquisition)}
      else
        _missing -> {:error, :gmail_source_replay_acquisition_missing}
      end
    end
  end

  defp validate_slack_conversation_watermark(watermark, account_id)
       when is_map(watermark) do
    with ^account_id <- read_integer(watermark, "account_id"),
         "slack_conversation:" <> digest = kind when digest != "" <-
           read_string(watermark, "kind"),
         true <- byte_size(kind) <= 80,
         value when is_binary(value) and value != "" <- read_string(watermark, "value"),
         :ok <- validate_expected_lower(watermark) do
      :ok
    else
      _invalid -> {:error, :invalid_deferred_source_watermark}
    end
  end

  defp validate_slack_conversation_watermark(_watermark, _account_id),
    do: {:error, :invalid_deferred_source_watermark}

  defp validate_expected_lower(watermark) do
    if has_key?(watermark, "expected_lower_value") do
      case get_value(watermark, "expected_lower_value") do
        nil -> :ok
        value when is_binary(value) and value != "" -> :ok
        _invalid -> {:error, :invalid_deferred_source_watermark}
      end
    else
      :ok
    end
  end

  defp lock_source_scope(user_id, account_id, watermark)
       when is_binary(user_id) and is_integer(account_id) and is_map(watermark) do
    kind = read_string(watermark, "kind")

    user =
      User
      |> where([candidate], candidate.id == ^user_id)
      |> lock("FOR UPDATE")
      |> Repo.one()

    account =
      ConnectedAccount
      |> where(
        [candidate],
        candidate.id == ^account_id and candidate.user_id == ^user_id
      )
      |> lock("FOR UPDATE")
      |> Repo.one()

    cursor =
      if is_binary(kind) do
        SourceCursor
        |> where(
          [candidate],
          candidate.connected_account_id == ^account_id and candidate.kind == ^kind
        )
        |> lock("FOR UPDATE")
        |> Repo.one()
      end

    cond do
      is_nil(kind) -> {:error, :invalid_deferred_source_watermark}
      is_nil(user) -> {:error, :source_watermark_user_not_found}
      is_nil(account) -> {:error, :source_watermark_account_not_found}
      true -> {:ok, account, cursor && cursor.value}
    end
  end

  defp lock_source_scope(_user_id, _account_id, _watermark),
    do: {:error, :invalid_deferred_source_watermark}

  defp settlement_disposition(watermark, current_value) do
    upper_value = read_string(watermark, "value")

    with {:ok, current} <- cursor_integer(current_value),
         {:ok, upper} <- cursor_integer(upper_value),
         {:ok, expected} <- expected_lower(watermark) do
      cond do
        cursor_after?(current, upper) ->
          {:ok, {:superseded, current_value}}

        expected == :legacy ->
          {:ok, {:seal, current_value}}

        expected == {:present, current} ->
          {:ok, {:seal, current_value}}

        match?({:present, _value}, expected) and
            cursor_after_or_equal?(current, elem(expected, 1)) ->
          {:ok, {:superseded, current_value}}

        true ->
          {:error, :source_watermark_cursor_regressed}
      end
    end
  end

  defp settle_disposition({:seal, lower_cursor}, job, result, account, watermarks) do
    with {:ok, _proof} <-
           SourceCycleSettlement.seal(job, result, account, watermarks,
             lower_cursor: lower_cursor
           ),
         :ok <- commit_watermarks(account, watermarks) do
      {:ok, {:ok, sanitize_result(result, length(watermarks))}}
    end
  end

  defp settle_disposition({:superseded, _current_value}, _job, result, _account, watermarks) do
    {:ok, {:ok, sanitize_superseded_result(result, length(watermarks))}}
  end

  defp settle_slack_conversation_disposition(
         {:seal, _lower_cursor},
         result,
         account,
         watermarks
       ) do
    with :ok <- commit_watermarks(account, watermarks) do
      {:ok, {:ok, sanitize_result(result, length(watermarks))}}
    end
  end

  defp settle_slack_conversation_disposition(
         {:superseded, _current_value},
         result,
         _account,
         watermarks
       ) do
    {:ok, {:ok, sanitize_superseded_result(result, length(watermarks))}}
  end

  defp expected_lower(watermark) do
    if has_key?(watermark, "expected_lower_value") do
      case cursor_integer(get_value(watermark, "expected_lower_value")) do
        {:ok, expected} -> {:ok, {:present, expected}}
        {:error, _reason} = error -> error
      end
    else
      {:ok, :legacy}
    end
  end

  defp cursor_integer(nil), do: {:ok, nil}

  defp cursor_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} when integer >= 0 -> {:ok, integer}
      _invalid -> {:error, :invalid_deferred_source_watermark}
    end
  end

  defp cursor_integer(_value), do: {:error, :invalid_deferred_source_watermark}

  defp cursor_after?(nil, _right), do: false
  defp cursor_after?(_left, nil), do: true
  defp cursor_after?(left, right), do: left > right

  defp cursor_after_or_equal?(nil, nil), do: true
  defp cursor_after_or_equal?(nil, _right), do: false
  defp cursor_after_or_equal?(_left, nil), do: true
  defp cursor_after_or_equal?(left, right), do: left >= right

  defp commit_watermarks(account, watermarks) do
    Enum.reduce_while(watermarks, :ok, fn watermark, :ok ->
      kind = read_string(watermark, "kind")
      value = read_string(watermark, "value")

      case SourceCursors.put(account, kind, %{"value" => value}) do
        {:ok, _cursor} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {:source_cursor_advance_failed, reason}}}
      end
    end)
  end

  defp sanitize_result(result, advanced_count) do
    result
    |> Map.delete(:deferred_watermarks)
    |> Map.delete("deferred_watermarks")
    |> Map.delete(:source_item_refs)
    |> Map.delete("source_item_refs")
    |> Map.delete(:source_proof_items)
    |> Map.delete("source_proof_items")
    |> Map.put(:advanced_watermarks, advanced_count)
  end

  defp sanitize_superseded_result(result, superseded_count) do
    result
    |> Map.delete(:outcome)
    |> Map.delete("outcome")
    |> sanitize_result(0)
    |> Map.put(:outcome, "superseded")
    |> Map.put(:superseded_watermarks, superseded_count)
  end

  defp deferred_watermarks(result),
    do: Map.get(result, :deferred_watermarks, Map.get(result, "deferred_watermarks"))

  defp read_integer(map, key) do
    case Map.get(map, key, Map.get(map, existing_atom(key))) do
      value when is_integer(value) -> value
      _other -> nil
    end
  end

  defp read_string(map, key) do
    case get_value(map, key) do
      value when is_binary(value) -> value
      _other -> nil
    end
  end

  defp get_value(map, key), do: Map.get(map, key, Map.get(map, existing_atom(key)))

  defp has_key?(map, key),
    do: Map.has_key?(map, key) or Map.has_key?(map, existing_atom(key))

  defp existing_atom("account_id"), do: :account_id
  defp existing_atom("acquisition_job_id"), do: :acquisition_job_id
  defp existing_atom("kind"), do: :kind
  defp existing_atom("value"), do: :value
  defp existing_atom("expected_lower_value"), do: :expected_lower_value
end
